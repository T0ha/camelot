ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

USER agent

# AI agent CLIs ship as npm packages. See claude/Dockerfile for why we
# install under /opt/agent-cli and pin shebangs to the baseline node.
RUN bash -c "npm install --prefix /opt/agent-cli -g @anthropic-ai/claude-code @openai/codex \
          && node_ver=\$(awk '/^nodejs/ {print \$2}' /opt/asdf/default-tool-versions) \
          && sed -i \"1s|^#!.*|#!/opt/asdf/installs/nodejs/\${node_ver}/bin/node|\" \
                  \$(readlink -f /opt/agent-cli/bin/claude) \
                  \$(readlink -f /opt/agent-cli/bin/codex)"

# All the common plugins. Versions intentionally NOT pinned globally —
# each repo's .tool-versions wins. nodejs plugin is already added by the base image.
RUN bash -c "asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git"
RUN bash -c "asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git"
RUN bash -c "asdf plugin add python https://github.com/danhper/asdf-python.git"
RUN bash -c "asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git"
RUN bash -c "asdf plugin add golang https://github.com/asdf-community/asdf-golang.git"
RUN bash -c "asdf plugin add rust https://github.com/code-lever/asdf-rust.git"
