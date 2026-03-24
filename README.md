# Docker Compose Skeleton

A portable, modular Docker service orchestration framework with a hardened REST API, 100 deployable service templates, dependency-ordered startup/shutdown, enhanced logging, push notifications, intelligent image updates, and a comprehensive management UI.

Clone it. Configure it. Run it — from any directory, by any user, on any Linux distro.

---

## Features

- **100 Service Templates** — Deploy Traefik, Portainer, Jellyfin, Nextcloud, Grafana, and 95 more with one command
- **REST API** — 76+ endpoints for full remote management (stacks, containers, templates, networks, volumes, backups, terminal)
- **Two-Factor Authentication** — TOTP 2FA with authenticator app support, auto-lock after inactivity
- **Setup Wizard** — 5-step guided first-run configuration via the companion UI
- **Dependency-Ordered Startup** — 10 stack categories start in order, shutdown in reverse
- **Intelligent Updates** — SHA256-based image change detection with rolling restarts
- **Compose Security Scanner** — Blocks privileged containers, dangerous mounts, capability escalation, and container escape vectors (7 rounds of penetration testing, 67+ security fixes)
- **Traefik Integration** — Auto-generated route files, Cloudflare DNS records, wildcard TLS certificates, Dynamic DNS
- **Plugin System** — Extensible with custom dashboard cards, hooks, and templates
- **Push Notifications** — NTFY integration for start, stop, failure, and health events
- **Health Monitoring** — Container health scoring, uptime tracking, resource trending
- **Backup & Restore** — Full system snapshots with path traversal protection
- **Encrypted Secrets** — AES-256-CBC encrypted key-value store for API keys, passwords, and tokens
- **Terminal Access** — Authenticated remote command execution with audit logging
- **System Updates** — Git-based framework updates with backup tags and one-click rollback
- **Cross-Distro** — Works on Ubuntu, Fedora, Arch, Alpine, openSUSE, Debian, and more

---

## Quick Start

```bash
# 1. Clone
git clone https://github.com/scotthowson/Docker-Compose-Skeleton.git
cd Docker-Compose-Skeleton

# 2. Run setup (installs dependencies, creates directories, launches setup API)
./setup.sh

# 3. Open DCS Manager, connect to your server IP, complete the Setup Wizard

# 4. Start all services
./start.sh
```

### What `./setup.sh` Does

| Step | Action |
|------|--------|
| 1 | Copies `.env.example` to `.env` |
| 2 | Creates `logs/` and archive directories |
| 3 | Creates stack directories from `DOCKER_STACKS` |
| 4 | Sets executable permissions on all scripts |
| 5 | Sets ownership to the current user |
| 6 | Installs required + optional system dependencies |
| 7 | Verifies Docker and Docker Compose |
| 8 | Launches the API server for Setup Wizard |

