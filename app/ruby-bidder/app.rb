require 'redis'
require 'json'
require 'sinatra'

# --- OpenTelemetry -----------------------------------------------------
# opentelemetry-instrumentation-all auto-detects and instruments Sinatra
# (HTTP server spans, including extracting the traceparent header that
# go-bidder sends) and Redis (child spans for GET/SET/etc). The OTLP
# exporter and endpoint are read from OTEL_EXPORTER_OTLP_ENDPOINT /
# OTEL_EXPORTER_OTLP_PROTOCOL, set by the Helm chart — nothing is
# hardcoded here, and if those env vars are unset the SDK exports to
# localhost and simply never succeeds, without affecting request handling.
require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'opentelemetry/instrumentation/all'

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch('OTEL_SERVICE_NAME', 'bidflow-ruby-bidder')
  c.use_all
end

# ------------------------------------------------------------------------

set :bind, '0.0.0.0'
set :port, 4567

# GC Tuning for high-traffic (from transcript)
ENV['RUBY_GC_HEAP_GROWTH_FACTOR'] = '1.1' if ENV['RUBY_GC_HEAP_GROWTH_FACTOR'].nil?

# Track metrics in memory
$bid_count = 0
$bid_errors = 0

# Lazy Redis connection with proper service discovery
def get_redis
  return @redis if @redis

  redis_host = ENV['REDIS_HOST'] || 'bidflow-app-redis'
  redis_port = ENV['REDIS_PORT']&.to_i || 6379

  @redis = Redis.new(
    host: redis_host,
    port: redis_port,
    timeout: 1,
    reconnect_attempts: 3
  )
rescue Redis::CannotConnectError => e
  # For graceful degradation: Log and proceed without Redis
  puts "Redis unavailable at #{redis_host}:#{redis_port}: #{e.message}"
  nil
end

post '/bid' do
  begin
    data = JSON.parse(request.body.read)
    bid_id = data['id']
    amount = data['amount']
    forwarded_by = data['forwarded_by'] # set when go-bidder is the caller

    current_span = OpenTelemetry::Trace.current_span
    current_span.set_attribute('bid.id', bid_id.to_s)
    current_span.set_attribute('bid.amount', amount.to_f) if amount
    current_span.set_attribute('bid.forwarded_by', forwarded_by) if forwarded_by

    # Validate before touching anything else. Checked as Numeric so a
    # string amount ("42") is a clean 400, not a NoMethodError -> 500.
    if bid_id.nil? || bid_id.to_s.empty?
      $bid_errors += 1
      halt 400, { error: 'Missing bid ID' }.to_json
    end
    unless amount.is_a?(Numeric) && amount.positive?
      $bid_errors += 1
      halt 400, { error: 'Invalid bid amount' }.to_json
    end

    # A/B Experiment: Variant-based Redis TTL
    redis_ttl = case ENV['AB_VARIANT']
                when 'B' then 120
                else 30
                end

    # Override with explicit env var if set
    redis_ttl = ENV['REDIS_TTL'].to_i if ENV['REDIS_TTL']

    # Store in Redis (if available) with TTL — instrumented automatically,
    # this shows up as a child span of the current request span.
    # Redis.new connects lazily, so an outage surfaces here, not in
    # get_redis — rescue it so the bid path degrades instead of 500ing.
    stored = false
    redis = get_redis
    if redis
      begin
        redis.set("bid:#{bid_id}", amount.to_s, ex: redis_ttl)
        stored = true
      rescue Redis::BaseError => e
        current_span.record_exception(e)
        puts({ event: 'redis_unavailable', error: e.message }.to_json)
      end
    end

    # Increment success counter
    $bid_count += 1

    # Log JSON event (structured for ELK), tagged with the active trace so
    # logs can be correlated back to the exact trace in Jaeger.
    log_event = {
      event: 'bid_received',
      id: bid_id,
      amount: amount,
      ab_variant: ENV['AB_VARIANT'] || 'A',
      stored: stored,
      forwarded_by: forwarded_by,
      trace_id: current_span.context.hex_trace_id,
      timestamp: Time.now.utc.iso8601
    }.to_json
    puts log_event

    status stored ? 201 : 202
    { status: stored ? 'Bid stored' : 'Bid accepted (cache unavailable)' }.to_json
  rescue JSON::ParserError => e
    $bid_errors += 1
    status 400
    { error: 'Invalid JSON' }.to_json
  rescue => e
    $bid_errors += 1
    OpenTelemetry::Trace.current_span.record_exception(e)
    status 500
    { error: e.message }.to_json
  end
end

get '/metrics' do
  content_type 'text/plain'
  <<~METRICS
    # HELP bids_total Total number of bids received
    # TYPE bids_total counter
    bids_total{status="received"} #{$bid_count}

    # HELP bids_errors_total Total number of bid errors
    # TYPE bids_errors_total counter
    bids_errors_total #{$bid_errors}
  METRICS
end

get '/health' do
  'OK'
end

get '/live' do
  'Alive'
end

get '/ready' do
  # Check Redis connectivity for readiness
  redis = get_redis
  if redis
    begin
      redis.ping
      status 200
      'Ready'
    rescue
      status 503
      'Redis unavailable'
    end
  else
    status 200
    'Ready (Redis optional)'
  end
end
