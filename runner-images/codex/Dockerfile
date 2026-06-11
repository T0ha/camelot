ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

# Codex CLI ships as an npm package. See claude/Dockerfile for why we
# install under /opt/agent-cli and pin the shebang to the baseline node.
RUN bash -c "npm install --prefix /opt/agent-cli -g @openai/codex \
          && node_ver=\$(awk '/^nodejs/ {print \$2}' /opt/asdf/default-tool-versions) \
          && sed -i \"1s|^#!.*|#!/opt/asdf/installs/nodejs/\${node_ver}/bin/node|\" \
                  \$(readlink -f /opt/agent-cli/bin/codex)"
