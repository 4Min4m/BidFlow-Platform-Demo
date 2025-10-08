require 'redis'
require 'json'
require 'sinatra'  # gem install sinatra redis (local run)

# GC Tuning for high-traffic (from transcript)
ENV['RUBY_GC_HEAP_GROWTH_FACTOR'] = '1.1' if ENV['RUBY_GC_HEAP_GROWTH_FACTOR'].nil?

redis = Redis.new(host: 'localhost', port: 6379)  # Local for now

post '/bid' do
  begin
    data = JSON.parse(request.body.read)
    bid_id = data['id']
    amount = data['amount']
    
    # Validate: Amount > 0
    raise "Invalid bid amount" if amount <= 0
    
    # Store in Redis
    redis.set("bid:#{bid_id}", amount.to_s)
    
    # Log JSON event
    log_event = { event: 'bid_received', id: bid_id, amount: amount, timestamp: Time.now.utc.iso8601 }.to_json
    puts log_event  # For demo; in prod, to ELK
    
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