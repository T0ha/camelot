ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

# Google Antigravity CLI (`agy`) ships as a standalone binary via an
# install script that drops it under $HOME/.local/bin. The base image
# runs as `agent` with $HOME on the /home/agent cache volume, which
# would shadow anything installed there at build time, so install
# into a throwaway HOME and move the binary into /opt/agent-cli/bin
# (on PATH ahead of the asdf shims, owned by `agent`).
RUN bash -c "export HOME=/tmp/agy-install \
          && mkdir -p \$HOME /opt/agent-cli/bin \
          && curl -fsSL https://antigravity.google/cli/install.sh | bash \
          && install -m 0755 \"\$(readlink -f \$HOME/.local/bin/agy)\" /opt/agent-cli/bin/agy \
          && rm -rf \$HOME \
          && /opt/agent-cli/bin/agy --version"
