ARG CLAUDE_IMAGE=ghcr.io/t0ha/camelot-runner-claude:latest

FROM ${CLAUDE_IMAGE}

USER agent

RUN bash -lc " \
      asdf plugin add python https://github.com/danhper/asdf-python.git && \
      asdf install python 3.12.7 && \
      asdf global  python 3.12.7 && \
      python -m pip install --user --no-cache-dir uv \
    "
