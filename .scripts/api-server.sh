#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — REST API Server v1.0
# Lightweight HTTP API for remote management — zero external dependencies.
# Uses socat or ncat to serve JSON responses over HTTP.
#
# Designed as the backend foundation for the Electron desktop app.
#
# Usage:
#   ./api-server.sh [--port PORT] [--bind ADDR] [--daemon] [--stop] [--help]
#
# Endpoints:
#   GET  /                          API info and available endpoints
#   GET  /status                    Overall system status
#   GET  /health                    Container health report (JSON)
#   GET  /stacks                    List all stacks with status
#   GET  /stacks/:name              Detailed info for a specific stack
#   GET  /stacks/:name/containers   Containers in a specific stack
#   GET  /stacks/:name/logs         Recent logs for a stack (last 50 lines)
#   POST /stacks/:name/start        Start a specific stack
#   POST /stacks/:name/stop         Stop a specific stack
#   POST /stacks/:name/restart      Restart a specific stack
#   POST /stacks/:name/update       Pull, detect changes, recreate if needed
#   GET  /images                    All images with age/size/staleness
#   GET  /images/stale              Only stale images (>30 days)
#   GET  /containers                All containers with status
#   GET  /containers/:name          Detailed info for a specific container
#   GET  /containers/:name/stats    Live resource stats for a container
#   GET  /config                    Current configuration (sanitized)
#   GET  /system                    System resource information
#   GET  /networks                  Docker networks and connections
#   GET  /volumes                   Docker volumes and usage
#   GET  /logs                      Framework log (last 100 lines)
#   GET  /events                    Recent Docker events (last 50)
#   GET  /version                   API and framework version info
#
# All responses are JSON with Content-Type: application/json.
# CORS headers are included for Electron app compatibility.
# =============================================================================

set -euo pipefail

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _API_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_API_SCRIPT_DIR/.." && pwd)"
    unset _API_SCRIPT_DIR
fi

if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"
APP_DATA_DIR="${APP_DATA_DIR:-$BASE_DIR/App-Data}"

# =============================================================================
# CONFIGURATION
# =============================================================================

API_PORT="${API_PORT:-9876}"
API_BIND="${API_BIND:-127.0.0.1}"
API_VERSION="1.0.0"
API_PID_FILE="/tmp/dcs-api-server.pid"
API_LOG_FILE="${BASE_DIR}/logs/api-server.log"

# =============================================================================
# DOCKER COMPOSE DETECTION
# =============================================================================

if [[ -z "${DOCKER_COMPOSE_CMD:-}" ]]; then
    if docker compose version >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo "Error: No Docker Compose found" >&2
        exit 1
    fi
fi

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DAEMON_MODE=false
STOP_SERVER=false
HANDLE_REQUEST=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --handle-request) HANDLE_REQUEST=true; shift ;;
        --port)    API_PORT="$2"; shift 2 ;;
        --bind)    API_BIND="$2"; shift 2 ;;
        --daemon)  DAEMON_MODE=true; shift ;;
        --stop)    STOP_SERVER=true; shift ;;
        --help|-h)
            cat <<EOF
Docker Compose Skeleton — REST API Server v${API_VERSION}

Usage: $0 [OPTIONS]

Options:
  --port PORT     Port to listen on (default: ${API_PORT})
  --bind ADDR     Bind address (default: ${API_BIND})
  --daemon        Run in background (daemonize)
  --stop          Stop a running daemon
  --help, -h      Show this help message

The API provides JSON endpoints for managing Docker Compose stacks,
containers, images, and system resources. Designed as the backend
for the Electron desktop application.

Requires: socat or ncat (netcat with -e support)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# =============================================================================
# DAEMON MANAGEMENT
# =============================================================================

if [[ "$STOP_SERVER" == "true" ]]; then
    if [[ -f "$API_PID_FILE" ]]; then
        pid=$(cat "$API_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
            rm -f "$API_PID_FILE"
            echo "API server stopped (PID $pid)"
        else
            rm -f "$API_PID_FILE"
            echo "API server was not running (stale PID file removed)"
        fi
    else
        echo "No API server PID file found"
    fi
    exit 0
fi

# =============================================================================
# DEPENDENCY CHECK
# =============================================================================

LISTENER_CMD=""
if command -v socat >/dev/null 2>&1; then
    LISTENER_CMD="socat"
elif command -v ncat >/dev/null 2>&1; then
    LISTENER_CMD="ncat"
else
    echo "Error: Neither 'socat' nor 'ncat' found. Install one:" >&2
    echo "  sudo apt install socat       # Debian/Ubuntu" >&2
    echo "  sudo dnf install socat       # Fedora/RHEL" >&2
    echo "  sudo pacman -S socat         # Arch" >&2
    exit 1
fi

# =============================================================================
# JSON HELPERS
# =============================================================================

# Escape a string for safe JSON embedding
_api_json_escape() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//$'\n'/\\n}"
    str="${str//$'\r'/\\r}"
    str="${str//$'\t'/\\t}"
    echo -n "$str"
}

