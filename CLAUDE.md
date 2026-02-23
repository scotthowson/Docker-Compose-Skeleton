# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker Compose Skeleton is a modular Docker service orchestration system for managing multiple compose stacks with dependency-ordered startup/shutdown, enhanced logging, NTFY push notifications, and intelligent image updates. It is a Bash-based framework (no build system, no tests) designed to be cloned and configured for any server.

## Critical Issue: Hardcoded Paths

The #1 problem is hardcoded paths throughout the codebase. These files all contain `/home/howson/.Docker-Services` or similar absolute paths that must be made dynamic for portability:

- `setup.sh` — `COMPOSE_DIR` hardcoded
- `start.sh` / `stop.sh` — `BASE_DIR` and `COMPOSE_DIR` hardcoded
- `.scripts/run.sh` — `COMPOSE_DIR`, `BASE_DIR`, `NTFY_URL` hardcoded
- `.scripts/stop.sh` — `COMPOSE_DIR`, `BASE_DIR`, `NTFY_URL` hardcoded (also uses `declare -r` which conflicts with re-sourcing)
- `.scripts/clean-up.sh` — `BASE_DIR` hardcoded to App-Data path
- `.scripts/ntfy-status.sh` — hardcoded container names and NTFY URL
- `.config/settings.cfg` — paths are dynamic via `BASE_DIR` (good), but `BASE_DIR` itself comes from the caller

The intended fix: `BASE_DIR` should be auto-detected from the repo root (via `BASH_SOURCE` or a `.env` file) and all scripts should derive paths from it.

## Architecture

### Execution Flow

```
./start.sh (entry point)
  -> sources .config/settings.cfg (config + color detection + validation)
  -> sources .lib/logger.sh (initializes logging system)
  -> sources .scripts/run.sh, update.sh, update_all_stacks.sh, clean-up.sh
  -> main():
       1. verify_environment() — checks docker, docker-compose, base dirs
       2. initiate_docker_update() — auto-updates docker-compose binary
       3. cleanup_docker_services() — removes unreferenced App-Data volumes
       4. start_docker_services() — starts all 10 stacks in dependency order
       5. update_all_stacks() — pulls latest images, detects changes via SHA256, rolling updates
       6. check_containers_status() — monitors critical containers via NTFY
```

`./stop.sh` mirrors this but only runs `stop_docker_services()` (reverse dependency order).

### Source Dependency Chain

All scripts assume these are sourced first (in order):
1. `.config/settings.cfg` — exports `LOG_LEVEL`, `ENABLE_COLORS`, `LOG_FILE`, all feature flags
2. `.config/palette.sh` — sourced internally by `logger.sh`, provides `COLOR_PALETTE` associative array
3. `.lib/logger.sh` — must call `initiate_logger` after sourcing; provides all `log_*` functions

Scripts in `.scripts/` and `.lib/` are **libraries** (sourced, not executed directly). They rely on `log_*` functions and `$COMPOSE_DIR`/`$BASE_DIR` being set by the caller.

### Stack Management

10 service categories under `Stacks/`, each with `docker-compose.yml` + `.env`:

**Startup order (dependency):** core-infrastructure → networking-security → monitoring-management → development-tools → media-services → web-applications → storage-backup → communication-collaboration → entertainment-personal → miscellaneous-services

**Shutdown order:** exact reverse of startup.

Each stack's `.env` is loaded with `set -a; source .env; set +a` before `docker-compose up`.

### Logger System

The logger (`.lib/logger.sh`, 600+ lines) provides 20+ log functions: `log_info`, `log_success`, `log_warning`, `log_error`, `log_debug`, `log_critical`, plus extended variants (`log_info_header`, `log_focus`, `log_highlight`, etc.) and modifiers (`log_bold_*`, `log_nodate_*`). All output goes to both console (with colors) and `$LOG_FILE` (plain text). The logger must be initialized with `initiate_logger` and cleaned up with `close_logger`.

### Notification System

Uses [NTFY](https://ntfy.sh) for push notifications. `NTFY_URL` is currently hardcoded in `.scripts/run.sh` and `.scripts/stop.sh`. Notifications fire for: service start/failure (critical stacks only), shutdown completion, and container health issues.

## Key Commands

```bash
# Run the full startup sequence (update docker-compose, cleanup, start stacks, pull images)
./start.sh

# Stop all services in reverse dependency order
./stop.sh

# Initial setup (sets permissions on all scripts)
./setup.sh
```

There are no tests, no linter, and no CI pipeline.

## Shell Conventions

- Bash 4+ required (uses associative arrays, `declare -ra`, `${var,,}`)
- Functions prefixed with `_` are private/internal
- All scripts use `#!/bin/bash` shebang
- Config uses `${VAR:-default}` pattern extensively for safe defaults
- `export -f` is used to share functions across sourced scripts
- Color output respects `$ENABLE_COLORS` and `$COLOR_MODE` (auto/always/never)

## Configuration Hierarchy

1. **Defaults** in `.config/settings.cfg` (every setting has a `${VAR:-default}`)
2. **Environment overrides** via `$ENVIRONMENT` variable (development/testing/staging/production) — see the `case` block at the bottom of `settings.cfg`
3. **Per-stack** `.env` files in each `Stacks/<category>/` directory
4. **Runtime** environment variables override everything (e.g., `LOG_LEVEL=DEBUG ./start.sh`)

## Known Issues / Design Debt

- `declare -r` in `.scripts/stop.sh` for `NTFY_URL`/`COMPOSE_DIR`/`BASE_DIR` causes "readonly variable" errors if the script is sourced multiple times
- `.scripts/stop.sh` uses `--volumes` flag on `docker-compose down`, which destroys named volumes (destructive by default)
- `setup.sh` hardcodes user `howson` in `chown` commands
- The wrapper scripts (`start_docker_services.sh`, `stop_docker_services.sh`, `restart_docker_services.sh`) reference the old hardcoded path structure
- `README.md` is outdated (references `./docker-compose/` and `run.sh` instead of current structure)
