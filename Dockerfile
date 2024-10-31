# Base image for pre-build stage
FROM ruby:3.3.3-alpine3.19 AS pre-builder

# ARGs for configuration
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.1.2
ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}
ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}
ARG NODE_OPTIONS="--openssl-legacy-provider"
ENV NODE_OPTIONS=${NODE_OPTIONS}
ENV BUNDLE_PATH="/gems"

# Update packages and install dependencies
RUN apk update && apk add --no-cache \
  openssl \
  tar \
  build-base \
  tzdata \
  postgresql-dev \
  postgresql-client \
  nodejs=20.15.1-r0 \
  git \
  && mkdir -p /var/app \
  && gem install bundler

# Install pnpm and configure environment
RUN wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.shrc" SHELL="$(which sh)" sh - \
    && echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> /root/.shrc \
    && echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.shrc \
    && export PNPM_HOME="/root/.local/share/pnpm" \
    && export PATH="$PNPM_HOME:$PATH" \
    && pnpm --version

# Persist the environment variables in Docker
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

WORKDIR /app

# Copy Gemfile and Gemfile.lock to install gems
COPY Gemfile Gemfile.lock ./

# Install Ruby dependencies and production gems
RUN apk add --no-cache build-base musl ruby-full ruby-dev gcc make musl-dev openssl openssl-dev g++ linux-headers xz vips
RUN bundle config set --local force_ruby_platform true
RUN if [ "$RAILS_ENV" = "production" ]; then \
  bundle config set without 'development test'; bundle install -j 4 -r 3; \
  else bundle install -j 4 -r 3; \
  fi

# Copy package.json and pnpm lockfile to install Node dependencies
COPY package.json pnpm-lock.yaml ./
RUN pnpm install

# Copy app files
COPY . /app

# Create log directory for non-stdout logging
RUN mkdir -p /app/log

# Generate production assets if production environment
RUN if [ "$RAILS_ENV" = "production" ]; then \
  SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled bundle exec rake assets:precompile \
  && rm -rf spec node_modules tmp/cache; \
  fi

# Generate .git_sha file with current commit hash if .git directory exists
RUN if [ -d .git ]; then git rev-parse HEAD > /app/.git_sha; else echo "no-git-sha" > /app/.git_sha; fi

# Remove unnecessary files to reduce image size
RUN rm -rf /gems/ruby/3.3.0/cache/*.gem \
  && find /gems/ruby/3.3.0/gems/ \( -name "*.c" -o -name "*.o" \) -delete \
  && rm -rf .git \
  && rm .gitignore

# Final stage for runtime
FROM ruby:3.3.3-alpine3.19

# ARGs for configuration
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.1.2
ARG EXECJS_RUNTIME="Disabled"
ENV EXECJS_RUNTIME=${EXECJS_RUNTIME}
ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}
ARG BUNDLE_FORCE_RUBY_PLATFORM=1
ENV BUNDLE_FORCE_RUBY_PLATFORM=${BUNDLE_FORCE_RUBY_PLATFORM}
ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}
ENV BUNDLE_PATH="/gems"

# Install runtime dependencies
RUN apk update && apk add --no-cache \
  build-base \
  openssl \
  tzdata \
  postgresql-client \
  imagemagick \
  git \
  vips \
  && gem install bundler

# Additional dependencies and pnpm setup for non-production
RUN if [ "$RAILS_ENV" != "production" ]; then \
  apk add --no-cache nodejs-current; \
  wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.shrc" SHELL="$(which sh)" sh - \
  && source /root/.shrc \
  && pnpm --version; \
  fi

# Copy gems and app files from pre-build stage
COPY --from=pre-builder /gems/ /gems/
COPY --from=pre-builder /app /app

# Copy .git_sha file from pre-builder stage
COPY --from=pre-builder /app/.git_sha /app/.git_sha

WORKDIR /app   

EXPOSE 3000
