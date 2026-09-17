# BidFlow — Self-Service Polyglot Bidding Platform (IDP on GKE Autopilot)

BidFlow is a small but real Internal Developer Platform: one Helm chart,
driven entirely by `values.yaml`, deploys a **polyglot pair of services**
(Go + Ruby) plus Redis, wires up autoscaling and health checks, and — as of
Phase 2 — gives you one connected, cross-language trace for every request
that flows through the system. It's built to demonstrate the platform
engineering skills in the resume bullet it backs, not to be a real auction
house.

## Architecture

```
                     +-----------------------------------------+
                     |              GKE Autopilot                |
                     |                                           |
   Internet          |   +----------+        +---------------+  |
   ------->  Ingress-+-->| go-bidder|--HTTP->|  ruby-bidder   |  |
   (GCE LB)          |   |  (Go)    | +trace |  (Sinatra)     |  |
                     |   |  :8080   | context|  :4567         |  |
                     |   +----+-----+        +-------+--------+  |
                     |        |                       |          |
                     |        | OTLP/HTTP             | redis-cli|
                     |        v                       v          |
                     |   +-------------+        +-----------+   |
                     |   |   Jaeger    |        |   Redis    |   |
                     |   | (all-in-one)|        |(StatefulSet)|  |
                     |   |  :16686 UI  |        +-----+-----+   |
                     |   +-------------+              |          |
                     |                                 v          |
                     |                          CronJob (6h) --> GCS bucket
                     |                          (Workload Identity) (RDB backup)
                     +-----------------------------------------+
                              ^
                              | build -> immutable SHA tag -> push -> helm upgrade
                     +--------+--------+
                     | GitHub Actions   |  (Workload Identity Federation - no
                     | (push-based      |   downloaded key; keyless OIDC auth
                     |  GitOps)         |   to GCP, same trust model as IRSA)
                     +------------------+
```

**Why two services calling each other, not one polyglot switch?** An earlier
version of this chart deployed *either* a Go or a Ruby pod behind one
conditional. That's a fine demo of "one chart, two languages," but it can't
produce a cross-language trace — there's only ever one hop. Restructuring so
`go-bidder` is the public entry point that validates and forwards to
`ruby-bidder` (which owns the Redis write) makes the polyglot claim and the
distributed-tracing claim reinforce each other: one HTTP request really does
cross a language boundary, and Jaeger shows it.

## What this demonstrates

