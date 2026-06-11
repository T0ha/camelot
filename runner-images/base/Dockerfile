# Multi-arch base. Build with `docker buildx --platform linux/amd64,linux/arm64`.
ARG DEBIAN_VERSION=trixie-slim

FROM docker.io/debian:${DEBIAN_VERSION}

# Auto-set by buildx (linux/amd64 → amd64, linux/arm64 → arm64).
# Falls back to dpkg if the build is run plainly (no buildx).
ARG TARGETARCH
ARG ASDF_VERSION=v0.14.1
ARG GH_VERSION=2.62.0
ARG NODEJS_VERSION=22.11.0

# asdf and npm caches live under /opt — the per-task profile volume is
# mounted at /home/agent and would shadow anything baked under $HOME.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    HOME=/home/agent \
    ASDF_DIR=/opt/asdf \
    ASDF_DATA_DIR=/opt/asdf \
    npm_config_cache=/opt/npm-cache \
    PATH=/opt/asdf/shims:/opt/asdf/bin:/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gnupg \
      jq \
      tini \
      sudo \
      build-essential \
      autoconf \
      bison \
      unzip \
      libssl-dev \
      libreadline-dev \
      zlib1g-dev \
      libncurses-dev \
      libffi-dev \
      libyaml-dev \
      libxml2-dev \
      libxslt1-dev \
      openssh-client \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI (gh) — multi-arch download
RUN ARCH="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.deb" -o /tmp/gh.deb \
 && dpkg -i /tmp/gh.deb \
 && rm /tmp/gh.deb

# Non-root user for the agent runtime. /opt/asdf and /opt/npm-cache are
# pre-owned by agent so plugin/version installs work without sudo.
RUN useradd --create-home --shell /bin/bash --uid 1000 agent \
 && mkdir -p /workspace /opt/asdf /opt/npm-cache \
 && chown -R agent:agent /workspace /home/agent /opt/asdf /opt/npm-cache

USER agent
WORKDIR /home/agent

# asdf installs into /opt/asdf — outside the /home/agent cache volume.
RUN git clone --depth 1 --branch ${ASDF_VERSION} https://github.com/asdf-vm/asdf.git ${ASDF_DIR}

# Node.js — most AI agent CLIs (Claude Code, Codex, gemini-cli, etc.) ship as npm
# packages, so a baseline node lives here. Repos with .tool-versions override it.
RUN bash -c "asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git"
RUN bash -c "asdf install nodejs ${NODEJS_VERSION}"
# /opt/asdf/default-tool-versions is the single source of truth for the
# image's default versions. It survives the profile volume and is copied
# into $HOME/.tool-versions both at image build time (so downstream RUN
# steps resolve the asdf shims) and at runtime by the entrypoint (when
# the cache volume is empty). Derived images append to it.
RUN bash -c "echo 'nodejs ${NODEJS_VERSION}' > /opt/asdf/default-tool-versions \
          && cp /opt/asdf/default-tool-versions \$HOME/.tool-versions"

# Baseline MCP config directory expected by entrypoint
RUN mkdir -p /home/agent/.config/camelot
COPY --chown=agent:agent mcp.defaults.json /etc/camelot/mcp.defaults.json

# Entrypoint + per-exec wrapper. --chmod=0755 because the git-tracked
# mode is 100644 and `tini` exec's these directly.
COPY --chmod=0755 --chown=agent:agent entrypoint.sh /entrypoint.sh
COPY --chmod=0755 --chown=agent:agent exec-wrapper.sh /exec-wrapper.sh

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["bash", "-l"]
