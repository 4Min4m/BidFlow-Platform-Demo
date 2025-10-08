# Build stage
FROM ruby:3.2-slim AS builder
WORKDIR /app
RUN apt-get update && apt-get install -y curl
RUN gem install sinatra redis --no-document

# Runtime stage
FROM ruby:3.2-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl
COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY app.rb .
EXPOSE 4567
CMD ["ruby", "app.rb", "-o", "0.0.0.0"]