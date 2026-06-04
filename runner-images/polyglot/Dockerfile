ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends nodejs npm \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g @anthropic-ai/claude-code @openai/codex

USER agent

# All the common plugins. Versions intentionally NOT pinned globally —
# each repo's .tool-versions wins.
RUN bash -lc " \
      asdf plugin add erlang  https://github.com/asdf-vm/asdf-erlang.git ; \
      asdf plugin add elixir  https://github.com/asdf-vm/asdf-elixir.git ; \
      asdf plugin add nodejs  https://github.com/asdf-vm/asdf-nodejs.git ; \
      asdf plugin add python  https://github.com/danhper/asdf-python.git ; \
      asdf plugin add ruby    https://github.com/asdf-vm/asdf-ruby.git ; \
      asdf plugin add golang  https://github.com/asdf-community/asdf-golang.git ; \
      asdf plugin add rust    https://github.com/code-lever/asdf-rust.git ; \
      true \
    "
