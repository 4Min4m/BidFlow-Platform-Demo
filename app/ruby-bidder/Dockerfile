# Build stage
FROM ruby:3.2-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl build-essential ruby-dev \
    && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN gem install bundler && bundle config set --local without 'development test' && bundle install

# Runtime stage
FROM ruby:3.2-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -r bidflow && useradd -r -g bidflow -u 10001 bidflow
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY app.rb .
USER bidflow:bidflow
EXPOSE 4567
ENV RACK_ENV=production
CMD ["bundle", "exec", "ruby", "app.rb"]
