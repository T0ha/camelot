ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

USER agent

# Node is provided by base via asdf; AI agent CLIs ship as npm packages.
RUN bash -c "npm install -g @anthropic-ai/claude-code @openai/codex"

# All the common plugins. Versions intentionally NOT pinned globally —
# each repo's .tool-versions wins. nodejs plugin is already added by the base image.
RUN bash -c "asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git"
RUN bash -c "asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git"
RUN bash -c "asdf plugin add python https://github.com/danhper/asdf-python.git"
RUN bash -c "asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git"
RUN bash -c "asdf plugin add golang https://github.com/asdf-community/asdf-golang.git"
RUN bash -c "asdf plugin add rust https://github.com/code-lever/asdf-rust.git"
