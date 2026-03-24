# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker Compose Skeleton is a portable, modular Docker service orchestration framework for managing multiple Compose stacks with dependency-ordered startup/shutdown, enhanced logging, NTFY push notifications, intelligent image updates, and a comprehensive suite of management utilities. It is a Bash-based framework (no build system, no tests) designed to be cloned and configured for any server by any user. All paths are auto-detected from the repository root.

The companion UI repository is at `../Docker-Compose-Skeleton-UI/` — a React/TypeScript Electron + web app with 37 pages that connects to this API server.

## Architecture

### Execution Flow

```
./start.sh (entry point)
  -> auto-detects BASE_DIR from script location (BASH_SOURCE)
  -> loads root .env (user configuration)
  -> sources .config/settings.cfg (config + color detection + validation)
  -> sources .lib/docker-utils.sh (detects docker compose v1 vs v2)
  -> sources .lib/logger.sh (initializes logging system v3.0)
  -> sources .lib/banner.sh (ASCII art banners)
  -> sources .scripts/run.sh, update.sh, update_all_stacks.sh, clean-up.sh
  -> sources .scripts/health-check.sh, system-info.sh (optional)
  -> main():
       1. verify_environment() — checks docker, compose, base dirs
       2. initiate_docker_update() — auto-updates docker-compose binary (v1 only)
       3. cleanup_docker_services() — removes unreferenced resources
       4. start_docker_services() — starts all 10 stacks with progress bars + timing
       5. update_all_stacks() — pulls images, detects changes via SHA256, rolling updates
       6. run_health_check() — comprehensive container health check with formatted table
```

`./stop.sh` mirrors this with `show_shutdown_banner`, `stop_docker_services()` (reverse order), post-shutdown verification, and `show_completion_banner`.

`./restart.sh` runs stop followed by start.

`./status.sh` displays container status across all stacks (standalone, no logger dependency).

### Source Dependency Chain

All scripts assume these are sourced first (in order):
1. Root `.env` — user configuration (loaded via `set -a; source .env; set +a`)
2. `.config/settings.cfg` — exports `LOG_LEVEL`, `ENABLE_COLORS`, `LOG_FILE`, all feature flags
3. `.config/palette.sh` — sourced internally by `logger.sh`, provides `COLOR_PALETTE` associative array
4. `.lib/docker-utils.sh` — detects Docker Compose version, sets `DOCKER_COMPOSE_CMD`
5. `.lib/logger.sh` — must call `initiate_logger` after sourcing; provides all `log_*` functions
6. `.lib/banner.sh` — ASCII art banners (optional, loaded via `_source_optional`)

Scripts in `.scripts/` and `.lib/` are **libraries** (sourced, not executed directly). They rely on `log_*` functions and `$COMPOSE_DIR`/`$BASE_DIR` being set by the caller.

### Stack Management

10 service categories under `Stacks/`, each with `docker-compose.yml` + `.env`:

**Startup order:** core-infrastructure -> networking-security -> monitoring-management -> development-tools -> media-services -> web-applications -> storage-backup -> communication-collaboration -> entertainment-personal -> miscellaneous-services

**Shutdown order:** exact reverse of startup. Batch operations via the API also respect this order.

### API Server (`.scripts/api-server.sh`)

The largest file (~13,400 lines), providing a full REST API over socat. 76+ endpoints across these domains:

| Section | Key Functions | Lines |
|---------|--------------|-------|
| Auth & TOTP | `handle_auth_login`, `handle_totp_setup/verify/validate/disable` | ~500 |
| Compose Scanner | `_api_scan_compose_security` (29 violation checks) | ~250 |
| Container CRUD | `handle_containers`, `handle_container_detail`, batch inspect via jq | ~300 |
| Stack Management | `handle_stacks`, `handle_stack_start/stop`, `handle_batch_stacks` | ~400 |
| Template Deploy | `handle_template_deploy` (auto-routing, DNS, port parsing) | ~500 |
| System Updates | `handle_system_update_check/apply/rollback` (git-based with backup tags) | ~250 |
| Cloudflare DNS | `_cloudflare_add_dns`, zone caching, CNAME creation, bulk cleanup | ~200 |
| DDNS | `_ddns_update_loop` (IP detection, A record updates, route sync) | ~150 |

**Request lifecycle:**
```
socat TCP-LISTEN → _api_handle_connection() → parse HTTP headers/body
  → _api_check_ip_whitelist() → _api_check_rate_limit()
  → _api_check_auth() (Bearer token or API key)
  → route to handler via case statement → _api_success() or _api_error()
```

