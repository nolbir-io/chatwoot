# pre-build stage
FROM ruby:3.3.3-alpine3.19 AS pre-builder

# ARG default to production settings
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.1.2
ENV BUNDLE_PATH="/gems"

# Set environment variables for Rails
ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}

ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}

ARG NODE_OPTIONS="--openssl-legacy-provider"
ENV NODE_OPTIONS=${NODE_OPTIONS}

# Set the working directory
WORKDIR /app

# Install required packages and gem dependencies
RUN apk update && apk add --no-cache \
  openssl \
  build-base \
  postgresql-dev \
  git \
  tzdata \
  && gem install bundler

# Copy only the Gemfile and Gemfile.lock first for caching
COPY Gemfile Gemfile.lock ./

# Install gems
RUN bundle install --jobs=4 --retry=3 --without development test

# Install pnpm and configure environment
RUN wget -qO- https://get.pnpm.io/install.sh | ENV="$HOME/.shrc" SHELL="$(which sh)" sh - \
    && echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> /root/.shrc \
    && echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.shrc \
    && export PNPM_HOME="/root/.local/share/pnpm" \
    && export PATH="$PNPM_HOME:$PATH"

# Persist the environment variables in Docker
ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

# Install npm dependencies
COPY package.json pnpm-lock.yaml ./
RUN pnpm install

# Copy the rest of the application code
COPY . .

# Creating a log directory to avoid errors when RAILS_LOG_TO_STDOUT is false
RUN mkdir -p /app/log

# Generate production assets if in production environment
RUN if [ "$RAILS_ENV" = "production" ]; then \
  SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled bundle exec rake assets:precompile \
  && rm -rf spec node_modules tmp/cache; \
  fi

# Generate .git_sha file with the current commit hash
RUN git rev-parse HEAD > /app/.git_sha

# Remove unnecessary files to reduce image size
RUN rm -rf /gems/ruby/3.3.0/cache/*.gem \
  && find /gems/ruby/3.3.0/gems/ \( -name "*.c" -o -name "*.o" \) -delete \
  && rm -rf .git \
  && rm .gitignore

# final build stage
FROM ruby:3.3.3-alpine3.19

# Set environment variables for final stage
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

# Install required packages
RUN apk update && apk add --no-cache \
  build-base \
  postgresql-client \
  imagemagick \
  git \
  vips \
  && gem install bundler

# Copy installed gems and application code from pre-builder stage
COPY --from=pre-builder /gems/ /gems/
COPY --from=pre-builder /app /app

# Copy .git_sha file from pre-builder stage
COPY --from=pre-builder /app/.git_sha /app/.git_sha

# Set the working directory
WORKDIR /app

# Expose the application port
EXPOSE 3000

# Command to start your application (adjust as necessary)
CMD ["rails", "server", "-b", "0.0.0.0"]
