ARG CLAUDE_IMAGE=ghcr.io/t0ha/camelot-runner-claude:latest

FROM ${CLAUDE_IMAGE}

USER agent

RUN bash -c "asdf plugin add python https://github.com/danhper/asdf-python.git"
RUN bash -c "asdf install python 3.12.7"
RUN bash -c "echo 'python 3.12.7' >> /opt/asdf/default-tool-versions \
          && cp /opt/asdf/default-tool-versions \$HOME/.tool-versions"
# Install uv into the asdf-managed python (under /opt/asdf) instead of
# --user (which writes /home/agent/.local — shadowed by the profile
# volume). Reshim so `uv` resolves through the asdf shim at runtime.
RUN bash -c "python -m pip install --no-cache-dir uv"
RUN bash -c "asdf reshim python"