**Key patterns in the API server:**
- `_api_json_escape "$val"` — always escape before embedding in JSON strings
- `_api_success '{"key": "val"}'` — sends 200 with JSON body + security headers
- `_api_error <code> "message"` — sends error with HTTP status code
- `_api_audit_log "$ip" "EVENT" "$user" "detail"` — append-only audit trail
- `_api_validate_resource_name "$name" "type"` — path traversal prevention
- `_api_check_admin` — enforce admin role for destructive operations
- Docker queries use `docker inspect ... | jq` for reliable parsing (never `|` delimiters)
- `grep -c` must use `$(cmd) || var=0` pattern, NOT `$(cmd || echo 0)` — the latter produces `0\n0`

### Traefik Auto-Routing

When deploying a template with Traefik active:
1. API detects Traefik's `custom_routes/` directory in stack App-Data
2. Parses service ports from compose YAML (extracts container names and port mappings)
3. Generates Traefik v3 dynamic config YAML (router + service + TLS)
4. Writes to `custom_routes/{stack}/{service}.yml`
5. Touches `.reload` marker to trigger Traefik's file watcher
6. Spawns background job to create Cloudflare CNAME (`service.domain → domain`, proxied)
7. DDNS loop periodically syncs missing DNS records for route files

Route files use backtick syntax: `` rule: "Host(`service.domain`)" ``

### Security Architecture

**Authentication:** PBKDF2-SHA256 (100k iterations) with per-user random salt. Legacy SHA-256 accounts auto-upgraded on login. TOTP 2FA optional (RFC 6238, HMAC-SHA1, ±1 time window).

**Compose Scanner:** `_api_scan_compose_security()` blocks: privileged mode, host PID/IPC/network, dangerous capabilities (SYS_ADMIN, NET_ADMIN, SYS_PTRACE), host filesystem mounts (/, /etc, /root, /boot, /var/run, Docker socket), security profile disabling, `build:` directive, variable substitution bypass (`${VAR:-dangerous}`). Two modes: "strict" (user edits) and "deploy" (trusted templates, relaxed).

**Network:** IP whitelist with CIDR matching, per-IP rate limiting (120 req/min default), SSRF protection (blocks private IPs, metadata endpoints), TLS termination, HSTS, CSP, CORS allowlist.

**Sessions:** 256-bit tokens via `/dev/urandom`, configurable expiry (default 24h), single-session enforcement option. Temporary TOTP tokens expire in 5 minutes.

### Logger System (v3.0)

`.lib/logger.sh` (1200+ lines) provides 50+ log functions:

**Core:** `log_info`, `log_success`, `log_warning`, `log_error`, `log_debug`, `log_critical`
**Extended:** `log_info_header`, `log_focus`, `log_highlight`, `log_alert`, etc.
**Variants:** `log_bold_*`, `log_nodate_*`, `log_bold_nodate_*`
**Advanced:** `log_progress`, `log_step`, `log_timer_start/stop`, `log_table`, `log_banner`, `log_keyvalue`, `log_separator`
**Tracking:** `LOG_ERROR_COUNT`, `LOG_WARNING_COUNT`, `LOG_ENTRY_COUNT` (auto-incremented)

### Management Utilities

Standalone scripts in `.scripts/` with their own color setup and `--help`:
- `stack-manager.sh` — CLI for individual stacks (start/stop/restart/status/logs/pull/list/running)
- `health-check.sh` — Container health monitoring with formatted tables
- `config-validator.sh` — Validates config, directories, compose syntax, ports, system requirements
- `maintenance.sh` — Cleanup, disk analysis, orphan detection, log rotation (report/disk/prune/deep-prune/orphans/log-rotate)
- `docker-network-info.sh` — Network visualization with tree-style container connections
- `image-tracker.sh` — Image age tracking and staleness detection
- `system-info.sh` — Docker and system resource information
- `logs-viewer.sh` — Interactive log viewer with filtering and search

## Key Commands

```bash
./start.sh                          # Full startup sequence
./stop.sh                           # Graceful shutdown
./stop.sh --force                   # Force stop (5s timeout)
./restart.sh                        # Stop + Start
./status.sh                         # Container status
./setup.sh                          # First-run setup
./start.sh --debug                  # Debug mode
LOG_LEVEL=DEBUG ./start.sh          # Runtime override

# API server
.scripts/api-server.sh --bind 0.0.0.0  # Start API (external access)
.scripts/api-server.sh --stop           # Stop API
.scripts/api-server.sh --status         # Check if running
bash -n .scripts/api-server.sh          # Syntax check (always run after edits)

# Management utilities
.scripts/stack-manager.sh list      # List all stacks
.scripts/maintenance.sh             # System report
.scripts/config-validator.sh --fix  # Validate & fix config
.scripts/docker-network-info.sh     # Network map
.scripts/image-tracker.sh           # Check image freshness

# Testing API endpoints
TOKEN=$(python3 -c "import json; t=json.load(open('.api-auth/tokens.json')); print(t[0]['token'])" 2>/dev/null)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9876/containers | python3 -m json.tool
```