# Build a standard JSON response envelope
_api_response() {
    local status_code="$1"
    local body="$2"
    local status_text="OK"

    case "$status_code" in
        200) status_text="OK" ;;
        201) status_text="Created" ;;
        400) status_text="Bad Request" ;;
        404) status_text="Not Found" ;;
        405) status_text="Method Not Allowed" ;;
        500) status_text="Internal Server Error" ;;
    esac

    local content_length=${#body}

    printf "HTTP/1.1 %s %s\r\n" "$status_code" "$status_text"
    printf "Content-Type: application/json\r\n"
    printf "Content-Length: %d\r\n" "$content_length"
    printf "Access-Control-Allow-Origin: *\r\n"
    printf "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
    printf "Access-Control-Allow-Headers: Content-Type, Authorization\r\n"
    printf "X-API-Version: %s\r\n" "$API_VERSION"
    printf "Connection: close\r\n"
    printf "\r\n"
    printf "%s" "$body"
}

_api_error() {
    local code="$1"
    local message="$2"
    local escaped
    escaped="$(_api_json_escape "$message")"
    _api_response "$code" "{\"error\": true, \"code\": $code, \"message\": \"$escaped\"}"
}

_api_success() {
    local body="$1"
    _api_response 200 "$body"
}

# =============================================================================
# DATA COLLECTION HELPERS
# =============================================================================

