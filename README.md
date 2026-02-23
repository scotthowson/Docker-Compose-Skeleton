# Docker Compose Skeleton

A modular Docker service orchestration framework for managing multiple Compose stacks with dependency-ordered startup/shutdown, enhanced logging, NTFY push notifications, intelligent image updates, and a full suite of management utilities.

Clone it, configure it, run it — from any directory, by any user.

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/your-user/Docker-Compose-Skeleton.git
cd Docker-Compose-Skeleton

# 2. Run initial setup
./setup.sh

# 3. Edit your configuration
nano .env

# 4. Start all services
./start.sh

# 5. Check status
./status.sh
```

## Commands

### Core Operations

| Command | Description |
|---------|-------------|
| `./setup.sh` | First-run setup — creates `.env`, directories, sets permissions |
| `./start.sh` | Start all services in dependency order with updates and health checks |
| `./stop.sh` | Stop all services in reverse dependency order |
| `./restart.sh` | Stop then start all services |
| `./status.sh` | Show container status across all stacks |

### Management Utilities

| Script | Description |
|--------|-------------|
| `.scripts/stack-manager.sh` | CLI for managing individual stacks (start/stop/restart/status/logs/pull) |
| `.scripts/health-check.sh` | Comprehensive container health monitoring with formatted tables |
| `.scripts/config-validator.sh` | Validates all config files, directories, and system requirements |
| `.scripts/maintenance.sh` | Docker cleanup, disk analysis, log rotation, orphan detection |
| `.scripts/docker-network-info.sh` | Visualize Docker networks, connections, and port mappings |
| `.scripts/image-tracker.sh` | Track image age and detect stale images across stacks |
| `.scripts/system-info.sh` | System and Docker resource information |
| `.scripts/logs-viewer.sh` | Interactive log viewer with filtering, search, and stats |

### Flags

| Flag | Available on | Description |
|------|-------------|-------------|
| `--help` | All scripts | Show usage information |
| `--debug` | `start.sh`, `stop.sh` | Debug logging + bash trace |
| `--force` | `stop.sh` | Force stop with 5s timeout |
| `--fix` | `config-validator.sh` | Auto-fix common issues |
| `--json` | Multiple utilities | JSON output |
| `--quiet` | Multiple utilities | Minimal output |

### Stack Manager Examples

```bash
# Manage individual stacks
.scripts/stack-manager.sh list                          # List all stacks
.scripts/stack-manager.sh start core-infrastructure     # Start one stack
.scripts/stack-manager.sh status web-applications       # Detailed status
.scripts/stack-manager.sh logs media-services --follow   # Live logs
.scripts/stack-manager.sh pull monitoring-management    # Pull latest images
.scripts/stack-manager.sh running                       # Show running stacks
```

### Maintenance Examples

```bash
# System maintenance
.scripts/maintenance.sh                  # Full system report
.scripts/maintenance.sh disk             # Disk usage breakdown
.scripts/maintenance.sh prune            # Safe cleanup
.scripts/maintenance.sh deep-prune       # Aggressive cleanup (interactive)
.scripts/maintenance.sh orphans          # Find orphaned resources
.scripts/maintenance.sh log-rotate       # Rotate log files

# Validate your setup
.scripts/config-validator.sh             # Check everything
.scripts/config-validator.sh --fix       # Auto-fix issues

# Network inspection
.scripts/docker-network-info.sh          # Network overview
.scripts/docker-network-info.sh --ports  # Include port mappings