After setup, open [DCS Manager](https://github.com/scotthowson/Docker-Compose-Skeleton-UI) and the 5-step wizard walks you through admin account creation, server config, Traefik domain setup, DDNS, and stack selection.

---

## REST API

A 13,000+ line hardened bash API server with 60+ endpoints. Starts automatically with `./start.sh` on port `9876`.

### Endpoints

| Group | Endpoints | Description |
|-------|-----------|-------------|
| **System** | `/status`, `/health`, `/version`, `/system` | Health, metrics, Docker info, disk usage |
| **Stacks** | `/stacks`, `/stacks/:name/*` | List, start, stop, restart, update, rename, clone |
| **Containers** | `/containers`, `/containers/:id/*` | Inspect, start, stop, restart, logs, exec, rename, file browser |
| **Templates** | `/templates`, `/templates/:name/deploy` | Browse, preview, deploy, import from URL |
| **Images** | `/images`, `/images/search`, `/images/check` | List, search Docker Hub, check for updates |
| **Networks** | `/networks`, `/networks/:id/*` | List, create, remove, connect, disconnect |
| **Volumes** | `/volumes`, `/volumes/:name` | List, inspect, remove |
| **Logs** | `/logs`, `/logs/live`, `/logs/stats` | Service logs with filtering, live streaming, statistics |
| **Events** | `/events`, `/stream` | Docker events, SSE real-time stream |
| **Config** | `/config`, `/config/update` | Read and update `.env` configuration |
| **Maintenance** | `/maintenance/*` | Disk analysis, prune, orphan detection, log rotation |
| **Backups** | `/backups/*` | Create, list, restore, status polling |
| **Snapshots** | `/snapshots/*` | Full system snapshots with metadata |
| **Auth** | `/auth/*` | Setup, login, invite codes, token management, sessions |
| **Terminal** | `/terminal/exec`, `/terminal/auth` | Authenticated Linux command execution |
| **Batch** | `/batch/start`, `/batch/stop`, `/batch/update` | Bulk stack operations |
| **Webhooks** | `/webhooks/*` | Create, test, fire on events |
| **Automations** | `/automations/*` | Scheduled tasks with cron expressions |
| **Plugins** | `/plugins/*` | Install, enable, scaffold custom plugins |
| **Export** | `/export/*` | Export health, system, config data |
| **Notifications** | `/notifications/*` | Rules, history, test |
| **Updates** | `/system/update/*` | Check, apply, rollback DCS updates via git |
| **OS Updates** | `/system/os-update/*` | Check and apply system package updates |
| **DDNS** | `/ddns/status` | Dynamic DNS status and IP monitoring |
| **Traefik** | `/traefik/status` | Traefik router and certificate status |

### Authentication

Token-based auth with PBKDF2-SHA256 password hashing (100k iterations), rate limiting, and invite-code registration:

```bash
# Initial setup
curl -X POST http://server:9876/auth/setup \
  -d '{"username":"admin","password":"YourPassword1"}'

# Login
curl -X POST http://server:9876/auth/login \
  -d '{"username":"admin","password":"YourPassword1"}'
# → {"success": true, "token": "abc123...", "role": "admin"}

# Authenticated request
curl -H "Authorization: Bearer abc123..." http://server:9876/stacks
```

### Security

The API server has been through **7 rounds of penetration testing** with 67+ security fixes:

| Layer | Protection |
|-------|-----------|
| **Authentication** | PBKDF2-SHA256 (100k iterations), constant-time comparison, rate limiting (5 attempts → 15 min lockout) |
| **Authorization** | Role-based access (admin/user), per-endpoint enforcement, invite-only registration |
| **Input Validation** | 91 validation calls, path traversal protection, URL-encoded attack rejection |
| **Compose Scanner** | Blocks privileged mode, dangerous capabilities (SYS_ADMIN, NET_ADMIN), host mounts, build directives, security profile disabling |
| **Injection Prevention** | 287 JSON escape calls, sed/awk injection protection, shell metacharacter rejection |
| **HTTP Security** | X-Content-Type-Options, X-Frame-Options, CSP, HSTS, Permissions-Policy, CORS allowlisting |
| **SSRF Protection** | Private IP blocking, DNS rebinding prevention, URL re-validation at fire time |
| **DoS Protection** | Body size limits (1MB), request timeouts (30s), global rate limiting |
| **Session Security** | 24h token expiry, single-session enforcement, file-locked token storage |
| **Audit Logging** | All POST/DELETE operations logged with IP, user, path, and timestamp |

---

## Service Templates

100 ready-to-deploy templates across 10+ categories. Deploy via the API or [DCS Manager UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI).

<details>
<summary><strong>View all 100 templates</strong></summary>

| Category | Templates |
|----------|-----------|
| **Reverse Proxies** | Traefik, Caddy, Nginx Proxy Manager, Cloudflared |
| **Media** | Jellyfin, Plex, Sonarr, Radarr, Lidarr, Readarr, Prowlarr, Bazarr, Tautulli, Seerr, Jellyseerr, qBittorrent, Transmission, SABnzbd, FlareSolverr |
| **Dashboards** | Homarr, Homepage, Dashy, Dashdot, Yacht |
| **Monitoring** | Grafana, Prometheus, Uptime Kuma, Netdata, Loki, InfluxDB, SpeedTest Tracker, Dozzle |
| **Storage** | Nextcloud, Nextcloud AIO, MinIO, Syncthing, Duplicati, FileBrowser |
| **Databases** | PostgreSQL, MySQL, MariaDB, MongoDB, Redis, RedisInsight, Adminer, pgAdmin, phpMyAdmin |
| **Productivity** | Memos, Trilium, BookStack, Mealie, Tandoor, Actual Budget, Firefly III, Vikunja, Planka, Reactive Resume, Karakeep, Linkwarden, Kavita, Calibre-Web, Audiobookshelf, Paperless-ngx |
| **Development** | Gitea, Code Server, n8n, Semaphore |
| **Security** | Authelia, Vaultwarden, CrowdSec, WireGuard (wg-easy), AdGuard Home, Pi-hole, Docker Socket Proxy |
| **Communication** | PrivateBin, Ntfy, Gotify, FreshRSS, SearXNG, Wizarr |
| **Gaming** | EmulatorJS, MonkeyType, Pelican Panel, RustDesk |
| **Infrastructure** | Portainer, Watchtower, Diun, Sablier, Komodo, Home Assistant, Healthchecks |
| **AI** | Ollama, Open WebUI |
| **Web** | Nginx, Ghost, Excalidraw, Stirling PDF, IT-Tools, Immich |
| **DNS** | Cloudflare DDNS |

</details>

### Deployment

```bash
# Preview (dry run with conflict detection)
curl -X POST http://server:9876/templates/traefik/dry-run \
  -H "Authorization: Bearer TOKEN" \
  -d '{"target_stack":"networking-security","variables":{"TRAEFIK_DOMAIN":"example.com"}}'

# Deploy
curl -X POST http://server:9876/templates/traefik/deploy \
  -H "Authorization: Bearer TOKEN" \
  -d '{"target_stack":"networking-security","auto_start":true,"variables":{"TRAEFIK_DOMAIN":"example.com"}}'
```

Every deployment includes: compose validation, security scanning, port conflict detection, automatic backup, variable substitution, config file scaffolding, volume permission fixing, and optional Cloudflare DNS record creation.

---

## Commands

| Command | Description |
|---------|-------------|
| `./setup.sh` | First-run setup — dependencies, directories, Setup Wizard |
| `./start.sh` | Start all services in dependency order |
| `./stop.sh` | Graceful shutdown in reverse order |
| `./restart.sh` | Stop then start |
| `./status.sh` | Container status overview |

### Management Utilities

| Script | Description |
|--------|-------------|
| `.scripts/stack-manager.sh` | CLI for individual stacks (start/stop/restart/status/logs/pull) |
| `.scripts/health-check.sh` | Container health monitoring with formatted tables |
| `.scripts/config-validator.sh` | Validates config, directories, compose syntax, ports |
| `.scripts/maintenance.sh` | Docker cleanup, disk analysis, orphan detection, log rotation |
| `.scripts/docker-network-info.sh` | Network visualization with tree-style connections |
| `.scripts/image-tracker.sh` | Image age tracking and staleness detection |
| `.scripts/system-info.sh` | System and Docker resource information |
| `.scripts/logs-viewer.sh` | Interactive log viewer with filtering and search |
| `.scripts/api-server.sh` | REST API server (60+ endpoints, 13,000+ lines) |

---

## Configuration

### Root `.env`

Copy from `.env.example` on first run. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `DOCKER_STACKS` | *(10 categories)* | Space-separated stack directories — controls startup order |
| `APP_DATA_DIR` | `./App-Data` | Persistent container data |
| `PUID` / `PGID` | `1000` | User/Group IDs for file permissions |
| `TZ` | `UTC` | Timezone for all containers |
| `TRAEFIK_DOMAIN` | *(empty)* | Domain for reverse proxy routing |
| `CF_DNS_API_TOKEN` | *(empty)* | Cloudflare API token for DNS + wildcard TLS |
| `DDNS_ENABLED` | `false` | Auto-update Cloudflare A record on IP change |
| `API_PORT` | `9876` | REST API server port |
| `API_AUTH_ENABLED` | `false` | Authentication (auto-enabled on 0.0.0.0) |
| `API_RATE_LIMIT` | `120` | Max requests per 60-second window |
| `API_SINGLE_SESSION` | `true` | New login revokes previous tokens |

See `.env.example` for all 72 documented settings.

### Startup Order

```
1. core-infrastructure     →  6. web-applications
2. networking-security     →  7. storage-backup
3. monitoring-management   →  8. communication-collaboration
4. development-tools       →  9. entertainment-personal
5. media-services          → 10. miscellaneous-services
```

Shutdown runs in exact reverse.

---

## DCS Manager UI

A companion Electron desktop app with glassmorphism dark theme UI. See [Docker-Compose-Skeleton-UI](https://github.com/scotthowson/Docker-Compose-Skeleton-UI).

**Stack:** Electron + React + Vite + Tailwind CSS + Zustand + TypeScript

**37 pages** including: Dashboard, Containers, Stacks, Templates, Health Monitor, Uptime, Trends, Networks, Volumes, Images, Logs, Terminal, Export, Settings, Users, Plugins, and more.

---

## Requirements

| Dependency | Required | Purpose |
|------------|----------|---------|
| **Bash 4+** | Yes | Associative arrays, `declare -g`, `${var,,}` |
| **Docker** | Yes | Container runtime |
| **Docker Compose v2** | Yes | Stack orchestration (`docker compose` plugin) |
| **jq** | Yes | JSON processing for the API server |
| **python3** | Yes | PBKDF2 password hashing, privilege escalation |
| **curl** | Yes | Health checks, notifications, updates |
| **git** | Yes | DCS updates, plugin installation |
| **openssl** | Yes | Token generation, TLS support |
| **socat** or **ncat** | Yes | API server TCP listener |
| rsync | Recommended | Backups and snapshots |
| tar | Recommended | Backup/restore archives |
| xxd | Recommended | Hex encoding for tokens |
| perl | Recommended | ANSI code stripping in log output |

`./setup.sh` detects your distro and offers to install all dependencies automatically.

**Supported distros:** Ubuntu, Debian, Fedora, RHEL, CentOS, Arch, Manjaro, openSUSE, Alpine, Void Linux, NixOS

---

## License

MIT
