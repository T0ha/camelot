ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

# Kimi Code CLI ships as an npm package that declares
# engines.node >= 22.19.0, newer than the base image's baseline node.
# Rather than bump the base (which would change every stack), install
# a dedicated node for kimi only and pin the `kimi` shebang to it —
# the same pin-the-shebang pattern as claude/Dockerfile, pointing at
# this node instead of the baseline. The CLI version is pinned because
# the `:kimi_jsonl` parser was verified against its stream-json shapes.
#
# The package runs a postinstall and ships native/linux binaries, so
# scripts must run (no --ignore-scripts); its optional native deps
# (node-pty, clipboard) may fail to build, which is fine headless.
ARG KIMI_NODEJS_VERSION=22.20.0
ARG KIMI_CODE_VERSION=2.3.0

RUN bash -c "asdf install nodejs ${KIMI_NODEJS_VERSION} \
          && kimi_node=/opt/asdf/installs/nodejs/${KIMI_NODEJS_VERSION}/bin \
          && PATH=\$kimi_node:\$PATH \$kimi_node/npm install --prefix /opt/agent-cli -g \
                  @moonshot-ai/kimi-code@${KIMI_CODE_VERSION} \
          && sed -i \"1s|^#!.*|#!\$kimi_node/node|\" \
                  \$(readlink -f /opt/agent-cli/bin/kimi)"

# Read-only planning agent: `--plan` cannot be combined with `-p`, so
# planning runs pass `--agent-file` pointing here (see
# Camelot.Agents.KimiDefaults.permission_args_by_stage/0).
COPY --chown=agent:agent planning-agent.md /opt/agent-cli/kimi/planning-agent.md
