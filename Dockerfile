# pre-build stage
FROM ruby:3.3.3-alpine3.19 AS pre-builder

# Set default production settings, overridden by docker-compose file in development
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.1.2
ENV BUNDLE_PATH="/gems"
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="${PNPM_HOME}:${PATH}"

COPY package.json pnpm-lock.yaml ./

# Rails environment settings
ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}
ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}

ARG NODE_OPTIONS="--openssl-legacy-provider"
ENV NODE_OPTIONS=${NODE_OPTIONS}

# Install dependencies
RUN apk update && apk add --no-cache \
  openssl tar build-base tzdata postgresql-dev postgresql-client nodejs=20.15.1-r0 git \
  && mkdir -p /var/app \
  && gem install bundler

# Install pnpm and configure environment
RUN wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.shrc" SHELL="$(which sh)" sh - \
  && echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> /root/.shrc \
  && echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.shrc \
  && pnpm --version

WORKDIR /app

COPY Gemfile Gemfile.lock ./

# Additional dependencies for Alpine
RUN apk add --no-cache build-base musl ruby-full ruby-dev gcc make musl-dev openssl openssl-dev g++ linux-headers xz vips
RUN bundle config set --local force_ruby_platform true

# Install gems
RUN if [ "$RAILS_ENV" = "production" ]; then \
  bundle config set without 'development test'; \
  bundle install -j 4 -r 3; \
  else bundle install -j 4 -r 3; \
  fi

# Install pnpm packages
RUN pnpm i

# Copy application files
COPY . /app

# Create a log directory
RUN mkdir -p /app/log

# Precompile assets for production
RUN if [ "$RAILS_ENV" = "production" ]; then \
  SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled bundle exec rake assets:precompile \
  && rm -rf spec node_modules tmp/cache; \
  fi

# Generate .git_sha file if .git exists
RUN if [ -d .git ]; then git rev-parse HEAD > /app/.git_sha; else echo "No git repository" > /app/.git_sha; fi

# Clean up unnecessary files
RUN rm -rf /gems/ruby/3.3.0/cache/*.gem \
  && find /gems/ruby/3.3.0/gems/ \( -name "*.c" -o -name "*.o" \) -delete \
  && rm -rf .git \
  && rm .gitignore

# Final build stage
FROM ruby:3.3.3-alpine3.19

ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.1.2
ENV EXECJS_RUNTIME="Disabled"
ENV RAILS_SERVE_STATIC_FILES=true
ENV BUNDLE_FORCE_RUBY_PLATFORM=1
ENV RAILS_ENV=production
ENV BUNDLE_PATH="/gems"
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="${PNPM_HOME}:${PATH}"

# Install required packages
RUN apk update && apk add --no-cache \
  build-base openssl tzdata postgresql-client imagemagick git vips \
  && gem install bundler

# Install pnpm for non-production environments
RUN if [ "$RAILS_ENV" != "production" ]; then \
  apk add --no-cache nodejs-current; \
  wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.shrc" SHELL="$(which sh)" sh - \
  && source /root/.shrc \
  && pnpm --version; \
  fi

# Copy files from pre-builder stage
COPY --from=pre-builder /gems/ /gems/
COPY --from=pre-builder /app /app
COPY --from=pre-builder /app/.git_sha /app/.git_sha

WORKDIR /app

EXPOSE 3000
