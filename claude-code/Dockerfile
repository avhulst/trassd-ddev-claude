# Build a minimal "claude-only" image whose sole job is to be a COPY source
# for a DDEV web-build Dockerfile (COPY --from=...).
#
# Stage 1 installs the Claude Code CLI via npm and extracts the single,
# self-contained binary. Stage 2 is a slim carrier that holds only that binary
# (and shares the glibc family of DDEV's Debian-based webserver image).

# ---- Stage 1: install -------------------------------------------------------
FROM node:22-bookworm-slim AS build

# Pinned by the CI workflow to the exact published version for reproducibility.
ARG CLAUDE_VERSION=latest

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
 # resolve the real single-file binary (the global `claude` is a symlink to it)
 && cp "$(readlink -f "$(command -v claude)")" /claude \
 && chmod 755 /claude \
 && /claude --version

# ---- Stage 2: minimal carrier ----------------------------------------------
FROM debian:bookworm-slim

COPY --from=build /claude /usr/local/bin/claude

# Smoke test: prove the binary runs in a slim Debian (same glibc as ddev-webserver).
RUN /usr/local/bin/claude --version

# This image is only ever used as a COPY source, but keeping it runnable lets you
# verify it with:  docker run --rm <image> claude --version
ENTRYPOINT ["/usr/local/bin/claude"]
