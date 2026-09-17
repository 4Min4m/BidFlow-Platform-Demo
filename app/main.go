// go-bidder is the polyglot "front door" of BidFlow.
//
// It is intentionally a *thin* validation + fan-out layer, written in Go to
// showcase the polyglot side of the platform: it terminates the public
// ingress, does cheap request validation, tags the bid with an A/B
// experiment variant, and forwards the enriched bid to the Ruby
// "core" service (ruby-bidder), which owns the Redis write.
//
// A single incoming HTTP request therefore produces one OpenTelemetry trace
// that spans two languages: a root span here in Go, a child HTTP span for
// the outbound call, and a server span (plus a Redis span) in Ruby. That
// cross-service, cross-language trace is the point of Project 3's Phase 2.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"os"
	"runtime/debug"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
	"go.opentelemetry.io/otel/trace"
)

const serviceName = "bidflow-go-bidder"

var (
	tracer = otel.Tracer(serviceName)

	bidsForwardedTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "bids_forwarded_total",
		Help: "Bids that go-bidder validated and forwarded to the core service.",
	}, []string{"status"})

	bidValidationErrorsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Name: "bid_validation_errors_total",
		Help: "Bids rejected by go-bidder before ever reaching the core service.",
	})

	forwardLatency = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "bid_forward_latency_seconds",
		Help:    "Latency of the go-bidder -> ruby-bidder forward call.",
		Buckets: prometheus.DefBuckets,
	})
)

// bidRequest is what a client (or load test) sends to go-bidder.
type bidRequest struct {
	ID     string  `json:"id"`
	Amount float64 `json:"amount"`
}

// bidForward is what go-bidder sends on to ruby-bidder: the original bid
// plus fields only the Go layer knows how to compute.
type bidForward struct {
	ID          string  `json:"id"`
	Amount      float64 `json:"amount"`
	ForwardedBy string  `json:"forwarded_by"`
	ReceivedAt  string  `json:"received_at"`
}

func mustGetenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func setupTracing(ctx context.Context) (func(context.Context) error, error) {
	// otlptracehttp.New honors OTEL_EXPORTER_OTLP_ENDPOINT /
	// OTEL_EXPORTER_OTLP_PROTOCOL from the environment when no explicit
	// options are given, so no endpoint is hardcoded here. If the env var
	// is unset (e.g. running locally with tracing disabled), the exporter
	// falls back to localhost:4318 and simply fails to connect silently
	// in the background — it never blocks request handling.
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}

	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(semconv.SchemaURL,
			semconv.ServiceName(serviceName),
		),
	)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(otel.GetTextMapPropagator())

	return tp.Shutdown, nil
}

func validateBid(b bidRequest) error {
	if b.ID == "" {
		return errors.New("missing bid id")
	}
	if b.Amount <= 0 {
		return errors.New("invalid bid amount")
	}
	return nil
}

func bidHandler(rubyURL string, httpClient *http.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx := r.Context()
		span := trace.SpanFromContext(ctx)

		var req bidRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			bidValidationErrorsTotal.Inc()
			span.SetStatus(codes.Error, "invalid json")
			http.Error(w, `{"error":"invalid json"}`, http.StatusBadRequest)
			return
		}

		if err := validateBid(req); err != nil {
			bidValidationErrorsTotal.Inc()
			span.SetStatus(codes.Error, err.Error())
			span.SetAttributes(attribute.String("bid.rejection_reason", err.Error()))
			http.Error(w, `{"error":"`+err.Error()+`"}`, http.StatusBadRequest)
			return
		}

		span.SetAttributes(
			attribute.String("bid.id", req.ID),
			attribute.Float64("bid.amount", req.Amount),
		)

		forward := bidForward{
			ID:          req.ID,
			Amount:      req.Amount,
			ForwardedBy: serviceName,
			ReceivedAt:  time.Now().UTC().Format(time.RFC3339),
		}
		body, _ := json.Marshal(forward)

		start := time.Now()
		fctx, fspan := tracer.Start(ctx, "forward_bid_to_ruby")
		httpReq, err := http.NewRequestWithContext(fctx, http.MethodPost, rubyURL+"/bid", bytes.NewReader(body))
		if err != nil {
			fspan.End()
			bidsForwardedTotal.WithLabelValues("error").Inc()
			http.Error(w, `{"error":"internal error building forward request"}`, http.StatusInternalServerError)
			return
		}
		httpReq.Header.Set("Content-Type", "application/json")

		resp, err := httpClient.Do(httpReq)
		forwardLatency.Observe(time.Since(start).Seconds())
		fspan.End()

		if err != nil {
			bidsForwardedTotal.WithLabelValues("error").Inc()
			span.SetStatus(codes.Error, "core service unreachable")
			http.Error(w, `{"error":"core service unreachable"}`, http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		respBody, _ := io.ReadAll(resp.Body)

		if resp.StatusCode >= 400 {
			bidsForwardedTotal.WithLabelValues("rejected_by_core").Inc()
		} else {
			bidsForwardedTotal.WithLabelValues("accepted").Inc()
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(respBody)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("OK"))
}

func liveHandler(w http.ResponseWriter, r *http.Request) {
	w.Write([]byte("Alive"))
}

// readyHandler pings the core (Ruby) service so Kubernetes stops routing
// traffic here if the dependency it fans out to is down — mirroring the
// readiness semantics of ruby-bidder's own /ready check against Redis.
func readyHandler(rubyURL string, httpClient *http.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, rubyURL+"/health", nil)
		if err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte("core service check failed"))
			return
		}
		resp, err := httpClient.Do(req)
		if err != nil || resp.StatusCode >= 400 {
			w.WriteHeader(http.StatusServiceUnavailable)
			w.Write([]byte("core service unavailable"))
			return
		}
		defer resp.Body.Close()
		w.Write([]byte("Ready"))
	}
}

func main() {
	log.Printf("starting %s — GOGC=%s GODEBUG=%s", serviceName, os.Getenv("GOGC"), os.Getenv("GODEBUG"))
	debug.SetGCPercent(-1) // no-op placeholder; GOGC env var is honored by the runtime directly

	ctx := context.Background()
	shutdown, err := setupTracing(ctx)
	if err != nil {
		log.Printf("tracing disabled: %v", err)
	} else {
		defer shutdown(ctx)
	}

	rubyURL := mustGetenv("RUBY_SERVICE_URL", "http://bidflow-app-ruby-bidder:4567")
	httpClient := &http.Client{
		Timeout:   3 * time.Second,
		Transport: otelhttp.NewTransport(http.DefaultTransport),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/live", liveHandler)
	mux.HandleFunc("/ready", readyHandler(rubyURL, httpClient))
	mux.Handle("/metrics", promhttp.Handler())
	mux.Handle("/bid", otelhttp.NewHandler(bidHandler(rubyURL, httpClient), "POST /bid"))

	addr := ":8080"
	log.Printf("%s listening on %s, forwarding bids to %s", serviceName, addr, rubyURL)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}
