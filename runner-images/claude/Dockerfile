ARG BASE_IMAGE=ghcr.io/t0ha/camelot-runner-base:latest

FROM ${BASE_IMAGE}

# Node is provided by base via asdf; Claude Code CLI ships as an npm package.
RUN bash -c "npm install -g @anthropic-ai/claude-code"