There are no tests, no linter, and no CI pipeline. After editing `.scripts/api-server.sh`, always run `bash -n .scripts/api-server.sh` to verify syntax.

## Shell Conventions

- Bash 4+ required (associative arrays, `declare -gA`, `${var,,}`)
- Functions prefixed with `_` are private/internal
- All scripts use `#!/bin/bash` shebang
- Config uses `${VAR:-default}` pattern extensively
- `export -f` shares functions across sourced scripts
- Color output respects `$ENABLE_COLORS` and `$COLOR_MODE` (auto/always/never)
- `BASE_DIR` is auto-detected via `BASH_SOURCE` — never hardcoded
- Standalone utilities detect their own `BASE_DIR` relative to script location
- Each standalone script has its own color palette (prefixed `_XX_*` to avoid conflicts)
- Docker data queries must use `jq` for JSON parsing (never parse with `|` or other delimiters — fields can contain unexpected characters)
- `grep -c` returns exit code 1 when count is 0; use `var=$(grep -c PATTERN FILE) || var=0` not `var=$(grep -c PATTERN FILE || echo 0)`

## Configuration Hierarchy

1. **Defaults** in `.config/settings.cfg` (every setting has a `${VAR:-default}`)
2. **Root `.env`** — user-facing configuration (created by `setup.sh` from `.env.example`)
3. **Environment overrides** via `$ENVIRONMENT` variable (development/testing/staging/production)
4. **Per-stack** `.env` files in each `Stacks/<category>/` directory
5. **Runtime** environment variables override everything (e.g., `LOG_LEVEL=DEBUG ./start.sh`)

## File Reference

### Entry Points (executable)
- `start.sh` — Full startup sequence with banners, progress, health check
- `stop.sh` — Graceful shutdown with progress bars, verification, cleanup report
- `restart.sh` — Stop then start wrapper
- `status.sh` — Container status viewer (standalone, no logger)
- `setup.sh` — First-run setup (cross-distro dependency installer)

### Libraries (`.lib/`, sourced)
- `logger.sh` — Enhanced logging system v3.0
- `banner.sh` — ASCII art banners (startup/shutdown/completion/mini)
- `docker-utils.sh` — Docker Compose version detection
- `helpers.sh`, `environment.sh`, `error_handling.sh`, `debugger.sh`
- `metrics.sh` — Metrics collection daemon (CPU, memory, disk, container stats)
- `scheduler.sh` — Cron-like task scheduler daemon
- `secrets.sh` — AES-256-CBC encrypted key-value store
- `sse.sh` — Server-Sent Events streaming for live data
- `health-score.sh` — Container health scoring algorithm
- `rollback.sh` — Compose file rollback snapshots
- `plugins.sh` — Plugin loader and lifecycle hooks

### API Server (`.scripts/api-server.sh`)
- 13,400+ lines, 76+ endpoints, socat-based HTTP server
- Handles all CRUD for stacks, containers, templates, networks, volumes
- Authentication (PBKDF2 + TOTP 2FA), rate limiting, IP whitelist
- Compose security scanner, Traefik auto-routing, Cloudflare DNS
- System updates (git pull --ff-only with backup tags), factory reset
- Terminal WebSocket proxy, metrics collection, backup/restore

### Core Scripts (`.scripts/`, sourced by entry points)
- `run.sh` — Service startup with progress, timers, summary tables
- `stop.sh` — Service shutdown with progress, timers, summary tables
- `update.sh`, `update_all_stacks.sh`, `clean-up.sh`
- `ntfy-status.sh`, `ntfy-status-stop.sh`, `ntfy-status-restart.sh`
- `backup-server.sh`, `wait-for-it.sh`

### Standalone Utilities (`.scripts/`, directly executable)
- `stack-manager.sh` — Individual stack management CLI
- `health-check.sh` — Container health monitoring
- `config-validator.sh` — Configuration validation
- `maintenance.sh` — Docker maintenance & cleanup
- `docker-network-info.sh` — Network visualization
- `image-tracker.sh` — Image update tracking
- `system-info.sh` — System information
- `logs-viewer.sh` — Log viewer with filtering

### Templates (`.templates/`)
- 100 service templates, each with `docker-compose.yml` + `template.json` manifest
- `template.json` defines: name, description, category, icon, required variables, port mappings
- Deploy via API writes to `Stacks/{category}/docker-compose.yml` (merges with existing services)
- Undeploy removes individual services from compose, cleans up routes and DNS

### Runtime Data (not source code — excluded from update checks)
- `.api-auth/` — User accounts, tokens, sessions, audit logs, rate limits
- `.data/` — Metrics, schedules, automations, webhooks, plugins state
- `.compose-history/` — Compose file version snapshots
- `.secrets/` — Encrypted key-value store (AES-256-CBC)
- `logs/` — Application logs and archives
