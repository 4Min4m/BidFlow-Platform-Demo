require 'redis'
require 'json'
require 'sinatra'

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
    
    # Validate: Amount > 0
    raise "Invalid bid amount" if amount.nil? || amount <= 0
    raise "Missing bid ID" if bid_id.nil?
    
    # A/B Experiment: Variant-based Redis TTL
    redis_ttl = case ENV['AB_VARIANT']
                when 'B' then 120
                else 30
                end
    
    # Override with explicit env var if set
    redis_ttl = ENV['REDIS_TTL'].to_i if ENV['REDIS_TTL']
    
    # Store in Redis (if available) with TTL
    redis = get_redis
    if redis
      redis.set("bid:#{bid_id}", amount.to_s, ex: redis_ttl)
    end
    
    # Increment success counter
    $bid_count += 1
    
    # Log JSON event (structured for ELK)
    log_event = { 
      event: 'bid_received', 
      id: bid_id, 
      amount: amount, 
      ab_variant: ENV['AB_VARIANT'] || 'A',
      timestamp: Time.now.utc.iso8601 
    }.to_json
    puts log_event
    
    status 201
    { status: 'Bid stored' }.to_json
  rescue JSON::ParserError => e
    $bid_errors += 1
    status 400
    { error: 'Invalid JSON' }.to_json
  rescue => e
    $bid_errors += 1
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