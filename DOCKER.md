# Running Marveen in Docker

Marveen can run **fully containerized**, but it is not a tidy single-process
service. At runtime the dashboard drives the real `claude` CLI **inside tmux
sessions** (one per agent) and screen-scrapes the TUI to deliver prompts and
recover sessions. So the image bakes in `claude` + `tmux` + `bun` and runs a
multi-process supervisor (`dashboard` + `channels`) under `tini` as PID 1.

Two things **cannot** be baked into the image and must be provided by you:

1. **A Claude credential** — it needs a browser to mint and there is no
   in-container login. You generate it once elsewhere and inject it.
2. **Channel pairing** — you DM the bot once after the container is up.

---

## What's in this setup

| File | Purpose |
|------|---------|
| `Dockerfile` | Multi-stage build. Builder compiles `better-sqlite3` + `tsc`; runtime stage adds `claude`, `tmux`, `bun`, `python3`, `supervisor`, `tini`, runs as non-root `marveen`. |
| `docker/entrypoint.sh` | Materializes `.env`, `CLAUDE.md`, `SOUL.md`, channel `access.json` and `~/.claude` seeds from env vars (the non-interactive slice of `install-linux.sh`), then execs supervisord. |
| `docker/supervisord.conf` | Runs `node dist/index.js` (dashboard) + `bash scripts/channels.sh` with auto-restart. |
| `docker/managed-settings.json` | Baked to `/etc/claude-code/managed-settings.json`. Without it Claude Code **silently drops** inbound channel messages. The Linux installer never writes this — the container fixes that gap. |
| `docker-compose.yml` | `marveen` service + optional `ollama` sidecar + named volumes. |
| `.env.docker.example` | Template for your secrets/config. |

---

## Prerequisites

- Docker Engine + Compose v2 (`docker compose version`).
- A Claude **Pro/Max** subscription (for an OAuth token) **or** an Anthropic
  Console API key.
- A Telegram bot token (from [@BotFather](https://t.me/BotFather) → `/newbot`),
  or a Slack app.

---

## Step 1 — Get a Claude credential (out-of-band)

On a machine **with a browser**:

```bash
claude setup-token
```

Copy the printed `sk-ant-oat01-…` token. (Alternatively use an Anthropic
Console API key `sk-ant-…`.) The token is valid ~1 year.

## Step 2 — Configure

```bash
cp .env.docker.example .env.docker
```

Edit `.env.docker` and set at minimum:

- `CLAUDE_CODE_OAUTH_TOKEN=` (the token from step 1) — **or** `ANTHROPIC_API_KEY=`, not both
- `TELEGRAM_BOT_TOKEN=` (your BotFather token)
- `OWNER_NAME=`, `BOT_NAME=`
- `DASHBOARD_TOKEN=` (a long random string — the dashboard is exposed on `0.0.0.0`)

## Step 3 — Build & start

```bash
docker compose build
docker compose up -d
docker compose logs -f marveen      # watch it come up
```

## Step 4 — (Optional) semantic memory model

Memory works without it (degrades to FTS5 keyword search), but for parity:

```bash
docker compose exec ollama ollama pull nomic-embed-text
```

## Step 5 — Open the dashboard

The startup token URL is in the logs, or build it from your `DASHBOARD_TOKEN`:

```
http://localhost:3420/?token=<DASHBOARD_TOKEN>
```

## Step 6 — Pair your Telegram bot

This is the one manual post-launch step (it can't happen at build time):

1. Open Telegram and message your bot anything (e.g. "Szia").
2. The bot replies with a pairing code.
3. Either complete pairing from the **dashboard**, or run the
   `telegram:access` skill, or set the numeric chat id as `ALLOWED_CHAT_ID`
   in `.env.docker` and `docker compose up -d` again.

Pairing is stored in the `marveen-claude` volume (`access.json`) and survives
restarts. The entrypoint also auto-recovers the paired chat id, so you can
leave `ALLOWED_CHAT_ID=0`.

---

## Operating it

```bash
# Logs
docker compose logs -f marveen
docker compose exec marveen tail -f /app/store/channels.log

# Supervisor status / restart a service (config is symlinked to the default path)
docker compose exec marveen supervisorctl status
docker compose exec marveen supervisorctl restart channels

# Attach to the live agent TUI (the actual Claude Code session)
docker compose exec marveen tmux ls
docker compose exec marveen tmux attach -t marveen-channels    # Ctrl-b d to detach

# Stop / start
docker compose down            # keeps volumes (state persists)
docker compose up -d
```

### Persistent state (named volumes)

| Volume | Holds | If lost |
|--------|-------|---------|
| `marveen-store` | SQLite DB, **vault key** (`.vault-key`), dashboard token, logs | All stored secrets become **unrecoverable**. |
| `marveen-claude` | Installed plugins, **channel pairing**, Claude sessions | Re-install plugin + re-pair. |
| `marveen-agents` | Per-agent scaffolds | Sub-agents need re-creating. |
| `marveen-ollama` | Pulled embedding model | Re-pull. |

Back these up if the deployment matters. The container runs as a fixed UID
(1001 — the `marveen` user; 1000 is the base image's built-in `node` user).
Don't change `MARVEEN_UID` after first run or it will lose access to its own
volumes.

---

## Honest caveats

- **TUI screen-scraping is version-sensitive.** The dashboard parses the live
  Claude Code TUI footer with regexes and types prompts via `tmux send-keys`.
  A Claude Code CLI update that changes the TUI/onboarding flow can break
  prompt delivery inside the container. To pin a known-good CLI, edit the
  Dockerfile: `npm install -g @anthropic-ai/claude-code@<version>`.
- **It's a "pet" container, not a stateless microservice.** One container runs
  a tmux server, the dashboard, the channels bridge, bun pollers, and N agent
  sessions. You can't scale it horizontally / run replicas.
- **Teardown isn't perfectly clean.** Orphan bun pollers can survive
  `tmux kill-session`; `tini` reaps them as PID 1, but Telegram allows only one
  long-poll per bot token, so a leaked poller can cause transient 409s until
  reaped.
- **Token lifecycle is manual.** `CLAUDE_CODE_OAUTH_TOKEN` expires (~1 year);
  re-mint on a browser machine and update `.env.docker`.
- **Some browser-OAuth MCP connectors** are awkward headless and are
  effectively skipped in a container (API-key / remote-OAuth MCPs still work).
- **Unofficial.** The project ships no Dockerfile; the supported deployments
  are bare-metal Linux (systemd) / macOS (launchd). This container glue is
  maintained here, separate from upstream.

---

## Why these specific choices (for maintainers)

- **Non-root is mandatory** — Claude Code refuses `--dangerously-skip-permissions`
  as root, and both `channels.sh` and agent spawning use that flag.
- **`node dist/index.js`, not `bun src/web/serve.ts`** — `start.sh`'s container
  fallback points at a file that doesn't exist in the repo.
- **`claude` on `/usr/local/bin`, `bun` on `/usr/local/bin`** — both are on the
  hardcoded `PATH` in `scripts/channels.sh`.
- **`managed-settings.json` at build time** — replaces the runtime `sudo` step
  the dashboard would otherwise prompt for, so inbound channel messages aren't
  dropped.
- **`TERM=xterm-256color`** — so the TUI renders the footer strings the
  dashboard's state detectors match against.
