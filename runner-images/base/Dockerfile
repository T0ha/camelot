# Multi-arch base. Build with `docker buildx --platform linux/amd64,linux/arm64`.
ARG DEBIAN_VERSION=trixie-slim

FROM docker.io/debian:${DEBIAN_VERSION}

# Auto-set by buildx (linux/amd64 → amd64, linux/arm64 → arm64).
# Falls back to dpkg if the build is run plainly (no buildx).
ARG TARGETARCH
ARG ASDF_VERSION=v0.14.1
ARG GH_VERSION=2.62.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    HOME=/home/agent \
    ASDF_DIR=/home/agent/.asdf \
    ASDF_DATA_DIR=/home/agent/.asdf \
    PATH=/home/agent/.asdf/shims:/home/agent/.asdf/bin:/home/agent/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

# Non-root user for the agent runtime
RUN useradd --create-home --shell /bin/bash --uid 1000 agent \
 && mkdir -p /workspace \
 && chown -R agent:agent /workspace /home/agent

USER agent
WORKDIR /home/agent

# asdf
RUN git clone --depth 1 --branch ${ASDF_VERSION} https://github.com/asdf-vm/asdf.git ${ASDF_DIR}
RUN echo '. "$HOME/.asdf/asdf.sh"' >> /home/agent/.bashrc

# Baseline MCP config directory expected by entrypoint
RUN mkdir -p /home/agent/.config/camelot
COPY --chown=agent:agent mcp.defaults.json /etc/camelot/mcp.defaults.json

# Entrypoint + per-exec wrapper
COPY --chown=root:root entrypoint.sh /entrypoint.sh
COPY --chown=root:root exec-wrapper.sh /exec-wrapper.sh
USER root
RUN chmod +x /entrypoint.sh /exec-wrapper.sh
USER agent

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
CMD ["bash", "-l"]
