# Build stage
FROM ruby:3.2-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y curl build-essential ruby-dev
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle config set --local without 'development test' && bundle install

# Runtime stage
FROM ruby:3.2-slim
WORKDIR /app
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY app.rb .
EXPOSE 4567
ENV RACK_ENV=production
CMD ["bundle", "exec", "puma", "-p", "4567", "-b", "tcp://0.0.0.0"]