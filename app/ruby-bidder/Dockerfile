# Build stage
FROM ruby:3.2-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y curl build-essential ruby-dev
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle config set --local without 'development test' && bundle install

# Runtime stage
FROM ruby:3.2-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY app.rb .
EXPOSE 4567
CMD ["bundle", "exec", "ruby", "app.rb", "-o", "0.0.0.0"]