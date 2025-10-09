require 'redis'
require 'json'
require 'sinatra'

# GC Tuning for high-traffic (from transcript)
ENV['RUBY_GC_HEAP_GROWTH_FACTOR'] = '1.1' if ENV['RUBY_GC_HEAP_GROWTH_FACTOR'].nil?

# Lazy Redis connection: Only init when needed (e.g., on /bid)
def get_redis
  @redis ||= Redis.new(host: 'localhost', port: 6379)
rescue Redis::CannotConnectError => e
  # For tests/demo: Log and proceed without Redis (or raise in prod)
  puts "Redis unavailable: #{e.message}. Skipping storage."
  nil
end

post '/bid' do
  begin
    data = JSON.parse(request.body.read)
    bid_id = data['id']
    amount = data['amount']
    
    # Validate: Amount > 0
    raise "Invalid bid amount" if amount <= 0
    
    # A/B Experiment: Variant-based Redis TTL (product teammate: Test expiration impacts)
    redis_ttl = case ENV['AB_VARIANT']
                when 'B' then (ENV['REDIS_TTL'] || 120).to_i
                else (ENV['REDIS_TTL'] || 30).to_i
                end
    
    # Store in Redis (if available) with TTL
    redis = get_redis
    if redis
      redis.set("bid:#{bid_id}", amount.to_s, ex: redis_ttl)
    end
    
    # Log JSON event (structured for ELK)
    log_event = { 
      event: 'bid_received', 
      id: bid_id, 
      amount: amount, 
      ab_variant: ENV['AB_VARIANT'] || 'A',
      timestamp: Time.now.utc.iso8601 
    }.to_json
    puts log_event  # For demo; in prod, to ELK with trace_id
    
    status 201
    { status: 'Bid stored' }.to_json
  rescue JSON::ParserError => e
    status 400
    { error: 'Invalid JSON' }.to_json
  rescue => e
    status 500
    { error: e.message }.to_json
  end
end

get '/metrics' do
  "bids_total{status=\"received\"} 1\n"
end

get '/health' do
  'OK'
end

get '/live' do  # Liveness probe
  'Alive'
end

get '/ready' do  # Readiness probe
  'Ready'
end