# Image tracking
.scripts/image-tracker.sh               # Check all images
.scripts/image-tracker.sh --quick       # Only show stale images
```

## Configuration

### Root `.env`

The main configuration file. Copy from `.env.example` on first run (or let `setup.sh` handle it):

| Variable | Default | Description |
|----------|---------|-------------|
| `APP_DATA_DIR` | `./App-Data` | Persistent container data directory |
| `PUID` / `PGID` | `1000` | User/Group IDs for file permissions |
| `PROXY_DOMAIN` | `example.com` | Domain for reverse proxy routing |
| `TZ` | `UTC` | Timezone for all containers |
| `NTFY_URL` | *(empty)* | NTFY notification endpoint |
| `SERVER_NAME` | `Docker Server` | Server name in notifications |
| `PORTAINER_URL` | *(empty)* | Portainer dashboard URL |
| `DOCKER_COMPOSE_VERSION` | `auto` | `auto`, `v1`, or `v2` |
| `REMOVE_VOLUMES_ON_STOP` | `false` | Remove named volumes on stop |
| `CONTINUE_ON_FAILURE` | `true` | Continue if a stack fails |
| `SKIP_HEALTHCHECK_WAIT` | `false` | Skip `--wait` flag on startup |
| `CRITICAL_CONTAINERS` | *(empty)* | Comma-separated critical containers |
| `IMPORTANT_CONTAINERS` | *(empty)* | Comma-separated important containers |
| `BACKUP_SOURCE_DIR` | *(empty)* | Backup source path |
| `BACKUP_DEST_DIR` | *(empty)* | Backup destination path |
| `BACKUP_RETENTION_COUNT` | `6` | Number of backups to keep |

### Advanced Settings (`.config/settings.cfg`)

| Category | Key Settings |
|----------|-------------|
| **Startup Behavior** | `SHOW_STARTUP_BANNER`, `SHOW_SYSTEM_INFO`, `SERVICE_START_DELAY`, `STACK_START_TIMEOUT` |
| **Health Checks** | `ENABLE_POST_STARTUP_HEALTH_CHECK`, `HEALTH_CHECK_DELAY`, `INCLUDE_RESOURCE_METRICS` |
| **Logging** | `LOG_LEVEL`, `LOG_DATE_FORMAT`, `LOG_MAX_SIZE`, `LOG_BACKUP_COUNT`, `LOG_RETENTION_DAYS` |
| **Colors** | `COLOR_MODE` (auto/always/never), `COLOR_THEME` (dark/light/high-contrast) |
| **Docker** | `DOCKER_TIMEOUT`, `SERVICE_START_DELAY`, `SERVICE_STOP_DELAY`, `MAX_PARALLEL_OPERATIONS` |
| **Notifications** | `ENABLE_NOTIFICATIONS`, `NOTIFICATION_LEVELS`, `WEBHOOK_URL`, `EMAIL_ALERTS` |

### Per-Stack `.env`

Each stack in `Stacks/` has its own `.env` for stack-specific overrides. By default they inherit from the root `.env`.

### Environment Overrides

Set `ENVIRONMENT` to change behavior profiles:

| Environment | Effect |
|------------|--------|
| `production` | Default. INFO logging, notifications on. |
| `development` | DEBUG logging, verbose mode, function tracing |
| `testing` | DEBUG logging, mocked external calls |
| `staging` | INFO logging, notifications + metrics on |

Runtime override: `LOG_LEVEL=DEBUG ./start.sh`

## Architecture

### Directory Structure

```
Docker-Compose-Skeleton/
├── start.sh                    # Main entry point (startup sequence)
├── stop.sh                     # Graceful shutdown
├── restart.sh                  # Stop + Start wrapper
├── status.sh                   # Container status viewer
├── setup.sh                    # First-run setup
├── .env.example                # Configuration template
├── .env                        # Your configuration (gitignored)
├── .config/
│   ├── settings.cfg            # Application settings & defaults
│   └── palette.sh              # Terminal color palette system
├── .lib/
│   ├── logger.sh               # Enhanced logging system (v3.0)
│   ├── banner.sh               # ASCII art banner library
│   ├── docker-utils.sh         # Docker Compose detection
│   ├── helpers.sh              # Utility functions
│   ├── environment.sh          # Environment verification
│   ├── error_handling.sh       # Graceful error handling
│   └── debugger.sh             # Debug mode support
├── .scripts/
│   ├── run.sh                  # Service startup library (v3.0)
│   ├── stop.sh                 # Service shutdown library (v3.0)
│   ├── health-check.sh         # Container health monitoring
│   ├── stack-manager.sh        # Individual stack management CLI
│   ├── config-validator.sh     # Configuration validator
│   ├── maintenance.sh          # Docker maintenance & cleanup
│   ├── docker-network-info.sh  # Network visualization
│   ├── image-tracker.sh        # Image update tracker
│   ├── system-info.sh          # System information reporter
│   ├── logs-viewer.sh          # Interactive log viewer
│   ├── update.sh               # Docker Compose updater
│   ├── update_all_stacks.sh    # Intelligent stack updater
│   ├── clean-up.sh             # Unused volume cleanup
│   ├── backup-server.sh        # Backup system
│   ├── ntfy-status.sh          # Start status notifications
│   ├── ntfy-status-stop.sh     # Stop status notifications
│   ├── ntfy-status-restart.sh  # Restart status notifications
│   └── wait-for-it.sh          # TCP port availability checker
├── Stacks/
│   ├── core-infrastructure/    # Redis (placeholder)
│   ├── networking-security/    # Whoami (placeholder)
│   ├── monitoring-management/  # Alpine heartbeat
│   ├── development-tools/      # Alpine uptime counter
│   ├── media-services/         # Nginx static page (:8081)
│   ├── web-applications/       # Nginx static page (:8082)
│   ├── storage-backup/         # Alpine file writer
│   ├── communication-collaboration/  # Alpine heartbeat
│   ├── entertainment-personal/ # Alpine heartbeat
│   └── miscellaneous-services/ # Alpine healthcheck demo
├── App-Data/                   # Container volumes (gitignored)
└── logs/                       # Log files (gitignored)
```

### Startup Order (Dependency Chain)

```
1. core-infrastructure          6. web-applications
2. networking-security          7. storage-backup
3. monitoring-management        8. communication-collaboration
4. development-tools            9. entertainment-personal
5. media-services              10. miscellaneous-services
```

Shutdown runs in exact reverse order.

### Startup Sequence

When you run `./start.sh`, this happens:

1. **Environment verification** — checks Docker, Compose, directories
2. **Docker Compose update** — auto-updates the binary (v1 only; v2 is package-managed)
3. **Volume cleanup** — removes unreferenced resources
4. **Service startup** — starts all 10 stacks in dependency order with progress bars and per-stack timing
5. **Image updates** — pulls latest images, detects changes via SHA256, rolling restart
6. **Health monitoring** — comprehensive container health check with color-coded status table

### Logger System

The Enhanced Logger (v3.0, 1200+ lines) provides 50+ log functions with colored console output and plain-text file logging:

- **20+ log levels**: `log_info`, `log_success`, `log_warning`, `log_error`, `log_debug`, `log_critical`, plus extended variants (`log_focus`, `log_highlight`, `log_alert`, etc.)
- **Bold/no-date/combined variants**: `log_bold_success`, `log_nodate_info`, `log_bold_nodate_warning`
- **Progress bars**: `log_progress "Starting stacks" 3 10` with Unicode block characters
- **Step tracking**: `log_step 1 6 "Verifying environment"`
- **Named timers**: `log_timer_start "pull"` / `log_timer_stop "pull"` with human-readable durations
- **Table formatting**: `log_table "Stack|Status|Duration" "core|OK|12s"` with box-drawing characters
- **Banners**: `log_banner "DOCKER SERVICES" "v2.0.0"` with centered bordered output
- **Key-value pairs**: `log_keyvalue "Docker" "v24.0.7"` with dot-leader alignment
- **Session summaries**: Duration, error/warning counts, entry totals in a formatted box
- **Error/warning counters**: Automatic tracking throughout the session

### Banner System

Beautiful ASCII art banners for startup, shutdown, and completion phases:
- `show_startup_banner` — Startup banner with version, environment, and date
- `show_shutdown_banner` — Red-themed shutdown banner
- `show_completion_banner` — Success/warning/error completion with optional duration
- `show_mini_banner` — Compact section headers with configurable colors

### Notifications

Push notifications via [NTFY](https://ntfy.sh). Set `NTFY_URL` in `.env` to enable. Notifications fire for:
- Service start (critical stacks)
- Service failure (with Portainer action button)
- Shutdown completion
- Container health issues

Leave `NTFY_URL` empty to disable all notifications.

## Customizing Stacks

Each stack ships with a minimal placeholder container. To add your real services:

1. Edit `Stacks/<category>/docker-compose.yml` with your services
2. Add stack-specific variables to `Stacks/<category>/.env`
3. Run `./start.sh` to deploy

The placeholder containers use `skeleton-*` naming, so they won't conflict with your real services.

## Requirements

- **Bash 4+** (uses associative arrays, `declare -g`)
- **Docker** with either:
  - Docker Compose plugin v2 (`docker compose`) — preferred
  - Legacy docker-compose binary v1
- **curl** for NTFY notifications (optional)
- **tput** for color support (standard on most systems)
- **bc** for size calculations in maintenance tools (optional)

## License

MIT
