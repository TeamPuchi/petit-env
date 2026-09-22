# petit-env

## [日本語ページ](./README.md)

A Docker-based umbrella runtime environment for running your own M5 Petit. It wires
[petit-mcp](https://github.com/TeamPuchi/petit-mcp), [petit-app](https://github.com/TeamPuchi/m5-petit-app),
[petit-memory](https://github.com/TeamPuchi/petit-memory), [petit-desire](https://github.com/TeamPuchi/petit-desire),
and [petit-scripts](https://github.com/TeamPuchi/petit-scripts) together in a single container, along with
a cron-equivalent scheduler for autonomous behavior, the dashboard, and memory consolidation.

> **Phase 1 (2026-07): authored, build-untested**
> This repository was written on a development machine without Docker installed.
> `docker build` / `docker compose up` have never actually been run. What has been
> verified so far:
> - YAML syntax (`python -c "import yaml; yaml.safe_load(...)"`)
> - Shell script syntax (`bash -n`)
> - Static sanity of the Dockerfile (manual review, version pinning consistency)
>
> Building and running on a machine with Docker installed is the remaining Phase 1 task.

## Layout

```
docker-compose.yml           # dev: builds from repos/ as the build context
docker-compose.release.yml   # release: prebuilt image (template for future use, planned for Phase 4)
Dockerfile.core               # ubuntu 24.04 + node (claude CLI) + uv + supercronic
.env.example
cron/petit.cron               # crontab for supercronic
scripts/
  sync-repos.sh / .ps1        # clone/pull component repos into repos/
  start.sh / .ps1             # runs sync-repos then docker compose up
  petit.sh                    # update / logs / status / stop
  entrypoint.sh                # container entrypoint (supercronic + dashboard + experience watchdog)
  autonomous-action.sh         # autonomous behavior script (generic, in-container version)
  experience-watchdog.sh       # experience daemon watchdog (Phase 1 placeholder)
  run-for-each-character.sh    # dispatches jobs across CHARACTER_IDS
release/
  start-windows.bat / start-macos.command   # double-click launchers (planned for Phase 4)
  README-for-users.md
sample-character/             # sample character scaffold (no real persona or IPs)
repos/.gitkeep                 # where sync-repos.sh checks out components
```

## Usage (developers, dev mode)

### Requirements

- Docker Desktop or Docker Engine
- Git
- Your own Claude account (subscription or API key)

### Setup

```bash
git clone https://github.com/TeamPuchi/petit-env.git
cd petit-env
cp .env.example .env
# edit .env: CHARACTER_IDS, M5_HOSTS_<ID>, etc.
```

### Start

```bash
./scripts/start.sh
```

This runs `scripts/sync-repos.sh` (clone/pull component repos) followed by `docker compose up --build`.

First time only, in another terminal, authenticate Claude:

```bash
docker compose exec core claude login
```

Once running, the dashboard is at `http://localhost:8765`.

### Day-to-day operations

```bash
./scripts/petit.sh update   # refresh components, rebuild, restart
./scripts/petit.sh logs -f  # follow logs
./scripts/petit.sh status   # container status
./scripts/petit.sh stop     # stop
```

Updates are manual by design — there is no automatic update, so a living petit is never
restarted without you asking for it.

## Creating a character

Copy `sample-character/` into `characters/<id>/` under the host directory that maps to
`PETIT_DATA_DIR` in your `.env`. See [sample-character/README.md](./sample-character/README.md)
for details.

## What runs in the container

| # | Component | How it runs |
|---|---|---|
| 1 | claude CLI + autonomous behavior | supercronic runs it every 20 minutes |
| 2 | MCP servers (m5-mcp / memory / desire-system) | spawned by the claude CLI on demand |
| 3 | Dashboard (petit-app, FastAPI on :8765) | runs as a long-lived process in the container |
| 4 | Desire updater / memory consolidation | scheduled via supercronic |
| 5 | Experience daemon watchdog | Phase 1 placeholder (see "Known limitations" below) |

## Cross-OS support

Designed to work on Windows / macOS / Linux, all via Docker Desktop (or Docker Engine on Linux).
M5 device connectivity is IP-based by default, since mDNS (`.local` hostnames) often can't be
resolved from inside a container.

Voice (TTS/ASR) is designed to work with a CPU fallback, or no voice at all. If you have a GPU
machine, run [m5-petit-speech](https://github.com/PetitOnes/m5-petit-speech) and
[m5-petit-voice-recognition](https://github.com/PetitOnes/m5-petit-voice-recognition) (still
upstream — no TeamPuchi fork yet) there and
point `.env` at their URLs.

## Known limitations (Phase 1)

- **Build-untested**, as noted above.
- **notes-mcp / relations-mcp are not included yet.** There is no repository for either MCP
  server yet, so they're not in `autonomous-action.sh`'s allowedTools (planned to be added
  once available).
- **No published component exists yet for an experience-daemon equivalent.**
  `scripts/experience-watchdog.sh` is a forward-compatible placeholder: it does nothing and
  exits cleanly if the target directory isn't found.
- `docker-compose.release.yml` / `release/*` are templates. The `ghcr.io/teampuchi/petit-core`
  image doesn't exist yet, and `Dockerfile.core` has no COPY step to bake the components in
  (planned for Phase 4).
- **The compose file of record for the EC2 deployment is
  [petit-infra](https://github.com/TeamPuchi/petit-infra)'s `compose/docker-compose.yml`.**
  The two compose files here are kept for local development and as templates.

## License

Apache License 2.0. See [LICENSE](./LICENSE).
