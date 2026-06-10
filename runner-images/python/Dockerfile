ARG CLAUDE_IMAGE=ghcr.io/t0ha/camelot-runner-claude:latest

FROM ${CLAUDE_IMAGE}

USER agent

RUN bash -c "asdf plugin add python https://github.com/danhper/asdf-python.git"
RUN bash -c "asdf install python 3.12.7"
RUN bash -c "asdf global python 3.12.7"
RUN bash -c "python -m pip install --user --no-cache-dir uv"
