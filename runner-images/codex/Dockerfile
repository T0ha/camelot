ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

# Node is provided by base via asdf; Codex CLI ships as an npm package.
RUN bash -c "npm install -g @openai/codex"
