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
ARG OPENCLAW_GIT_REF=v2026.2.24
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
    sudo \
    xz-utils \
    build-essential \
    procps \
    file \
    tini \
    python3 \
    python3-venv \
  && rm -rf /var/lib/apt/lists/*

# `openclaw update` expects pnpm. Provide it in the runtime image.
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# Install Tailscale
RUN curl -fsSL https://tailscale.com/install.sh | sh

# Create non-root runtime user with passwordless sudo
RUN useradd -m -s /bin/bash claw \
  && printf '%s\n' 'claw ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/claw \
  && chmod 0440 /etc/sudoers.d/claw \
  && chown -R claw:claw /home/claw

# Install mise
RUN sudo -u claw -H sh -lc 'curl -fsSL https://mise.run | sh'
ENV PATH="/home/claw/.local/bin:${PATH}"
ENV MISE_CONFIG_DIR="/home/claw"
ENV MISE_GLOBAL_CONFIG_FILE="/home/claw/mise.toml"

# Copy mise config and install tools
COPY --chown=claw:claw docker/mise.toml /home/claw/mise.toml
COPY --chown=claw:claw docker/opencode.jsonc /home/claw/.config/opencode/opencode.json
RUN sudo -u claw -H sh -lc '/home/claw/.local/bin/mise install \
  && /home/claw/.local/bin/mise reshim'

# Install agent-browser dependencies (Chromium + system deps)
RUN sudo -u claw -H sh -lc '/home/claw/.local/bin/mise x npm:agent-browser@latest -- agent-browser install --with-deps'

# Ensure mise shims are on PATH for runtime
ENV PATH="/home/claw/.local/share/mise/shims:${PATH}"

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

# Persist user-installed tools by default by targeting the Railway volume.
# - npm global installs -> /data/npm
# - pnpm global installs -> /data/pnpm (binaries) + /data/pnpm-store (store)
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
ENV PATH="/data/npm/bin:/data/pnpm:${PATH}"

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

# The wrapper listens on $PORT.
# IMPORTANT: Do not set a default PORT here.
# Railway injects PORT at runtime and routes traffic to that port.
# If we force a different port, deployments can come up but the domain will route elsewhere.
EXPOSE 8080

# Ensure PID 1 reaps zombies and forwards signals.
ENV HOME=/home/claw
USER claw
ENTRYPOINT ["tini", "--"]
CMD ["/entrypoint.sh"]
