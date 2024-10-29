# Pre-build stage
FROM ruby:3.3.3-alpine3.19 AS pre-builder

ARG BUNDLE_WITHOUT="development:test"
ARG RAILS_SERVE_STATIC_FILES=true
ARG RAILS_ENV=production
ARG NODE_OPTIONS="--openssl-legacy-provider"

ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT} \
    BUNDLER_VERSION=2.1.2 \
    RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES} \
    RAILS_ENV=${RAILS_ENV} \
    NODE_OPTIONS=${NODE_OPTIONS} \
    BUNDLE_PATH="/gems" \
    PNPM_HOME="/root/.local/share/pnpm" \
    PATH="$PNPM_HOME:$PATH"

# Install necessary dependencies
RUN apk update && apk add --no-cache \
  openssl tar build-base tzdata postgresql-dev postgresql-client nodejs=20.15.1-r0 git xz vips \
  && gem install bundler \
  && rm -rf /var/cache/apk/*

# Install pnpm
RUN wget -qO- https://get.pnpm.io/install.sh | SHELL="/bin/sh" sh - \
    && echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.shrc \
    && export PATH="$PNPM_HOME:$PATH" \
    && pnpm --version

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local force_ruby_platform true \
  && bundle install -j4 --without development test \
  && rm -rf /gems/ruby/3.3.0/cache/*.gem

COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile \
  && rm -rf node_modules tmp/cache

COPY . .

# Production assets if RAILS_ENV is production
RUN if [ "$RAILS_ENV" = "production" ]; then \
  SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled bundle exec rake assets:precompile; \
  fi \
  && rm -rf spec tmp/cache .git .gitignore \
  && mkdir -p /app/log \
  && git rev-parse HEAD > /app/.git_sha

# Final build stage
FROM ruby:3.3.3-alpine3.19

ARG BUNDLE_WITHOUT="development:test"
ARG EXECJS_RUNTIME="Disabled"
ARG RAILS_SERVE_STATIC_FILES=true
ARG BUNDLE_FORCE_RUBY_PLATFORM=1
ARG RAILS_ENV=production

ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT} \
    BUNDLER_VERSION=2.1.2 \
    EXECJS_RUNTIME=${EXECJS_RUNTIME} \
    RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES} \
    BUNDLE_FORCE_RUBY_PLATFORM=${BUNDLE_FORCE_RUBY_PLATFORM} \
    RAILS_ENV=${RAILS_ENV} \
    BUNDLE_PATH="/gems" \
    PNPM_HOME="/root/.local/share/pnpm" \
    PATH="$PNPM_HOME:$PATH"

RUN apk update && apk add --no-cache \
  tzdata postgresql-client vips \
  && gem install bundler \
  && rm -rf /var/cache/apk/*

COPY --from=pre-builder /gems/ /gems/
COPY --from=pre-builder /app /app

WORKDIR /app
EXPOSE 3000
