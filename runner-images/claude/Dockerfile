ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

# Claude Code CLI ships as an npm package. Install under /opt/agent-cli
# (on PATH ahead of asdf shims) and pin the script's shebang to the
# image's baseline node — otherwise a per-repo .tool-versions that
# selects a different nodejs would break `claude` ("no preset version
# installed for command claude"), since `npm install -g` makes the
# binary version-bound to the asdf-managed nodejs it was installed on.
RUN bash -c "npm install --prefix /opt/agent-cli -g @anthropic-ai/claude-code \
          && node_ver=\$(awk '/^nodejs/ {print \$2}' /opt/asdf/default-tool-versions) \
          && sed -i \"1s|^#!.*|#!/opt/asdf/installs/nodejs/\${node_ver}/bin/node|\" \
                  \$(readlink -f /opt/agent-cli/bin/claude)"
