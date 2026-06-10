ARG CLAUDE_IMAGE=ghcr.io/t0ha/camelot-runner-claude:latest

FROM ${CLAUDE_IMAGE}

USER agent

# Stock plugins; concrete versions come from each repo's .tool-versions.
# nodejs plugin is already added by the base image.
RUN bash -c "asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git"
RUN bash -c "asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git"

# A reasonable default so an empty .tool-versions still works
RUN bash -c "asdf install erlang 27.1"
RUN bash -c "asdf install elixir 1.18.0-otp-27"
RUN bash -c "asdf global erlang 27.1"
RUN bash -c "asdf global elixir 1.18.0-otp-27"
