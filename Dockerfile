# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN corepack enable

WORKDIR /openclaw

# Pin to a known-good ref (tag/branch). Override in Railway template settings if needed.
# Using a released tag avoids build breakage when `main` temporarily references unpublished packages.
ARG OPENCLAW_GIT_REF=v2026.2.9
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

# Install all system dependencies in a single layer
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    xz-utils \
    build-essential \
    procps \
    file \
  && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Install mise
RUN curl -fsSL https://mise.run | sh
ENV PATH="/root/.local/bin:${PATH}"
ENV MISE_CONFIG_DIR="/root"
ENV MISE_GLOBAL_CONFIG_FILE="/root/mise.toml"

# Copy mise config and install tools
COPY docker/mise.toml /root/mise.toml
COPY docker/opencode.jsonc /root/.config/opencode/opencode.json
RUN mise install \
  && mise reshim \
  && mise exec -- bun --version \
  && mise exec -- opencode --version \
  && mise exec -- codex --version \
  && mise exec -- claude --version

# Install agent-browser dependencies (Chromium + system deps)
RUN mise exec -- agent-browser install --with-deps

# Ensure mise shims are on PATH for runtime
ENV PATH="/root/.local/share/mise/shims:${PATH}"

# Create linuxbrew user and install Homebrew
RUN useradd -m -s /bin/bash linuxbrew \
  && mkdir -p /home/linuxbrew/.linuxbrew \
  && chown -R linuxbrew:linuxbrew /home/linuxbrew

# Install Homebrew as linuxbrew user
USER linuxbrew
RUN /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Add Homebrew to PATH for all users
ENV PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"

# Install common dev tools via Homebrew (as linuxbrew user)
RUN brew install \
    wget \
    jq \
    yq \
    ripgrep \
    fd \
    fzf \
    gh \
    vim \
    tmux \
  && brew cleanup \
  && brew --version

# Switch back to root for remaining setup
USER root

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src

# Copy and enable entrypoint script (starts Tailscale + app)
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
CMD ["/entrypoint.sh"]
