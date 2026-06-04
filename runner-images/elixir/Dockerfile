ARG CLAUDE_IMAGE=ghcr.io/t0ha/camelot-runner-claude:latest

FROM ${CLAUDE_IMAGE}

USER agent

# Stock plugins; concrete versions come from each repo's .tool-versions
RUN bash -lc " \
      asdf plugin add erlang  https://github.com/asdf-vm/asdf-erlang.git && \
      asdf plugin add elixir  https://github.com/asdf-vm/asdf-elixir.git && \
      asdf plugin add nodejs  https://github.com/asdf-vm/asdf-nodejs.git \
    "

# A reasonable default so an empty .tool-versions still works
RUN bash -lc " \
      asdf install erlang 27.1 && \
      asdf install elixir 1.18.0-otp-27 && \
      asdf global  erlang 27.1 && \
      asdf global  elixir 1.18.0-otp-27 \
    "
