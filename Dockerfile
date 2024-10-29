# pre-build stage
FROM ruby:3.3.3-alpine3.19 AS pre-builder

# ARG default to production settings
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.1.2
ENV BUNDLE_PATH="/gems"

# Install essential packages
RUN apk update && apk add --no-cache \
  openssl \
  build-base \
  tzdata \
  postgresql-dev \
  postgresql-client \
  nodejs=20.15.1-r0 \
  git \
  && gem install bundler

# Set working directory
WORKDIR /app

# Copy Gemfile and Gemfile.lock and install gems
COPY Gemfile Gemfile.lock ./
RUN bundle config set --local force_ruby_platform true && \
    if [ "$RAILS_ENV" = "production" ]; then \
      bundle config set without 'development test'; \
    fi && \
    bundle install -j 4

# Install pnpm and configure environment
RUN wget -qO- https://get.pnpm.io/install.sh | sh - && \
    echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> /root/.shrc && \
    echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.shrc && \
    source /root/.shrc

# Install project dependencies
COPY package.json pnpm-lock.yaml ./
RUN pnpm install

# Copy application code
COPY . .

# Create necessary directories and precompile assets if in production
RUN mkdir -p log && \
    if [ "$RAILS_ENV" = "production" ]; then \
      SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled bundle exec rake assets:precompile && \
      rm -rf spec node_modules tmp/cache; \
    fi

# Generate .git_sha file with current commit hash
RUN git rev-parse HEAD > .git_sha

# Remove unnecessary files
RUN rm -rf /gems/ruby/3.3.0/cache/*.gem && \
    find /gems/ruby/3.3.0/gems/ -name "*.c" -o -name "*.o" -delete && \
    rm -rf .git .gitignore

# final build stage
FROM ruby:3.3.3-alpine3.19

# ARG and ENV settings
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.1.2
ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}
ENV BUNDLE_PATH="/gems"

# Install runtime dependencies
RUN apk update && apk add --no-cache \
  openssl \
  tzdata \
  postgresql-client \
  imagemagick \
  git \
  vips && \
  gem install bundler

# Copy from pre-builder stage
COPY --from=pre-builder /gems/ /gems/
COPY --from=pre-builder /app /app

# Copy .git_sha file from pre-builder stage
COPY --from=pre-builder /app/.git_sha /app/.git_sha

# Set working directory
WORKDIR /app

# Expose the port
EXPOSE 3000
