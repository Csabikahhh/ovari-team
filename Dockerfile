# syntax=docker/dockerfile:1
#
# Marveen — fully containerized.
#
# This is NOT a tidy one-process service: at runtime the dashboard drives the
# real `claude` CLI inside tmux sessions (one per agent) and screen-scrapes the
# TUI. So the runtime image bakes in `claude` + `tmux` + `bun` and runs a
# multi-process supervisor (dashboard + channels) under tini as PID 1.
#
# See DOCKER.md for the out-of-band steps (Claude token, Telegram pairing).

############################################
# Stage 1 — builder: compile native module + tsc
############################################
FROM node:22-bookworm AS builder

WORKDIR /app

# Toolchain so better-sqlite3 (native N-API addon) compiles if no prebuild
# matches this platform. build is `tsc` (devDependency typescript).
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install with dev deps (typescript/tsc are devDependencies).
COPY package.json package-lock.json ./
RUN npm ci

# Compile TypeScript -> dist/, then drop dev deps so the layer we copy into the
# runtime image is prod-only. better-sqlite3 (a prod dep) and its compiled
# .node binary survive the prune.
COPY . .
RUN npm run build \
    && npm prune --omit=dev

############################################
# Stage 2 — runtime
############################################
FROM node:22-bookworm-slim AS runtime
ENV DEBIAN_FRONTEND=noninteractive

# OS deps the *running app* shells out to:
#  tmux     — every agent + the channels bridge run as tmux sessions
#  lsof     — dashboard port lock (lsof -ti :PORT)
#  procps   — /bin/ps, pgrep (process-tree liveness + orphan-poller reap)
#  python3  — operational heredocs (config seeding, pairing, managed-settings)
#  git/curl/ffmpeg — Claude Code tooling, media (voice notes), plugin install
#  jq       — channels.sh reads the agent model from settings.json
#  tini     — PID 1 zombie reaper (orphan bun pollers outlive tmux kill-session)
#  supervisor — runs dashboard + channels with auto-restart (replaces systemd)
RUN apt-get update && apt-get install -y --no-install-recommends \
      tmux \
      lsof \
      procps \
      python3 \
      git \
      curl \
      ca-certificates \
      ffmpeg \
      jq \
      unzip \
      tini \
      supervisor \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI — the runtime drives this binary inside tmux. Lands on
# /usr/local/bin (npm global), which is on channels.sh's hardcoded PATH.
RUN npm install -g @anthropic-ai/claude-code \
    && claude --version || true

# Bun — the Telegram/Slack channel plugin poller runs as a bun process.
# Installed to /usr/local/bin so it is on PATH for the dashboard and channels.
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash \
    && bun --version

# Managed settings: Claude Code SILENTLY DROPS inbound channel notifications
# from any plugin not listed here (and requires channelsEnabled). Admin-owned
# (root) + world-readable. The Linux installer never writes this — we bake it.
RUN mkdir -p /etc/claude-code
COPY docker/managed-settings.json /etc/claude-code/managed-settings.json
RUN chmod 644 /etc/claude-code/managed-settings.json

# Non-root user is MANDATORY: Claude Code refuses --dangerously-skip-permissions
# when running as root, and both channels.sh and agent spawning use that flag.
# UID/GID 1001 (1000 is taken by the base image's built-in `node` user).
ARG MARVEEN_UID=1001
ARG MARVEEN_GID=1001
RUN groupadd -g ${MARVEEN_GID} marveen \
    && useradd -m -u ${MARVEEN_UID} -g ${MARVEEN_GID} -s /bin/bash marveen

WORKDIR /app

# Built app: dist/, prod node_modules (with compiled better-sqlite3), and the
# source assets the runtime reads (scripts/, templates/, seed-*, skills/, web/,
# docker/). .env / store / agents / .claude are excluded via .dockerignore.
COPY --from=builder --chown=marveen:marveen /app /app

# Persistent-state dirs. A named volume mounted here inherits this ownership on
# first creation, so the strict 0600/0700 file-vault stays consistent.
# Also chown the /app dir node itself: COPY --chown set the *contents* to
# marveen but left the directory root-owned, which blocks the entrypoint from
# creating .env / CLAUDE.md / .claude inside it.
RUN mkdir -p /app/store /app/agents /home/marveen/.claude \
    && chown marveen:marveen /app \
    && chown -R marveen:marveen /app/store /app/agents /home/marveen/.claude \
    && chmod 700 /home/marveen/.claude \
    && ln -sf /app/docker/supervisord.conf /etc/supervisord.conf

ENV HOME=/home/marveen \
    NODE_ENV=production \
    MARVEEN_ENV=linux-server \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    WEB_HOST=0.0.0.0 \
    WEB_PORT=3420 \
    PATH=/home/marveen/.bun/bin:/home/marveen/.local/bin:/usr/local/bin:/usr/bin:/bin

USER marveen
EXPOSE 3420

# tini reaps the orphaned bun pollers that survive `tmux kill-session`.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["bash", "/app/docker/entrypoint.sh"]