| Where it lives |
|---|---|
| Self-service IDP on GKE Autopilot | `terraform/main.tf` (cluster + APIs), one Helm chart for both services |
| Modular Helm charts (Ruby/Go polyglot) | `helm/templates/deployment.yaml` — a single `range` over `values.services` renders both languages; onboarding a third service is a values.yaml entry, not new YAML |
| Compliant deployments under 3 minutes | `helm/templates/{networkpolicy,resourcequota,limitrange}.yaml` bake in non-root containers, dropped capabilities, default-deny NetworkPolicy, and resource guardrails so a team can't accidentally deploy something non-compliant |
| End-to-end GitOps, immutable image tagging | `.github/workflows/deploy.yaml` — build -> SHA-tag -> push -> `helm upgrade`, push-based (Project 1's EKS/HTTPBin platform demonstrates the pull-based/Argo CD alternative) |
| Terraform | `terraform/main.tf` — GKE Autopilot, Artifact Registry, GCS backup bucket, Workload Identity Federation for keyless CI auth, Workload Identity for the backup CronJob |
| Prometheus + HPA | `/metrics` on both services (Prometheus-scrape annotated), `helm/templates/hpa.yaml`, one per service |
| Polyglot distributed tracing (OpenTelemetry + Jaeger) | `app/go-bidder` + `app/ruby-bidder` both instrumented; `helm/templates/jaeger.yaml` |

## Repo layout

```
app/
  go-bidder/     Public entry point: validates bids, forwards to ruby-bidder
  ruby-bidder/   Core service: owns the Redis write, the A/B TTL experiment
helm/            One chart, both services + Redis + Jaeger + guardrails
terraform/       GKE Autopilot, Artifact Registry, GCS bucket, Workload
                 Identity Federation (CI) and Workload Identity (backups)
scripts/parsing/ log_parser.py — offline Z-score prototype for bid anomalies
transcripts/     Simulated cross-functional review notes that shaped the
                 design decisions below (dev/platform/product "teammates")
```

## Deploying from GitHub Codespaces

Everything below assumes a Codespace with no local installs — `gcloud`,
`terraform`, `kubectl`, and `helm` all need one-time authentication inside
the Codespace itself.

1. **Authenticate gcloud** (one-time per Codespace):
   ```bash
   gcloud auth login --no-launch-browser
   gcloud auth application-default login --no-launch-browser
   gcloud config set project <your-project-id>
   ```
2. **Provision infrastructure:**
   ```bash
   cd terraform
   terraform init
   terraform apply \
     -var="project_id=<your-project-id>" \
     -var="github_repository=<your-gh-user>/<your-repo>" \
     -var="backup_bucket_name=<globally-unique-bucket-name>"
   terraform output   # copy these values into the next two steps
   ```
3. **Wire up GitHub Actions** — in your repo's Settings -> Secrets and
   variables -> Actions -> Variables, add `WIF_PROVIDER`,
   `WIF_SERVICE_ACCOUNT`, `ARTIFACT_REGISTRY`, `GKE_REGION` from the
   `terraform output` above. No secrets are needed — Workload Identity
   Federation is keyless.
4. **Fill in `helm/values.yaml`**: `imageRegistry`, `backup.gcpServiceAccountEmail`,
   `backup.gcs.bucket` — again, straight from `terraform output`.
5. **Sanity-check the chart before pushing anything:**
   ```bash
   helm lint helm/
   helm template bidflow-app helm/ --values helm/values.yaml | less
   ```
6. **Push to `main`.** GitHub Actions builds both images, tags them with the
   commit SHA, pushes to Artifact Registry, and runs `helm upgrade --install`
   against your cluster.
7. **Verify:**
   ```bash
   kubectl get pods -n bidflow
   kubectl get ingress -n bidflow   # wait for an ADDRESS, GCE LBs take a few minutes
   curl -X POST http://<ingress-ip>/bid -d '{"id":"abc","amount":42.5}'
   ```
8. **See a real cross-language trace:**
   ```bash
   kubectl port-forward -n bidflow svc/bidflow-app-jaeger 16686:16686
   ```
   Open `localhost:16686`, search for service `bidflow-go-bidder`, and open
   the most recent trace — it should show a `go-bidder` root span, an HTTP
   client span, and a `ruby-bidder` server span with a nested Redis span.

## Honest scope notes

- **Single environment, single region.** This project's differentiator is
  polyglot developer experience and tracing, not multi-env promotion.
- **Jaeger is all-in-one**, storing traces in memory. It's the right choice
  for demoing trace propagation on a portfolio budget; it is *not*
  production-grade (traces vanish on pod restart, no HA, no long-term
  retention). Production would point the OTLP exporters at a managed
  backend (Grafana Tempo, Cloud Trace, or Jaeger with Elasticsearch/Cassandra
  storage).
- **go-bidder and ruby-bidder are stand-ins** for "the kind of service a
  team would onboard," not real auction logic.
- **NetworkPolicy egress is intentionally a little permissive** (443/DNS
  open to any destination for the whole service group) rather than pinned
  to exact IP ranges for GCS/Jaeger — tightening that further is a natural
  next exercise, called out in the study guide.

## How I Created It

I developed BidFlow over a focused stretch as preparation for a senior
platform engineer role, starting with a simple Ruby Sinatra prototype to
simulate auction bid flows (inspired by real-world transcripts on
high-traffic GC tuning — see `transcripts/`). From there I layered in
infrastructure using Terraform for GKE Autopilot, GitHub Actions for an
end-to-end CI/CD pipeline, and Helm for templated, reusable manifests. Adding
a second, Go-based service later wasn't a rewrite — it was one more entry in
`values.yaml` and a new `app/` directory, which is exactly the point of a
modular chart.

To build collaboration skills, I simulated cross-team feedback by
role-playing with AI as "teammates" (a developer, platform engineer, and
product owner) — see the **Teammate Iterations** section below and the raw
transcripts in `transcripts/`. Their hypothetical questions drove real
refinements, like the language-specific GC env vars and the A/B TTL
experiment.

## Key Features

- **Self-Service Deploys** — a single Helm chart, driven by `values.yaml`,
  deploys both languages. The CI pipeline builds/tests/pushes both images
  and rolls out via `helm upgrade` with immutable SHA tags.
- **Scaling & Reliability** — one HPA per service (1-5 replicas, 50% CPU),
  liveness/readiness probes on both, graceful Redis degradation in
  ruby-bidder, StatefulSet + dynamic PVC for Redis.
- **A/B Experimentation** — `AB_VARIANT` env var controls the Redis bid TTL
  (30s vs 120s), with logs tagged by variant.
- **Observability & Anomaly Detection** — `/metrics` on both services,
  structured JSON logs correlated to trace IDs, `scripts/parsing/log_parser.py`
  as an offline Z-score prototype, and — as of Phase 2 — full distributed
  tracing via OpenTelemetry + Jaeger.
- **Data Resilience** — a dynamic 1Gi PVC backs Redis, with a CronJob doing
  RDB backups to GCS every 6 hours over Workload Identity (no keys).
- **Compliance guardrails** — non-root containers, dropped Linux
  capabilities, a default-deny `NetworkPolicy` opened up only for the
  traffic paths BidFlow actually needs, and namespace-wide `ResourceQuota`/
  `LimitRange` so a misconfigured onboarding can't starve the cluster.

## Teammate Iterations

- **Dev Teammate (Runtime Customization)** — questioning how to handle Ruby
  vs. Go without fragmented charts led to per-service env blocks in
  `values.yaml` rendered by one shared Deployment template.
- **Platform Teammate (Observability Stack)** — guidance on ELK/Prometheus
  and anomaly detection inspired the structured logs, `/metrics` endpoints,
  and — extending the original idea — the OpenTelemetry/Jaeger work in
  Phase 2, since trace correlation is the natural next step after
  structured logs.
- **Product Teammate (Experiment Priorities)** — focus on low-latency A/B
  for TTLs resulted in the env-driven variant logic in `ruby-bidder`.

Full transcripts: `transcripts/`.

## Tech Stack

- **Cloud & Orchestration:** GKE Autopilot, Kubernetes, Helm
- **IaC & CI/CD:** Terraform, GitHub Actions (Workload Identity Federation —
  keyless), push-based GitOps
- **App Runtime:** Go 1.22 (go-bidder, entry point) + Ruby 3.2/Sinatra
  (ruby-bidder, core logic), Redis 7
- **Observability:** OpenTelemetry SDKs (Go + Ruby) -> OTLP -> Jaeger
  all-in-one; Prometheus-annotated `/metrics`; structured JSON logs
- **Security/Compliance:** non-root containers, dropped capabilities,
  NetworkPolicy, ResourceQuota/LimitRange, Workload Identity (no static
  keys anywhere in the pipeline)

## Future Enhancements

- Redis: StatefulSet with replicas=3 (or migrate to Memorystore) for HA
- Swap Jaeger all-in-one for a managed/HA tracing backend
- Migrate to Argo CD for pull-based sync (mirroring Project 1, for
  comparison) or add progressive delivery (Flagger/Argo Rollouts)
- Tighten NetworkPolicy egress from "443 to anywhere" to explicit GCS/Jaeger
  CIDR ranges
- Chaos testing (Litmus) against the Redis-unavailable degradation path

Fork and build on it — let's make auctions faster and more reliable!