# Get all stack names
_api_get_stacks() {
    local -a stacks=()
    for dir in "$COMPOSE_DIR"/*/; do
        [[ -f "${dir}docker-compose.yml" ]] && stacks+=("$(basename "$dir")")
    done
    echo "${stacks[@]}"
}

# Get stack status: RUNNING (with count) or STOPPED
_api_stack_status() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    local -a args=(-f "$compose_file")
    [[ -f "$env_file" ]] && args+=(--env-file "$env_file")

    local count
    count=$($DOCKER_COMPOSE_CMD "${args[@]}" ps -q 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        echo "running:$count"
    else
        echo "stopped:0"
    fi
}

# Get container details as JSON array entry
_api_container_json() {
    local container_id="$1"
    local name state health image created status

    name=$(docker inspect --format='{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||')
    state=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)
    health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null)
    image=$(docker inspect --format='{{.Config.Image}}' "$container_id" 2>/dev/null)
    created=$(docker inspect --format='{{.Created}}' "$container_id" 2>/dev/null)
    status=$(docker inspect --format='{{.State.Status}}' "$container_id" 2>/dev/null)

    local started_at uptime_seconds=0
    started_at=$(docker inspect --format='{{.State.StartedAt}}' "$container_id" 2>/dev/null)
    if [[ -n "$started_at" ]] && [[ "$started_at" != "0001-01-01T00:00:00Z" ]]; then
        local start_epoch now_epoch
        start_epoch=$(date -d "$started_at" +%s 2>/dev/null) || start_epoch=0
        now_epoch=$(date +%s)
        uptime_seconds=$(( now_epoch - start_epoch ))
    fi

    local ports
    ports=$(_api_json_escape "$(docker inspect --format='{{range $p, $conf := .NetworkSettings.Ports}}{{$p}}->{{range $conf}}{{.HostPort}}{{end}} {{end}}' "$container_id" 2>/dev/null)")

    local restart_count
    restart_count=$(docker inspect --format='{{.RestartCount}}' "$container_id" 2>/dev/null)

    local image_id
    image_id=$(docker inspect --format='{{.Image}}' "$container_id" 2>/dev/null)
    local image_id_short="${image_id:7:12}"

    printf '{"name": "%s", "state": "%s", "health": "%s", "image": "%s", "image_id": "%s", "created": "%s", "uptime_seconds": %d, "ports": "%s", "restart_count": %s}' \
        "$(_api_json_escape "$name")" \
        "$(_api_json_escape "$state")" \
        "$(_api_json_escape "$health")" \
        "$(_api_json_escape "$image")" \
        "$image_id_short" \
        "$(_api_json_escape "$created")" \
        "$uptime_seconds" \
        "$ports" \
        "${restart_count:-0}"
}

# =============================================================================
# ENDPOINT HANDLERS
# =============================================================================

handle_root() {
    local endpoints='[
    {"method": "GET",  "path": "/",                          "description": "API info and available endpoints"},
    {"method": "GET",  "path": "/status",                    "description": "Overall system status"},
    {"method": "GET",  "path": "/health",                    "description": "Container health report"},
    {"method": "GET",  "path": "/stacks",                    "description": "List all stacks with status"},
    {"method": "GET",  "path": "/stacks/:name",              "description": "Detailed info for a stack"},
    {"method": "GET",  "path": "/stacks/:name/containers",   "description": "Containers in a stack"},
    {"method": "GET",  "path": "/stacks/:name/logs",         "description": "Recent logs for a stack"},
    {"method": "POST", "path": "/stacks/:name/start",        "description": "Start a stack"},
    {"method": "POST", "path": "/stacks/:name/stop",         "description": "Stop a stack"},
    {"method": "POST", "path": "/stacks/:name/restart",      "description": "Restart a stack"},
    {"method": "POST", "path": "/stacks/:name/update",       "description": "Pull, detect, recreate"},
    {"method": "GET",  "path": "/images",                    "description": "All images with metadata"},
    {"method": "GET",  "path": "/images/stale",              "description": "Only stale images (>30d)"},
    {"method": "GET",  "path": "/containers",                "description": "All containers with status"},
    {"method": "GET",  "path": "/containers/:name",          "description": "Detailed container info"},
    {"method": "GET",  "path": "/containers/:name/stats",    "description": "Live resource stats"},
    {"method": "GET",  "path": "/config",                    "description": "Current configuration"},
    {"method": "GET",  "path": "/system",                    "description": "System resource info"},
    {"method": "GET",  "path": "/networks",                  "description": "Docker networks"},
    {"method": "GET",  "path": "/volumes",                   "description": "Docker volumes"},
    {"method": "GET",  "path": "/logs",                      "description": "Framework log tail"},
    {"method": "GET",  "path": "/events",                    "description": "Recent Docker events"},
    {"method": "GET",  "path": "/version",                   "description": "Version information"}
  ]'

    _api_success "{\"name\": \"Docker Compose Skeleton API\", \"version\": \"$API_VERSION\", \"endpoints\": $endpoints}"
}

handle_version() {
    local docker_version compose_version
    docker_version=$(_api_json_escape "$(docker --version 2>/dev/null)")
    compose_version=$(_api_json_escape "$($DOCKER_COMPOSE_CMD version 2>/dev/null)")

    _api_success "{\"api_version\": \"$API_VERSION\", \"framework_version\": \"${SCRIPT_VERSION:-2.0.0}\", \"docker_version\": \"$docker_version\", \"compose_version\": \"$compose_version\", \"compose_command\": \"$DOCKER_COMPOSE_CMD\"}"
}

handle_status() {
    local total_containers running_containers stopped_containers
    total_containers=$(docker ps -a -q 2>/dev/null | wc -l)
    running_containers=$(docker ps -q 2>/dev/null | wc -l)
    stopped_containers=$(( total_containers - running_containers ))

    local total_images
    total_images=$(docker images -q 2>/dev/null | wc -l)

    local total_volumes
    total_volumes=$(docker volume ls -q 2>/dev/null | wc -l)

    local total_networks
    total_networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cv '^bridge$\|^host$\|^none$' || echo 0)

    local disk_usage
    disk_usage=$(df -h / 2>/dev/null | tail -1 | awk '{printf "{\"total\": \"%s\", \"used\": \"%s\", \"available\": \"%s\", \"percent\": \"%s\"}", $2, $3, $4, $5}')

    local load_avg mem_total mem_available
    load_avg=$(awk '{printf "[%s, %s, %s]", $1, $2, $3}' /proc/loadavg 2>/dev/null || echo "[0,0,0]")
    mem_total=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    mem_available=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)

    local uptime_seconds
    uptime_seconds=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)

    local stacks
    stacks=($(_api_get_stacks))
    local running_stacks=0
    for s in "${stacks[@]}"; do
        local st
        st=$(_api_stack_status "$s")
        [[ "$st" == running:* ]] && (( running_stacks++ ))
    done

    _api_success "{\"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", \"hostname\": \"$(hostname)\", \"uptime_seconds\": $uptime_seconds, \"docker\": {\"containers\": {\"total\": $total_containers, \"running\": $running_containers, \"stopped\": $stopped_containers}, \"images\": $total_images, \"volumes\": $total_volumes, \"networks\": $total_networks}, \"stacks\": {\"total\": ${#stacks[@]}, \"running\": $running_stacks}, \"system\": {\"load_average\": $load_avg, \"memory_mb\": {\"total\": $mem_total, \"available\": $mem_available}, \"disk\": $disk_usage}}"
}

handle_health() {
    local -a results=()
    local total=0 healthy=0 unhealthy=0 stopped=0

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        (( total++ ))

        local name state health
        name=$(docker inspect --format='{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        state=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null)
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)

        if [[ "$state" != "running" ]]; then
            (( stopped++ ))
        elif [[ "$health" == "unhealthy" ]]; then
            (( unhealthy++ ))
        else
            (( healthy++ ))
        fi

        results+=("{\"name\": \"$(_api_json_escape "$name")\", \"state\": \"$state\", \"health\": \"$health\"}")
    done < <(docker ps -a -q 2>/dev/null)

    local overall="healthy"
    (( unhealthy > 0 )) && overall="degraded"
    (( stopped > 0 )) && overall="critical"

    local containers_json
    containers_json=$(printf '%s,' "${results[@]}")
    containers_json="[${containers_json%,}]"

    _api_success "{\"status\": \"$overall\", \"summary\": {\"total\": $total, \"healthy\": $healthy, \"unhealthy\": $unhealthy, \"stopped\": $stopped}, \"containers\": $containers_json}"
}

handle_stacks() {
    local stacks
    stacks=($(_api_get_stacks))

    local -a entries=()
    for stack in "${stacks[@]}"; do
        local st
        st=$(_api_stack_status "$stack")
        local status="${st%%:*}"
        local count="${st#*:}"

        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        local has_env="false"
        [[ -f "$COMPOSE_DIR/$stack/.env" ]] && has_env="true"

        # Count services defined in compose file
        local service_count
        service_count=$(grep -c '^\s\+[a-zA-Z]' "$compose_file" 2>/dev/null || echo 0)

        entries+=("{\"name\": \"$stack\", \"status\": \"$status\", \"running_containers\": $count, \"has_env\": $has_env, \"compose_file\": \"$compose_file\"}")
    done

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#stacks[@]}, \"stacks\": $json}"
}

handle_stack_detail() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local st
    st=$(_api_stack_status "$stack")
    local status="${st%%:*}"
    local count="${st#*:}"

    # Get services from config
    local -a services=()
    while IFS= read -r svc; do
        [[ -n "$svc" ]] && services+=("\"$(_api_json_escape "$svc")\"")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config --services 2>/dev/null)

    local services_json
    services_json=$(printf '%s,' "${services[@]}")
    services_json="[${services_json%,}]"

    # Get containers
    local -a container_entries=()
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        container_entries+=("$(_api_container_json "$cid")")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)

    local containers_json
    containers_json=$(printf '%s,' "${container_entries[@]}")
    containers_json="[${containers_json%,}]"

    # Get images used
    local -a image_entries=()
    while IFS= read -r img; do
        [[ -z "$img" ]] && continue
        local img_id size
        img_id=$(docker image inspect --format='{{.Id}}' "$img" 2>/dev/null)
        size=$(docker image inspect --format='{{.Size}}' "$img" 2>/dev/null)
        image_entries+=("{\"name\": \"$(_api_json_escape "$img")\", \"id\": \"${img_id:7:12}\", \"size\": ${size:-0}}")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

    local images_json
    images_json=$(printf '%s,' "${image_entries[@]}")
    images_json="[${images_json%,}]"

    _api_success "{\"name\": \"$stack\", \"status\": \"$status\", \"running_containers\": $count, \"has_env\": $([[ -f "$env_file" ]] && echo true || echo false), \"services\": $services_json, \"containers\": $containers_json, \"images\": $images_json}"
}

handle_stack_containers() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local -a entries=()
    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        entries+=("$(_api_container_json "$cid")")
    done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" ps -q 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"stack\": \"$stack\", \"containers\": $json}"
}

handle_stack_logs() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local logs_raw
    logs_raw=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" logs --tail 50 --no-color 2>&1)
    local escaped
    escaped=$(_api_json_escape "$logs_raw")

    _api_success "{\"stack\": \"$stack\", \"lines\": 50, \"logs\": \"$escaped\"}"
}

handle_stack_action() {
    local stack="$1"
    local action="$2"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local -a compose_args=(-f "$compose_file")
    [[ -f "$env_file" ]] && compose_args+=(--env-file "$env_file")

    local output=""
    local success=true

    case "$action" in
        start)
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d --remove-orphans 2>&1) || success=false
            ;;
        stop)
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" down --remove-orphans --timeout 30 2>&1) || success=false
            ;;
        restart)
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" down --remove-orphans --timeout 30 2>&1) || true
            output+=$'\n'
            output+=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d --remove-orphans 2>&1) || success=false
            ;;
        update)
            # Record pre-update IDs
            local -A pre_ids=()
            while IFS= read -r img; do
                [[ -z "$img" ]] && continue
                local cid
                cid=$(docker image inspect --format='{{.Id}}' "$img" 2>/dev/null)
                [[ -n "$cid" ]] && pre_ids["$img"]="$cid"
            done < <($DOCKER_COMPOSE_CMD "${compose_args[@]}" config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

            # Pull
            output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" pull 2>&1) || success=false

            # Compare
            local changes_found=false
            local -a changes=()
            for img in "${!pre_ids[@]}"; do
                local new_id
                new_id=$(docker image inspect --format='{{.Id}}' "$img" 2>/dev/null)
                if [[ "${pre_ids[$img]}" != "$new_id" ]]; then
                    changes_found=true
                    changes+=("$img")
                fi
            done

            if [[ "$changes_found" == "true" ]] && [[ "$success" == "true" ]]; then
                output+=$'\n'
                output+=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d --remove-orphans 2>&1) || success=false
            fi

            local changes_json
            changes_json=$(printf '"%s",' "${changes[@]}")
            changes_json="[${changes_json%,}]"

            local escaped_output
            escaped_output=$(_api_json_escape "$output")
            _api_success "{\"stack\": \"$stack\", \"action\": \"update\", \"success\": $success, \"changes_detected\": $changes_found, \"changed_images\": $changes_json, \"output\": \"$escaped_output\"}"
            return
            ;;
    esac

    local escaped_output
    escaped_output=$(_api_json_escape "$output")
    _api_success "{\"stack\": \"$stack\", \"action\": \"$action\", \"success\": $success, \"output\": \"$escaped_output\"}"
}

handle_images() {
    local stale_only="${1:-false}"

    local -a entries=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r repo tag id created size <<< "$line"

        local age_days=-1
        local staleness="unknown"
        if [[ -n "$created" ]] && [[ "$created" != "<none>" ]]; then
            local img_epoch
            img_epoch=$(date -d "$created" '+%s' 2>/dev/null || echo 0)
            if [[ "$img_epoch" -gt 0 ]]; then
                local now_epoch
                now_epoch=$(date '+%s')
                age_days=$(( (now_epoch - img_epoch) / 86400 ))
                if [[ $age_days -lt 7 ]]; then staleness="current"
                elif [[ $age_days -lt 30 ]]; then staleness="aging"
                else staleness="stale"
                fi
            fi
        fi

        if [[ "$stale_only" == "true" ]] && [[ "$staleness" != "stale" ]]; then
            continue
        fi

        entries+=("{\"repository\": \"$(_api_json_escape "$repo")\", \"tag\": \"$(_api_json_escape "$tag")\", \"id\": \"$(_api_json_escape "$id")\", \"created\": \"$(_api_json_escape "$created")\", \"size\": \"$(_api_json_escape "$size")\", \"age_days\": $age_days, \"staleness\": \"$staleness\"}")
    done < <(docker images --format '{{.Repository}}|{{.Tag}}|{{.ID}}|{{.CreatedAt}}|{{.Size}}' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"images\": $json}"
}

handle_containers() {
    local -a entries=()

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        entries+=("$(_api_container_json "$cid")")
    done < <(docker ps -a -q 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"containers\": $json}"
}

handle_container_detail() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local cid
    cid=$(docker inspect --format='{{.Id}}' "$name" 2>/dev/null)

    local full_json
    full_json=$(_api_container_json "$cid")

    # Add extra detail: environment, mounts, networks
    local env_json mounts_json networks_json
    env_json=$(_api_json_escape "$(docker inspect --format='{{range .Config.Env}}{{.}} {{end}}' "$name" 2>/dev/null)")
    mounts_json=$(_api_json_escape "$(docker inspect --format='{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' "$name" 2>/dev/null)")
    networks_json=$(_api_json_escape "$(docker inspect --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$name" 2>/dev/null)")

    # Reconstruct with extra fields
    # Remove closing brace and append
    full_json="${full_json%\}}"
    full_json+=", \"environment\": \"$env_json\", \"mounts\": \"$mounts_json\", \"networks\": \"$networks_json\"}"

    _api_success "$full_json"
}

handle_container_stats() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local stats_line
    stats_line=$(docker stats --no-stream --format '{{.CPUPerc}}|{{.MemUsage}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}|{{.PIDs}}' "$name" 2>/dev/null)

    IFS='|' read -r cpu mem_usage mem_perc net_io block_io pids <<< "$stats_line"

    _api_success "{\"container\": \"$name\", \"cpu_percent\": \"$(_api_json_escape "$cpu")\", \"memory_usage\": \"$(_api_json_escape "$mem_usage")\", \"memory_percent\": \"$(_api_json_escape "$mem_perc")\", \"network_io\": \"$(_api_json_escape "$net_io")\", \"block_io\": \"$(_api_json_escape "$block_io")\", \"pids\": \"$(_api_json_escape "$pids")\"}"
}

handle_config() {
    # Return sanitized configuration (exclude passwords/secrets)
    local config="{"
    config+="\"environment\": \"${ENVIRONMENT:-production}\","
    config+="\"log_level\": \"${LOG_LEVEL:-INFO}\","
    config+="\"compose_dir\": \"$(_api_json_escape "$COMPOSE_DIR")\","
    config+="\"app_data_dir\": \"$(_api_json_escape "$APP_DATA_DIR")\","
    config+="\"base_dir\": \"$(_api_json_escape "$BASE_DIR")\","
    config+="\"compose_command\": \"$DOCKER_COMPOSE_CMD\","
    config+="\"skip_healthcheck_wait\": ${SKIP_HEALTHCHECK_WAIT:-false},"
    config+="\"continue_on_failure\": ${CONTINUE_ON_FAILURE:-true},"
    config+="\"remove_volumes_on_stop\": ${REMOVE_VOLUMES_ON_STOP:-false},"
    config+="\"aggressive_image_prune\": ${AGGRESSIVE_IMAGE_PRUNE:-false},"
    config+="\"update_notification\": ${UPDATE_NOTIFICATION:-true},"
    config+="\"show_banners\": ${SHOW_BANNERS:-true},"
    config+="\"api_port\": $API_PORT,"
    config+="\"api_bind\": \"$API_BIND\","
    config+="\"ntfy_configured\": $([[ -n "${NTFY_URL:-}" ]] && echo true || echo false),"
    config+="\"server_name\": \"$(_api_json_escape "${SERVER_NAME:-Docker Server}")\","
    config+="\"timezone\": \"${TZ:-UTC}\""
    config+="}"

    _api_success "$config"
}

handle_system() {
    local docker_info
    docker_info=$(docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)

    local -a df_entries=()
    while IFS='|' read -r type total active size reclaimable; do
        [[ -z "$type" ]] && continue
        df_entries+=("{\"type\": \"$(_api_json_escape "$type")\", \"total\": \"$(_api_json_escape "$total")\", \"active\": \"$(_api_json_escape "$active")\", \"size\": \"$(_api_json_escape "$size")\", \"reclaimable\": \"$(_api_json_escape "$reclaimable")\"}")
    done <<< "$docker_info"

    local df_json
    df_json=$(printf '%s,' "${df_entries[@]}")
    df_json="[${df_json%,}]"

    local cpu_count mem_total_mb swap_total_mb kernel_version
    cpu_count=$(nproc 2>/dev/null || echo 0)
    mem_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    swap_total_mb=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    kernel_version=$(_api_json_escape "$(uname -r 2>/dev/null)")

    local docker_version
    docker_version=$(_api_json_escape "$(docker --version 2>/dev/null)")

    _api_success "{\"hostname\": \"$(hostname)\", \"kernel\": \"$kernel_version\", \"cpu_count\": $cpu_count, \"memory_total_mb\": $mem_total_mb, \"swap_total_mb\": $swap_total_mb, \"docker_version\": \"$docker_version\", \"docker_disk_usage\": $df_json}"
}

handle_networks() {
    local -a entries=()

    while IFS='|' read -r id name driver scope; do
        [[ -z "$id" ]] && continue

        # Get containers on this network
        local -a net_containers=()
        while IFS= read -r cname; do
            [[ -n "$cname" ]] && net_containers+=("\"$(_api_json_escape "$cname")\"")
        done < <(docker network inspect --format='{{range $k, $v := .Containers}}{{$v.Name}} {{end}}' "$id" 2>/dev/null | tr ' ' '\n' | grep -v '^$')

        local nc_json
        nc_json=$(printf '%s,' "${net_containers[@]}")
        nc_json="[${nc_json%,}]"

        entries+=("{\"id\": \"$(_api_json_escape "$id")\", \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"scope\": \"$(_api_json_escape "$scope")\", \"containers\": $nc_json}")
    done < <(docker network ls --format '{{.ID}}|{{.Name}}|{{.Driver}}|{{.Scope}}' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"networks\": $json}"
}

handle_volumes() {
    local -a entries=()

    while IFS='|' read -r name driver mountpoint; do
        [[ -z "$name" ]] && continue

        local size="0"
        if [[ -d "$mountpoint" ]]; then
            size=$(du -sb "$mountpoint" 2>/dev/null | awk '{print $1}' || echo 0)
        fi

        entries+=("{\"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"mountpoint\": \"$(_api_json_escape "$mountpoint")\", \"size_bytes\": $size}")
    done < <(docker volume ls --format '{{.Name}}|{{.Driver}}|{{.Mountpoint}}' 2>/dev/null)

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"volumes\": $json}"
}

handle_logs() {
    local log_file="${BASE_DIR}/logs/docker-services.log"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"lines\": 0, \"logs\": \"\"}"
        return
    fi

    local content
    content=$(tail -100 "$log_file" 2>/dev/null)
    local escaped
    escaped=$(_api_json_escape "$content")

    _api_success "{\"log_file\": \"$(_api_json_escape "$log_file")\", \"lines\": 100, \"logs\": \"$escaped\"}"
}

handle_events() {
    local events_raw
    events_raw=$(docker events --since '1h' --until "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --format '{{.Time}}|{{.Type}}|{{.Action}}|{{.Actor.Attributes.name}}' 2>/dev/null | tail -50)

    local -a entries=()
    while IFS='|' read -r timestamp type action name; do
        [[ -z "$timestamp" ]] && continue
        entries+=("{\"timestamp\": $timestamp, \"type\": \"$(_api_json_escape "$type")\", \"action\": \"$(_api_json_escape "$action")\", \"name\": \"$(_api_json_escape "$name")\"}")
    done <<< "$events_raw"

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#entries[@]}, \"events\": $json}"
}

# =============================================================================
# REQUEST ROUTER
# =============================================================================

handle_request() {
    local method path

    # Read the HTTP request line
    local request_line=""
    read -r request_line

    # Parse method and path
    method=$(echo "$request_line" | awk '{print $1}')
    path=$(echo "$request_line" | awk '{print $2}')

    # Consume remaining headers (read until empty line)
    local header=""
    while IFS= read -r header; do
        header="${header%%$'\r'}"
        [[ -z "$header" ]] && break
    done

    # Normalize path: strip trailing slash, lowercase
    path="${path%/}"
    [[ -z "$path" ]] && path="/"

    # Handle CORS preflight
    if [[ "$method" == "OPTIONS" ]]; then
        _api_response 200 ""
        return
    fi

    # Log the request
    echo "$(date '+%Y-%m-%d %H:%M:%S') $method $path" >> "$API_LOG_FILE" 2>/dev/null

    # ── Route: GET endpoints ──────────────────────────────────────────
    if [[ "$method" == "GET" ]]; then
        case "$path" in
            /)                          handle_root ;;
            /status)                    handle_status ;;
            /health)                    handle_health ;;
            /stacks)                    handle_stacks ;;
            /images)                    handle_images false ;;
            /images/stale)              handle_images true ;;
            /containers)                handle_containers ;;
            /config)                    handle_config ;;
            /system)                    handle_system ;;
            /networks)                  handle_networks ;;
            /volumes)                   handle_volumes ;;
            /logs)                      handle_logs ;;
            /events)                    handle_events ;;
            /version)                   handle_version ;;

            /stacks/*/containers)
                local stack="${path#/stacks/}"
                stack="${stack%/containers}"
                handle_stack_containers "$stack"
                ;;
            /stacks/*/logs)
                local stack="${path#/stacks/}"
                stack="${stack%/logs}"
                handle_stack_logs "$stack"
                ;;
            /stacks/*)
                local stack="${path#/stacks/}"
                handle_stack_detail "$stack"
                ;;
            /containers/*/stats)
                local container="${path#/containers/}"
                container="${container%/stats}"
                handle_container_stats "$container"
                ;;
            /containers/*)
                local container="${path#/containers/}"
                handle_container_detail "$container"
                ;;
            *)
                _api_error 404 "Endpoint not found: $path"
                ;;
        esac
        return
    fi

    # ── Route: POST endpoints ─────────────────────────────────────────
    if [[ "$method" == "POST" ]]; then
        case "$path" in
            /stacks/*/start)
                local stack="${path#/stacks/}"
                stack="${stack%/start}"
                handle_stack_action "$stack" "start"
                ;;
            /stacks/*/stop)
                local stack="${path#/stacks/}"
                stack="${stack%/stop}"
                handle_stack_action "$stack" "stop"
                ;;
            /stacks/*/restart)
                local stack="${path#/stacks/}"
                stack="${stack%/restart}"
                handle_stack_action "$stack" "restart"
                ;;
            /stacks/*/update)
                local stack="${path#/stacks/}"
                stack="${stack%/update}"
                handle_stack_action "$stack" "update"
                ;;
            *)
                _api_error 404 "Endpoint not found: $path"
                ;;
        esac
        return
    fi

    _api_error 405 "Method not allowed: $method"
}

# =============================================================================
# SERVER MAIN LOOP
# =============================================================================

start_server() {
    # Create log directory
    mkdir -p "$(dirname "$API_LOG_FILE")" 2>/dev/null

    # Color setup for terminal output
    local _A_RST="" _A_BOLD="" _A_DIM=""
    local _A_CYAN="" _A_BLUE="" _A_GREEN="" _A_GRAY="" _A_WHITE="" _A_MAGENTA=""

    if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        _A_RST="$(tput sgr0)"
        _A_BOLD="$(tput bold)"
        _A_DIM="$(tput dim)"
        _A_CYAN="$(tput setaf 51)"
        _A_BLUE="$(tput setaf 33)"
        _A_GREEN="$(tput setaf 82)"
        _A_GRAY="$(tput setaf 245)"
        _A_WHITE="$(tput setaf 15)"
        _A_MAGENTA="$(tput setaf 141)"
    fi

    local border
    border="$(printf '%0.s═' $(seq 1 60))"

    echo ""
    echo "  ${_A_BOLD}${_A_BLUE}${border}${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_CYAN}   ╔═╗╔═╗╦  ╔═╗╔═╗╦═╗╦  ╦╔═╗╦═╗${_A_RST}"
    echo "  ${_A_BOLD}${_A_CYAN}   ╠═╣╠═╝║  ╚═╗║╣ ╠╦╝╚╗╔╝║╣ ╠╦╝${_A_RST}"
    echo "  ${_A_BOLD}${_A_CYAN}   ╩ ╩╩  ╩  ╚═╝╚═╝╩╚═ ╚╝ ╚═╝╩╚═${_A_RST}"
    echo ""
    echo "  ${_A_DIM}${_A_GRAY}  Docker Compose Skeleton REST API${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_BLUE}${border}${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_WHITE}Version${_A_RST}    ${_A_CYAN}v${API_VERSION}${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}Listen${_A_RST}     ${_A_GREEN}${API_BIND}:${API_PORT}${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}Transport${_A_RST}  ${_A_MAGENTA}${LISTENER_CMD}${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}PID${_A_RST}        ${_A_GRAY}$$${_A_RST}"
    echo "  ${_A_BOLD}${_A_WHITE}Base Dir${_A_RST}   ${_A_DIM}${BASE_DIR}${_A_RST}"
    echo ""
    echo "  ${_A_DIM}${_A_GRAY}──────────────────────────────────────────────────────────${_A_RST}"
    echo ""
    echo "  ${_A_GREEN}Endpoints${_A_RST}  ${_A_DIM}curl http://${API_BIND}:${API_PORT}/${_A_RST}"
    echo "  ${_A_GREEN}Stop${_A_RST}       ${_A_DIM}$0 --stop${_A_RST}"
    echo ""
    echo "  ${_A_BOLD}${_A_BLUE}${border}${_A_RST}"
    echo ""

    # Write PID file
    echo $$ > "$API_PID_FILE"

    local self_path
    self_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

    # Start the listener — socat/ncat invoke this script with --handle-request
    # which triggers the internal request handler (see ENTRY POINT below)
    if [[ "$LISTENER_CMD" == "socat" ]]; then
        socat "TCP-LISTEN:${API_PORT},bind=${API_BIND},reuseaddr,fork" \
            EXEC:"$self_path --handle-request",nofork
    else
        # ncat mode
        ncat -l -k "${API_BIND}" "${API_PORT}" -e "$self_path --handle-request"
    fi
}

# =============================================================================
# ENTRY POINT
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Internal: called by socat/ncat for each incoming connection
    if [[ "$HANDLE_REQUEST" == "true" ]]; then
        handle_request
        exit 0
    fi

    if [[ "$DAEMON_MODE" == "true" ]]; then
        start_server >> "$API_LOG_FILE" 2>&1 &
        disown
        echo "API server started in background (PID: $!)"
        echo "Log: $API_LOG_FILE"
        echo "Stop: $0 --stop"
    else
        start_server
    fi
fi
