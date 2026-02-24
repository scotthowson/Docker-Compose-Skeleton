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
#   GET  /stacks/:name/compose      Raw docker-compose.yml content for a stack
#   POST /stacks/:name/start        Start a specific stack
#   POST /stacks/:name/stop         Stop a specific stack
#   POST /stacks/:name/restart      Restart a specific stack
#   POST /stacks/:name/update       Pull, detect changes, recreate if needed
#   GET  /images                    All images with age/size/staleness
#   GET  /images/stale              Only stale images (>30 days)
#   GET  /containers                All containers with status
#   GET  /containers/:name          Detailed info for a specific container
#   GET  /containers/:name/stats    Live resource stats for a container
#   GET  /containers/:name/processes Process list for a container
#   GET  /config                    Current configuration (sanitized)
#   GET  /system                    System resource information
#   GET  /networks                  Docker networks and connections
#   GET  /volumes                   Docker volumes and usage
#   GET  /logs                      Framework log (last 100 lines)
#   GET  /events                    Recent Docker events (last 50)
#   GET  /version                   API and framework version info
#
# Authentication Endpoints:
#   POST   /auth/setup              Create first admin account (no auth required)
#   POST   /auth/login              Authenticate and get session token (no auth required)
#   POST   /auth/register           Register with invite code (no auth required)
#   GET    /auth/verify             Verify a token is valid (no auth required)
#   POST   /auth/invite             Generate an invite code (admin only)
#   GET    /auth/users              List all users (admin only)
#   POST   /auth/revoke             Revoke a user's access (admin only)
#   GET    /auth/invites            List active invite codes (admin only)
#   DELETE /auth/invite/:code       Delete an invite code (admin only)
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

# Authentication configuration
API_AUTH_DIR="${BASE_DIR}/.api-auth"
API_TOKEN_EXPIRY="${API_TOKEN_EXPIRY:-86400}"       # 24 hours in seconds
API_INVITE_EXPIRY="${API_INVITE_EXPIRY:-604800}"     # 7 days in seconds
API_MAX_LOGIN_ATTEMPTS="${API_MAX_LOGIN_ATTEMPTS:-5}"
API_LOCKOUT_DURATION="${API_LOCKOUT_DURATION:-900}"  # 15 minutes in seconds

# Auto-detect whether auth is required based on bind address
# Auth is optional for localhost-only, required for external access
if [[ -n "${API_AUTH_ENABLED:-}" ]]; then
    # Explicit override from config
    API_AUTH_ENABLED="${API_AUTH_ENABLED}"
else
    case "$API_BIND" in
        127.0.0.1|localhost|::1)
            API_AUTH_ENABLED="false"
            ;;
        *)
            API_AUTH_ENABLED="true"
            ;;
    esac
fi

# IP Whitelist — comma-separated list of allowed IPs/CIDRs (empty = allow all)
# Example: API_IP_WHITELIST="192.168.1.0/24,10.0.0.5"
API_IP_WHITELIST="${API_IP_WHITELIST:-}"

# Global rate limiting — max requests per minute per IP (0 = disabled)
API_RATE_LIMIT="${API_RATE_LIMIT:-120}"
API_RATE_WINDOW="${API_RATE_WINDOW:-60}"  # window in seconds

# Rate limit tracking directory
API_RATE_DIR="/tmp/dcs-api-rates"
mkdir -p "$API_RATE_DIR" 2>/dev/null

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
    stopped=false
    if [[ -f "$API_PID_FILE" ]]; then
        pid=$(cat "$API_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            # Kill the process group to ensure socat children are also stopped
            kill -- -"$pid" 2>/dev/null || kill "$pid" 2>/dev/null
            rm -f "$API_PID_FILE"
            echo "API server stopped (PID $pid)"
            stopped=true
        else
            rm -f "$API_PID_FILE"
        fi
    fi

    # Also try to kill any socat listening on API_PORT as a fallback
    if [[ "$stopped" == "false" ]]; then
        found_pid=$(lsof -ti "tcp:${API_PORT}" -sTCP:LISTEN 2>/dev/null || true)
        if [[ -n "$found_pid" ]]; then
            kill $found_pid 2>/dev/null
            rm -f "$API_PID_FILE"
            echo "API server stopped (found listening on port ${API_PORT})"
        else
            echo "API server is not running"
        fi
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

# Escape a string for safe JSON embedding (handles all control characters)
_api_json_escape() {
    local str="$1"
    # First strip ANSI escape sequences before doing JSON escaping
    # Use perl if available (most reliable), otherwise sed
    if command -v perl >/dev/null 2>&1; then
        str=$(printf '%s' "$str" | perl -pe 's/\e\[[0-9;]*[a-zA-Z]//g; s/\e\][^\a]*\a//g; s/[\x00-\x08\x0B\x0C\x0E-\x1F]//g' 2>/dev/null) || true
    fi
    str="${str//\\/\\\\}"      # backslash
    str="${str//\"/\\\"}"      # double quote
    str="${str//$'\n'/\\n}"    # newline
    str="${str//$'\r'/\\r}"    # carriage return
    str="${str//$'\t'/\\t}"    # tab
    printf '%s' "$str"
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
        401) status_text="Unauthorized" ;;
        403) status_text="Forbidden" ;;
        404) status_text="Not Found" ;;
        405) status_text="Method Not Allowed" ;;
        409) status_text="Conflict" ;;
        429) status_text="Too Many Requests" ;;
        500) status_text="Internal Server Error" ;;
    esac

    # Use byte count (not char count) for Content-Length — critical for UTF-8
    local content_length
    content_length=$(printf '%s' "$body" | wc -c)

    printf "HTTP/1.1 %s %s\r\n" "$status_code" "$status_text"
    printf "Content-Type: application/json; charset=utf-8\r\n"
    printf "Content-Length: %d\r\n" "$content_length"
    printf "Access-Control-Allow-Origin: *\r\n"
    printf "Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r\n"
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
# QUERY STRING PARSER
# =============================================================================

declare -gA QUERY_PARAMS=()

_api_parse_query() {
    QUERY_PARAMS=()
    local full_path="$1"
    if [[ "$full_path" == *"?"* ]]; then
        local query_string="${full_path#*\?}"
        local IFS='&'
        local -a pairs
        read -ra pairs <<< "$query_string"
        for pair in "${pairs[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            value="${value//+/ }"
            QUERY_PARAMS["$key"]="$value"
        done
    fi
}

# =============================================================================
# AUTHENTICATION HELPERS
# =============================================================================

# Initialize auth data directory and files
_api_init_auth_dir() {
    if [[ ! -d "$API_AUTH_DIR" ]]; then
        mkdir -p "$API_AUTH_DIR" 2>/dev/null
        chmod 700 "$API_AUTH_DIR"
    fi
    [[ ! -f "$API_AUTH_DIR/users.json" ]]  && echo '[]' > "$API_AUTH_DIR/users.json"
    [[ ! -f "$API_AUTH_DIR/tokens.json" ]] && echo '[]' > "$API_AUTH_DIR/tokens.json"
    [[ ! -f "$API_AUTH_DIR/invites.json" ]] && echo '[]' > "$API_AUTH_DIR/invites.json"
    [[ ! -f "$API_AUTH_DIR/rate_limits.json" ]] && echo '{}' > "$API_AUTH_DIR/rate_limits.json"
}

# Hash a password with a given salt using SHA-256
_api_hash_password() {
    local salt="$1"
    local password="$2"
    echo -n "${salt}${password}" | sha256sum | cut -d' ' -f1
}

# Generate a random token
_api_generate_token() {
    openssl rand -hex 32 2>/dev/null || {
        # Fallback if openssl is not available
        local hex=""
        for i in $(seq 1 32); do
            hex+=$(printf '%02x' $(( RANDOM % 256 )))
        done
        echo "$hex"
    }
}

# Generate a random salt
_api_generate_salt() {
    openssl rand -hex 16 2>/dev/null || {
        local hex=""
        for i in $(seq 1 16); do
            hex+=$(printf '%02x' $(( RANDOM % 256 )))
        done
        echo "$hex"
    }
}

# Read a JSON auth file (returns contents)
_api_read_auth_file() {
    local file="$API_AUTH_DIR/$1"
    if [[ -f "$file" ]]; then
        cat "$file" 2>/dev/null
    else
        echo '[]'
    fi
}

# Write a JSON auth file
_api_write_auth_file() {
    local file="$API_AUTH_DIR/$1"
    local content="$2"
    printf '%s' "$content" > "$file" 2>/dev/null
}

# Get current epoch timestamp
_api_now_epoch() {
    date +%s
}

# Get current ISO timestamp
_api_now_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Check if a user exists (returns 0 if exists, 1 if not)
_api_user_exists() {
    local username="$1"
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        local count
        count=$(echo "$users" | jq -r --arg u "$username" '[.[] | select(.username == $u)] | length' 2>/dev/null)
        [[ "$count" -gt 0 ]] && return 0
    else
        echo "$users" | grep -q "\"username\": *\"$username\"" && return 0
    fi
    return 1
}

# Get user count
_api_user_count() {
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        echo "$users" | jq 'length' 2>/dev/null
    else
        # Rough count by counting username fields
        echo "$users" | grep -c '"username"' 2>/dev/null || echo "0"
    fi
}

# Get user record as JSON (requires jq)
_api_get_user() {
    local username="$1"
    local users
    users=$(_api_read_auth_file "users.json")
    echo "$users" | jq -r --arg u "$username" '.[] | select(.username == $u)' 2>/dev/null
}

# Add a user record
_api_add_user() {
    local username="$1" password_hash="$2" salt="$3" role="$4"
    local created_at
    created_at=$(_api_now_iso)
    local users
    users=$(_api_read_auth_file "users.json")
    if command -v jq >/dev/null 2>&1; then
        local new_users
        new_users=$(echo "$users" | jq \
            --arg u "$username" \
            --arg h "$password_hash" \
            --arg s "$salt" \
            --arg r "$role" \
            --arg c "$created_at" \
            '. + [{"username": $u, "password_hash": $h, "salt": $s, "role": $r, "created_at": $c}]' 2>/dev/null)
        _api_write_auth_file "users.json" "$new_users"
    else
        # Fallback: manual JSON construction
        local entry="{\"username\": \"$username\", \"password_hash\": \"$password_hash\", \"salt\": \"$salt\", \"role\": \"$role\", \"created_at\": \"$created_at\"}"
        if [[ "$users" == "[]" ]]; then
            _api_write_auth_file "users.json" "[$entry]"
        else
            # Remove trailing ] and append
            local trimmed="${users%]}"
            _api_write_auth_file "users.json" "${trimmed}, $entry]"
        fi
    fi
}

# Store a session token
_api_store_token() {
    local token="$1" username="$2" role="$3"
    local now
    now=$(_api_now_epoch)
    local expires_at=$(( now + API_TOKEN_EXPIRY ))
    local created_at
    created_at=$(_api_now_iso)
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    if command -v jq >/dev/null 2>&1; then
        local new_tokens
        new_tokens=$(echo "$tokens" | jq \
            --arg t "$token" \
            --arg u "$username" \
            --arg r "$role" \
            --arg c "$created_at" \
            --argjson e "$expires_at" \
            '. + [{"token": $t, "username": $u, "role": $r, "created_at": $c, "expires_at": $e}]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"
    else
        local entry="{\"token\": \"$token\", \"username\": \"$username\", \"role\": \"$role\", \"created_at\": \"$created_at\", \"expires_at\": $expires_at}"
        if [[ "$tokens" == "[]" ]]; then
            _api_write_auth_file "tokens.json" "[$entry]"
        else
            local trimmed="${tokens%]}"
            _api_write_auth_file "tokens.json" "${trimmed}, $entry]"
        fi
    fi
}

# Validate a token — sets AUTH_USERNAME and AUTH_ROLE on success; returns 1 on failure
_api_validate_token() {
    local token="$1"
    AUTH_USERNAME=""
    AUTH_ROLE=""

    if [[ -z "$token" ]]; then
        return 1
    fi

    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        local record
        record=$(echo "$tokens" | jq -r --arg t "$token" --argjson n "$now" \
            '.[] | select(.token == $t and .expires_at > $n)' 2>/dev/null)
        if [[ -n "$record" ]]; then
            AUTH_USERNAME=$(echo "$record" | jq -r '.username' 2>/dev/null)
            AUTH_ROLE=$(echo "$record" | jq -r '.role' 2>/dev/null)
            return 0
        fi
    else
        # Fallback: grep-based token search
        if echo "$tokens" | grep -q "\"token\": *\"$token\""; then
            # Basic extraction — limited without jq
            AUTH_USERNAME=$(echo "$tokens" | grep -A5 "\"token\": *\"$token\"" | grep '"username"' | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
            AUTH_ROLE=$(echo "$tokens" | grep -A5 "\"token\": *\"$token\"" | grep '"role"' | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
            if [[ -n "$AUTH_USERNAME" ]]; then
                return 0
            fi
        fi
    fi
    return 1
}

# =============================================================================
# IP WHITELIST & RATE LIMITING
# =============================================================================

# Check if a given IP is within a CIDR range (supports /8 /16 /24 /32)
_api_ip_in_cidr() {
    local ip="$1" cidr="$2"
    local net mask
    net="${cidr%/*}"
    mask="${cidr#*/}"
    [[ "$mask" == "$cidr" ]] && mask=32  # no slash means exact match

    # Convert IP to integer
    local IFS='.'
    local -a ip_parts=($ip) net_parts=($net)
    local ip_int=$(( (ip_parts[0] << 24) + (ip_parts[1] << 16) + (ip_parts[2] << 8) + ip_parts[3] ))
    local net_int=$(( (net_parts[0] << 24) + (net_parts[1] << 16) + (net_parts[2] << 8) + net_parts[3] ))
    local mask_int=$(( 0xFFFFFFFF << (32 - mask) ))

    (( (ip_int & mask_int) == (net_int & mask_int) ))
}

# Check if the connecting IP is allowed
# Uses SOCAT_PEERADDR environment variable set by socat
_api_check_ip_whitelist() {
    [[ -z "$API_IP_WHITELIST" ]] && return 0  # no whitelist = allow all

    local client_ip="${SOCAT_PEERADDR:-127.0.0.1}"

    # Always allow localhost
    case "$client_ip" in
        127.0.0.1|::1|localhost) return 0 ;;
    esac

    # Check each entry in the whitelist
    local IFS=','
    for entry in $API_IP_WHITELIST; do
        entry="${entry// /}"  # trim spaces
        [[ -z "$entry" ]] && continue

        # Exact match
        [[ "$client_ip" == "$entry" ]] && return 0

        # CIDR match
        if [[ "$entry" == */* ]]; then
            _api_ip_in_cidr "$client_ip" "$entry" && return 0
        fi
    done

    return 1  # not in whitelist
}

# Check global rate limit for the connecting IP
# Returns 0 if within limit, 1 if rate limited
_api_check_global_rate_limit() {
    (( API_RATE_LIMIT <= 0 )) && return 0  # rate limiting disabled

    local client_ip="${SOCAT_PEERADDR:-127.0.0.1}"
    local now
    now=$(date +%s)

    # Always allow localhost without rate limiting
    case "$client_ip" in
        127.0.0.1|::1|localhost) return 0 ;;
    esac

    # Rate file per IP (sanitize the IP for filename)
    local safe_ip="${client_ip//[^0-9a-fA-F.]/_}"
    local rate_file="${API_RATE_DIR}/${safe_ip}"

    # Clean up old entries and count recent requests
    local count=0
    local cutoff=$(( now - API_RATE_WINDOW ))

    if [[ -f "$rate_file" ]]; then
        # Remove expired timestamps and count valid ones
        local tmp_file="${rate_file}.tmp"
        while IFS= read -r ts; do
            if (( ts > cutoff )); then
                echo "$ts"
                count=$(( count + 1 ))
            fi
        done < "$rate_file" > "$tmp_file" 2>/dev/null
        mv -f "$tmp_file" "$rate_file" 2>/dev/null
    fi

    # Check if over limit
    if (( count >= API_RATE_LIMIT )); then
        return 1
    fi

    # Record this request
    echo "$now" >> "$rate_file"
    return 0
}

# Check authentication from request headers — sets AUTH_USERNAME and AUTH_ROLE
# Returns 0 on success, 1 on failure
_api_check_auth() {
    AUTH_USERNAME=""
    AUTH_ROLE=""

    # If auth is disabled, allow everything
    if [[ "$API_AUTH_ENABLED" != "true" ]]; then
        AUTH_USERNAME="anonymous"
        AUTH_ROLE="admin"
        return 0
    fi

    # If no users exist yet, allow access (setup not complete)
    local user_count
    user_count=$(_api_user_count)
    if [[ "$user_count" -eq 0 ]]; then
        AUTH_USERNAME="anonymous"
        AUTH_ROLE="admin"
        return 0
    fi

    _api_init_auth_dir

    # Extract token from Authorization header
    local token=""
    if [[ -n "${REQUEST_AUTH_HEADER:-}" ]]; then
        # Strip "Bearer " prefix
        token="${REQUEST_AUTH_HEADER#Bearer }"
        token="${token#bearer }"
    fi

    if [[ -z "$token" ]]; then
        return 1
    fi

    _api_validate_token "$token"
    return $?
}

# Check if authenticated user is admin — call after _api_check_auth
_api_check_admin() {
    if [[ "${AUTH_ROLE:-}" != "admin" ]]; then
        return 1
    fi
    return 0
}

# Rate limiting: check if an IP is locked out
_api_check_rate_limit() {
    local client_ip="${1:-unknown}"
    local rate_file="$API_AUTH_DIR/rate_limits.json"
    [[ ! -f "$rate_file" ]] && return 0

    if command -v jq >/dev/null 2>&1; then
        local now
        now=$(_api_now_epoch)
        local record
        record=$(cat "$rate_file" | jq -r --arg ip "$client_ip" '.[$ip] // empty' 2>/dev/null)
        if [[ -n "$record" ]]; then
            local attempts locked_until
            attempts=$(echo "$record" | jq -r '.attempts // 0' 2>/dev/null)
            locked_until=$(echo "$record" | jq -r '.locked_until // 0' 2>/dev/null)
            if [[ "$locked_until" -gt "$now" ]] 2>/dev/null; then
                return 1  # Still locked out
            fi
            # Reset if lock has expired
            if [[ "$locked_until" -gt 0 ]] && [[ "$locked_until" -le "$now" ]] 2>/dev/null; then
                _api_reset_rate_limit "$client_ip"
            fi
        fi
    fi
    return 0
}

# Rate limiting: record a failed login attempt
_api_record_failed_login() {
    local client_ip="${1:-unknown}"
    local rate_file="$API_AUTH_DIR/rate_limits.json"
    [[ ! -f "$rate_file" ]] && echo '{}' > "$rate_file"

    if command -v jq >/dev/null 2>&1; then
        local now
        now=$(_api_now_epoch)
        local rates
        rates=$(cat "$rate_file")
        local current_attempts
        current_attempts=$(echo "$rates" | jq -r --arg ip "$client_ip" '.[$ip].attempts // 0' 2>/dev/null)
        current_attempts=$(( current_attempts + 1 ))

        local locked_until=0
        if [[ "$current_attempts" -ge "$API_MAX_LOGIN_ATTEMPTS" ]]; then
            locked_until=$(( now + API_LOCKOUT_DURATION ))
        fi

        local new_rates
        new_rates=$(echo "$rates" | jq \
            --arg ip "$client_ip" \
            --argjson a "$current_attempts" \
            --argjson l "$locked_until" \
            --argjson t "$now" \
            '.[$ip] = {"attempts": $a, "locked_until": $l, "last_attempt": $t}' 2>/dev/null)
        printf '%s' "$new_rates" > "$rate_file"
    fi
}

# Rate limiting: reset after successful login
_api_reset_rate_limit() {
    local client_ip="${1:-unknown}"
    local rate_file="$API_AUTH_DIR/rate_limits.json"
    [[ ! -f "$rate_file" ]] && return

    if command -v jq >/dev/null 2>&1; then
        local rates
        rates=$(cat "$rate_file")
        local new_rates
        new_rates=$(echo "$rates" | jq --arg ip "$client_ip" 'del(.[$ip])' 2>/dev/null)
        printf '%s' "$new_rates" > "$rate_file"
    fi
}

# Clean up expired tokens (called periodically)
_api_cleanup_expired_tokens() {
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        local cleaned
        cleaned=$(echo "$tokens" | jq --argjson n "$now" '[.[] | select(.expires_at > $n)]' 2>/dev/null)
        [[ -n "$cleaned" ]] && _api_write_auth_file "tokens.json" "$cleaned"
    fi
}

# Store an invite code
_api_store_invite() {
    local code="$1" role="$2" created_by="$3"
    local now
    now=$(_api_now_epoch)
    local expires_at=$(( now + API_INVITE_EXPIRY ))
    local created_at
    created_at=$(_api_now_iso)
    local invites
    invites=$(_api_read_auth_file "invites.json")

    if command -v jq >/dev/null 2>&1; then
        local new_invites
        new_invites=$(echo "$invites" | jq \
            --arg c "$code" \
            --arg r "$role" \
            --arg b "$created_by" \
            --arg ca "$created_at" \
            --argjson e "$expires_at" \
            '. + [{"code": $c, "role": $r, "created_by": $b, "created_at": $ca, "expires_at": $e, "used": false, "used_by": ""}]' 2>/dev/null)
        _api_write_auth_file "invites.json" "$new_invites"
    else
        local entry="{\"code\": \"$code\", \"role\": \"$role\", \"created_by\": \"$created_by\", \"created_at\": \"$created_at\", \"expires_at\": $expires_at, \"used\": false, \"used_by\": \"\"}"
        if [[ "$invites" == "[]" ]]; then
            _api_write_auth_file "invites.json" "[$entry]"
        else
            local trimmed="${invites%]}"
            _api_write_auth_file "invites.json" "${trimmed}, $entry]"
        fi
    fi
}

# Validate an invite code — returns role on success, empty on failure
_api_validate_invite() {
    local code="$1"
    local invites
    invites=$(_api_read_auth_file "invites.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        local record
        record=$(echo "$invites" | jq -r --arg c "$code" --argjson n "$now" \
            '.[] | select(.code == $c and .expires_at > $n and (.used != true))' 2>/dev/null)
        if [[ -n "$record" ]]; then
            echo "$record" | jq -r '.role' 2>/dev/null
            return 0
        fi
    else
        if echo "$invites" | grep -q "\"code\": *\"$code\""; then
            echo "user"
            return 0
        fi
    fi
    return 1
}

# Consume an invite code after use — marks as used instead of deleting
_api_consume_invite() {
    local code="$1" username="${2:-unknown}"
    local invites
    invites=$(_api_read_auth_file "invites.json")

    if command -v jq >/dev/null 2>&1; then
        local new_invites
        new_invites=$(echo "$invites" | jq --arg c "$code" --arg u "$username" \
            '[.[] | if .code == $c then . + {"used": true, "used_by": $u} else . end]' 2>/dev/null)
        _api_write_auth_file "invites.json" "$new_invites"
    fi
}

# Delete a specific invite code by value
_api_delete_invite() {
    local code="$1"
    local invites
    invites=$(_api_read_auth_file "invites.json")

    if command -v jq >/dev/null 2>&1; then
        local exists
        exists=$(echo "$invites" | jq -r --arg c "$code" '[.[] | select(.code == $c)] | length' 2>/dev/null)
        if [[ "$exists" -eq 0 ]]; then
            return 1
        fi
        local new_invites
        new_invites=$(echo "$invites" | jq --arg c "$code" '[.[] | select(.code != $c)]' 2>/dev/null)
        _api_write_auth_file "invites.json" "$new_invites"
        return 0
    fi
    return 1
}

# Revoke all tokens for a user
_api_revoke_user_tokens() {
    local username="$1"
    local tokens
    tokens=$(_api_read_auth_file "tokens.json")

    if command -v jq >/dev/null 2>&1; then
        local new_tokens
        new_tokens=$(echo "$tokens" | jq --arg u "$username" '[.[] | select(.username != $u)]' 2>/dev/null)
        _api_write_auth_file "tokens.json" "$new_tokens"
    fi
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
    {"method": "GET",  "path": "/stacks/:name/compose",      "description": "Raw docker-compose.yml content"},
    {"method": "POST", "path": "/stacks/:name/start",        "description": "Start a stack"},
    {"method": "POST", "path": "/stacks/:name/stop",         "description": "Stop a stack"},
    {"method": "POST", "path": "/stacks/:name/restart",      "description": "Restart a stack"},
    {"method": "POST", "path": "/stacks/:name/update",       "description": "Pull, detect, recreate"},
    {"method": "GET",  "path": "/images",                    "description": "All images with metadata"},
    {"method": "GET",  "path": "/images/stale",              "description": "Only stale images (>30d)"},
    {"method": "GET",  "path": "/containers",                "description": "All containers with status"},
    {"method": "GET",  "path": "/containers/:name",          "description": "Detailed container info"},
    {"method": "GET",  "path": "/containers/:name/stats",    "description": "Live resource stats"},
    {"method": "GET",  "path": "/containers/:name/processes","description": "Container process list"},
    {"method": "GET",  "path": "/config",                    "description": "Current configuration"},
    {"method": "GET",  "path": "/system",                    "description": "System resource info"},
    {"method": "GET",  "path": "/networks",                  "description": "Docker networks"},
    {"method": "GET",  "path": "/volumes",                   "description": "Docker volumes"},
    {"method": "GET",  "path": "/logs",                      "description": "Framework log tail"},
    {"method": "GET",  "path": "/events",                    "description": "Recent Docker events"},
    {"method": "GET",  "path": "/version",                   "description": "Version information"},
    {"method": "POST",   "path": "/auth/setup",              "description": "Create first admin account", "auth": false},
    {"method": "POST",   "path": "/auth/login",              "description": "Authenticate and get token", "auth": false},
    {"method": "POST",   "path": "/auth/register",           "description": "Register with invite code", "auth": false},
    {"method": "GET",    "path": "/auth/verify",             "description": "Verify a token", "auth": false},
    {"method": "POST",   "path": "/auth/invite",             "description": "Generate invite code", "auth": "admin"},
    {"method": "GET",    "path": "/auth/users",              "description": "List all users", "auth": "admin"},
    {"method": "POST",   "path": "/auth/revoke",             "description": "Revoke user access", "auth": "admin"},
    {"method": "GET",    "path": "/auth/invites",            "description": "List active invites", "auth": "admin"},
    {"method": "DELETE",  "path": "/auth/invite/:code",      "description": "Delete invite code", "auth": "admin"}
  ]'

    _api_success "{\"name\": \"Docker Compose Skeleton API\", \"version\": \"$API_VERSION\", \"auth_enabled\": $API_AUTH_ENABLED, \"endpoints\": $endpoints}"
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

    # Fast stack status: run all checks in parallel subshells
    local stacks
    stacks=($(_api_get_stacks))
    local running_stacks=0
    local tmpdir
    tmpdir=$(mktemp -d)

    for s in "${stacks[@]}"; do
        (
            local compose_file="$COMPOSE_DIR/$s/docker-compose.yml"
            local env_file="$COMPOSE_DIR/$s/.env"
            local -a args=(-f "$compose_file")
            [[ -f "$env_file" ]] && args+=(--env-file "$env_file")
            local count
            count=$($DOCKER_COMPOSE_CMD "${args[@]}" ps -q 2>/dev/null | wc -l)
            echo "$count" > "$tmpdir/$s"
        ) &
    done
    wait

    for s in "${stacks[@]}"; do
        local count=0
        [[ -f "$tmpdir/$s" ]] && count=$(cat "$tmpdir/$s")
        [[ "$count" -gt 0 ]] && running_stacks=$(( running_stacks + 1 ))
    done
    rm -rf "$tmpdir"

    _api_success "{\"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\", \"hostname\": \"$(hostname)\", \"uptime_seconds\": $uptime_seconds, \"docker\": {\"containers\": {\"total\": $total_containers, \"running\": $running_containers, \"stopped\": $stopped_containers}, \"images\": $total_images, \"volumes\": $total_volumes, \"networks\": $total_networks}, \"stacks\": {\"total\": ${#stacks[@]}, \"running\": $running_stacks}, \"system\": {\"load_average\": $load_avg, \"memory_mb\": {\"total\": $mem_total, \"available\": $mem_available}, \"disk\": $disk_usage}}"
}

handle_health() {
    local -a results=()
    local total=0 healthy=0 unhealthy=0 stopped=0

    while IFS= read -r cid; do
        [[ -z "$cid" ]] && continue
        total=$(( total + 1 ))

        local name state health
        name=$(docker inspect --format='{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||')
        state=$(docker inspect --format='{{.State.Status}}' "$cid" 2>/dev/null)
        health=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)

        if [[ "$state" != "running" ]]; then
            stopped=$(( stopped + 1 ))
        elif [[ "$health" == "unhealthy" ]]; then
            unhealthy=$(( unhealthy + 1 ))
        else
            healthy=$(( healthy + 1 ))
        fi

        results+=("{\"name\": \"$(_api_json_escape "$name")\", \"state\": \"$state\", \"health\": \"$health\"}")
    done < <(docker ps -a -q 2>/dev/null)

    # Status logic: stopped containers are expected/normal and don't affect health.
    # Only actually unhealthy containers (failed healthchecks) trigger warnings.
    local overall="healthy"
    if (( unhealthy >= 3 )); then
        overall="critical"
    elif (( unhealthy > 0 )); then
        overall="degraded"
    fi

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

handle_stack_compose() {
    local stack="$1"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"

    if [[ ! -f "$compose_file" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    local content
    content=$(cat "$compose_file" 2>/dev/null) || {
        _api_error 500 "Failed to read compose file for stack: $stack"
        return
    }

    local escaped
    escaped=$(_api_json_escape "$content")

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"content\": \"$escaped\"}"
}

# =============================================================================
# COMPOSE EDITOR & STACK ENV HANDLERS (Phase 1)
# =============================================================================

handle_stack_compose_validate() {
    local stack="$1"
    local body="$2"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for compose validation"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    local tmpfile
    tmpfile=$(mktemp /tmp/dcs-compose-validate-XXXXXX.yml)
    printf '%s' "$content" > "$tmpfile"

    local env_args=()
    if [[ -f "$COMPOSE_DIR/$stack/.env" ]]; then
        env_args=(--env-file "$COMPOSE_DIR/$stack/.env")
    fi

    local validation_output
    local valid=true
    validation_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config 2>&1) || valid=false
    rm -f "$tmpfile"

    local escaped_output
    escaped_output=$(_api_json_escape "$validation_output")

    _api_success "{\"valid\": $valid, \"stack\": \"$(_api_json_escape "$stack")\", \"output\": \"$escaped_output\"}"
}

handle_stack_compose_save() {
    local stack="$1"
    local body="$2"
    local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for compose save"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    # Validate before saving
    local tmpfile
    tmpfile=$(mktemp /tmp/dcs-compose-save-XXXXXX.yml)
    printf '%s' "$content" > "$tmpfile"

    local env_args=()
    if [[ -f "$COMPOSE_DIR/$stack/.env" ]]; then
        env_args=(--env-file "$COMPOSE_DIR/$stack/.env")
    fi

    local validation_output
    validation_output=$($DOCKER_COMPOSE_CMD -f "$tmpfile" "${env_args[@]}" config 2>&1)
    local valid=$?
    rm -f "$tmpfile"

    if [[ $valid -ne 0 ]]; then
        local escaped_errors
        escaped_errors=$(_api_json_escape "$validation_output")
        _api_success "{\"success\": false, \"stack\": \"$(_api_json_escape "$stack")\", \"message\": \"Validation failed\", \"validated\": false, \"validation_errors\": \"$escaped_errors\"}"
        return
    fi

    # Backup original
    if [[ -f "$compose_file" ]]; then
        cp "$compose_file" "${compose_file}.bak" 2>/dev/null
    fi

    # Write new content
    printf '%s' "$content" > "$compose_file" 2>/dev/null || {
        _api_error 500 "Failed to write compose file"
        return
    }

    _api_success "{\"success\": true, \"stack\": \"$(_api_json_escape "$stack")\", \"message\": \"Compose file saved successfully\", \"validated\": true}"
}

handle_stack_env() {
    local stack="$1"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if [[ ! -f "$env_file" ]]; then
        _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"raw\": \"\", \"variables\": []}"
        return
    fi

    local raw
    raw=$(cat "$env_file" 2>/dev/null)
    local escaped_raw
    escaped_raw=$(_api_json_escape "$raw")

    local -a vars=()
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ ))
        if [[ -z "$line" ]]; then
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            vars+=("{\"key\": \"\", \"value\": \"\", \"line\": $line_num, \"comment\": \"$(_api_json_escape "$line")\"}")
            continue
        fi
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            vars+=("{\"key\": \"$(_api_json_escape "$key")\", \"value\": \"$(_api_json_escape "$value")\", \"line\": $line_num, \"comment\": \"\"}")
        fi
    done < "$env_file"

    local vars_json
    if [[ ${#vars[@]} -gt 0 ]]; then
        vars_json=$(printf '%s,' "${vars[@]}")
        vars_json="[${vars_json%,}]"
    else
        vars_json="[]"
    fi

    _api_success "{\"stack\": \"$(_api_json_escape "$stack")\", \"raw\": \"$escaped_raw\", \"variables\": $vars_json}"
}

handle_stack_env_save() {
    local stack="$1"
    local body="$2"
    local env_file="$COMPOSE_DIR/$stack/.env"

    if [[ ! -d "$COMPOSE_DIR/$stack" ]]; then
        _api_error 404 "Stack not found: $stack"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for env save"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    # Backup existing
    if [[ -f "$env_file" ]]; then
        cp "$env_file" "${env_file}.bak" 2>/dev/null
    fi

    printf '%s' "$content" > "$env_file" 2>/dev/null || {
        _api_error 500 "Failed to write .env file"
        return
    }

    _api_success "{\"success\": true, \"stack\": \"$(_api_json_escape "$stack")\", \"message\": \"Stack .env file saved successfully\"}"
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

handle_container_processes() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    # Verify the container is running (docker top requires a running container)
    local state
    state=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null)
    if [[ "$state" != "running" ]]; then
        _api_error 400 "Container is not running: $name (state: $state)"
        return
    fi

    local top_output
    top_output=$(docker top "$name" -eo uid,pid,ppid,%cpu,time,cmd 2>&1) || {
        _api_error 500 "Failed to get processes: $(_api_json_escape "$top_output")"
        return
    }

    local -a entries=()
    local header_skipped=false
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # Skip the header line
        if [[ "$header_skipped" == "false" ]]; then
            header_skipped=true
            continue
        fi

        # Parse columns: UID PID PPID %CPU TIME CMD (CMD may contain spaces)
        local uid pid ppid cpu time cmd
        read -r uid pid ppid cpu time cmd <<< "$line"

        entries+=("{\"uid\": \"$(_api_json_escape "$uid")\", \"pid\": \"$(_api_json_escape "$pid")\", \"ppid\": \"$(_api_json_escape "$ppid")\", \"cpu\": \"$(_api_json_escape "$cpu")\", \"time\": \"$(_api_json_escape "$time")\", \"cmd\": \"$(_api_json_escape "$cmd")\"}")
    done <<< "$top_output"

    local json
    json=$(printf '%s,' "${entries[@]}")
    json="[${json%,}]"

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"processes\": $json}"
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
    config+="\"ntfy_url\": \"$(_api_json_escape "${NTFY_URL:-}")\","
    config+="\"ntfy_topic\": \"$(_api_json_escape "${NTFY_TOPIC:-}")\","
    config+="\"ntfy_priority\": \"$(_api_json_escape "${NTFY_PRIORITY:-default}")\","
    config+="\"enable_colors\": ${ENABLE_COLORS:-true},"
    config+="\"color_mode\": \"${COLOR_MODE:-auto}\","
    config+="\"api_enabled\": ${API_ENABLED:-true},"
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

handle_disks() {
    local -a disk_entries=()
    while IFS='|' read -r device mount total used available percent; do
        [[ -z "$device" || "$device" == "Filesystem" ]] && continue
        # Skip system/firmware mounts that aren't user-relevant
        case "$mount" in
            /sys/*|/proc/*|/dev/*|/run/*|/snap/*|/boot/efi|/boot/grub) continue ;;
        esac
        # Skip entries with no device path (virtual filesystems)
        [[ "$device" != /* ]] && continue
        disk_entries+=("{\"device\": \"$(_api_json_escape "$device")\", \"mount\": \"$(_api_json_escape "$mount")\", \"total\": \"$(_api_json_escape "$total")\", \"used\": \"$(_api_json_escape "$used")\", \"available\": \"$(_api_json_escape "$available")\", \"percent\": \"$(_api_json_escape "$percent")\"}")
    done < <(df -h --output=source,target,size,used,avail,pcent -x tmpfs -x devtmpfs -x squashfs -x overlay -x efivarfs -x vfat 2>/dev/null | tail -n +2 | awk '{print $1"|"$2"|"$3"|"$4"|"$5"|"$6}')

    local json
    json=$(printf '%s,' "${disk_entries[@]}")
    json="[${json%,}]"

    _api_success "{\"total\": ${#disk_entries[@]}, \"disks\": $json}"
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

handle_create_network() {
    local body="$1"
    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for network creation"
        return
    fi

    local name driver subnet gateway internal
    name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)
    driver=$(echo "$body" | jq -r '.driver // "bridge"' 2>/dev/null)
    subnet=$(echo "$body" | jq -r '.subnet // empty' 2>/dev/null)
    gateway=$(echo "$body" | jq -r '.gateway // empty' 2>/dev/null)
    internal=$(echo "$body" | jq -r '.internal // false' 2>/dev/null)

    if [[ -z "$name" ]]; then
        _api_error 400 "Network name is required"
        return
    fi

    # Validate name (alphanumeric, hyphens, underscores)
    if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        _api_error 400 "Invalid network name. Use alphanumeric characters, hyphens, underscores, and dots."
        return
    fi

    # Check if network already exists
    if docker network inspect "$name" >/dev/null 2>&1; then
        _api_error 409 "Network '$name' already exists"
        return
    fi

    # Build docker command
    local -a cmd=(docker network create --driver "$driver")
    if [[ -n "$subnet" ]]; then
        cmd+=(--subnet "$subnet")
    fi
    if [[ -n "$gateway" ]]; then
        cmd+=(--gateway "$gateway")
    fi
    if [[ "$internal" == "true" ]]; then
        cmd+=(--internal)
    fi
    cmd+=("$name")

    local output
    output=$("${cmd[@]}" 2>&1) || {
        _api_error 500 "Failed to create network: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"message\": \"Network '$name' created successfully\"}"
}

handle_delete_network() {
    local name="$1"

    if [[ -z "$name" ]]; then
        _api_error 400 "Network name is required"
        return
    fi

    # Check if network exists
    if ! docker network inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Network '$name' not found"
        return
    fi

    # Prevent deleting built-in networks
    if [[ "$name" == "bridge" || "$name" == "host" || "$name" == "none" ]]; then
        _api_error 403 "Cannot delete built-in network '$name'"
        return
    fi

    # Check for connected containers
    local connected
    connected=$(docker network inspect --format='{{range $k, $v := .Containers}}{{$v.Name}} {{end}}' "$name" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | wc -l || true)
    if [[ "$connected" -gt 0 ]]; then
        _api_error 409 "Network '$name' has $connected connected container(s). Disconnect them first."
        return
    fi

    local output
    output=$(docker network rm "$name" 2>&1) || {
        _api_error 500 "Failed to delete network: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Network '$name' deleted successfully\"}"
}

handle_network_connect() {
    local name="$1" body="$2"
    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local container
    container=$(echo "$body" | jq -r '.container // empty' 2>/dev/null)

    if [[ -z "$container" ]]; then
        _api_error 400 "Container name is required"
        return
    fi

    local output
    output=$(docker network connect "$name" "$container" 2>&1) || {
        _api_error 500 "Failed to connect: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"network\": \"$(_api_json_escape "$name")\", \"container\": \"$(_api_json_escape "$container")\", \"message\": \"Connected '$container' to '$name'\"}"
}

handle_network_disconnect() {
    local name="$1" body="$2"
    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required"
        return
    fi

    local container
    container=$(echo "$body" | jq -r '.container // empty' 2>/dev/null)

    if [[ -z "$container" ]]; then
        _api_error 400 "Container name is required"
        return
    fi

    local output
    output=$(docker network disconnect "$name" "$container" 2>&1) || {
        _api_error 500 "Failed to disconnect: $(_api_json_escape "$output")"
        return
    }

    _api_success "{\"success\": true, \"network\": \"$(_api_json_escape "$name")\", \"container\": \"$(_api_json_escape "$container")\", \"message\": \"Disconnected '$container' from '$name'\"}"
}

handle_network_detail() {
    local name="$1"

    if ! docker network inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Network '$name' not found"
        return
    fi

    local inspect_json
    inspect_json=$(docker network inspect "$name" 2>/dev/null)

    local id driver scope internal ipam_subnet ipam_gateway
    id=$(echo "$inspect_json" | jq -r '.[0].Id // empty' 2>/dev/null)
    driver=$(echo "$inspect_json" | jq -r '.[0].Driver // empty' 2>/dev/null)
    scope=$(echo "$inspect_json" | jq -r '.[0].Scope // empty' 2>/dev/null)
    internal=$(echo "$inspect_json" | jq -r '.[0].Internal // false' 2>/dev/null)
    ipam_subnet=$(echo "$inspect_json" | jq -r '.[0].IPAM.Config[0].Subnet // empty' 2>/dev/null)
    ipam_gateway=$(echo "$inspect_json" | jq -r '.[0].IPAM.Config[0].Gateway // empty' 2>/dev/null)

    # Get containers with their IPs
    local -a container_entries=()
    while IFS='|' read -r cid cname cipv4; do
        [[ -z "$cid" ]] && continue
        container_entries+=("{\"id\": \"$(_api_json_escape "$cid")\", \"name\": \"$(_api_json_escape "$cname")\", \"ipv4\": \"$(_api_json_escape "$cipv4")\"}")
    done < <(echo "$inspect_json" | jq -r '.[0].Containers | to_entries[] | "\(.key)|\(.value.Name)|\(.value.IPv4Address)"' 2>/dev/null)

    local ce_json
    ce_json=$(printf '%s,' "${container_entries[@]}")
    ce_json="[${ce_json%,}]"

    _api_success "{\"id\": \"$(_api_json_escape "$id")\", \"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\", \"scope\": \"$(_api_json_escape "$scope")\", \"internal\": $internal, \"subnet\": \"$(_api_json_escape "$ipam_subnet")\", \"gateway\": \"$(_api_json_escape "$ipam_gateway")\", \"containers\": $ce_json}"
}

handle_delete_volume() {
    local name="$1"

    if [[ -z "$name" ]]; then
        _api_error 400 "Volume name is required"
        return
    fi

    # Check if volume exists
    if ! docker volume inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Volume '$name' not found"
        return
    fi

    local output
    output=$(docker volume rm "$name" 2>&1) || {
        _api_error 500 "Failed to delete volume: $(_api_json_escape "$output"). It may be in use by a container."
        return
    }

    _api_success "{\"success\": true, \"name\": \"$(_api_json_escape "$name")\", \"message\": \"Volume '$name' deleted successfully\"}"
}

handle_logs() {
    local log_file="${BASE_DIR}/logs/docker-services.log"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"log_file\": \"\", \"lines\": 0, \"logs\": \"\"}"
        return
    fi

    local num_lines="${QUERY_PARAMS[lines]:-100}"
    local level_filter="${QUERY_PARAMS[level]:-}"
    local search_filter="${QUERY_PARAMS[search]:-}"

    [[ "$num_lines" =~ ^[0-9]+$ ]] || num_lines=100
    (( num_lines > 5000 )) && num_lines=5000

    local content
    if [[ -n "$level_filter" || -n "$search_filter" ]]; then
        content=$(tail -"$num_lines" "$log_file" 2>/dev/null)
        if [[ -n "$level_filter" ]]; then
            content=$(printf '%s\n' "$content" | grep -i "\[$level_filter\]" 2>/dev/null || true)
        fi
        if [[ -n "$search_filter" ]]; then
            content=$(printf '%s\n' "$content" | grep -i "$search_filter" 2>/dev/null || true)
        fi
    else
        content=$(tail -"$num_lines" "$log_file" 2>/dev/null)
    fi

    local escaped
    escaped=$(_api_json_escape "$content")
    local actual_lines
    actual_lines=$(printf '%s' "$content" | wc -l | tr -d ' ')

    _api_success "{\"log_file\": \"$(_api_json_escape "$log_file")\", \"lines\": $actual_lines, \"logs\": \"$escaped\"}"
}

handle_logs_stats() {
    local log_file="${BASE_DIR}/logs/docker-services.log"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"total_lines\": 0, \"file_size\": \"0\", \"levels\": {\"error\":0,\"critical\":0,\"warning\":0,\"success\":0,\"info\":0,\"debug\":0,\"step\":0,\"timing\":0}, \"sessions\": 0, \"archives\": {\"count\": 0, \"total_size\": \"0\"}}"
        return
    fi

    local total_lines file_size
    total_lines=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')
    file_size=$(du -h "$log_file" 2>/dev/null | awk '{print $1}')

    local errors warnings successes infos debugs steps timings criticals
    errors=$(grep -c '\[ERROR\]' "$log_file" 2>/dev/null || echo 0)
    criticals=$(grep -c '\[CRITICAL\]' "$log_file" 2>/dev/null || echo 0)
    warnings=$(grep -c '\[WARNING\]' "$log_file" 2>/dev/null || echo 0)
    successes=$(grep -c '\[SUCCESS\]' "$log_file" 2>/dev/null || echo 0)
    infos=$(grep -c '\[INFO\]' "$log_file" 2>/dev/null || echo 0)
    debugs=$(grep -c '\[DEBUG\]' "$log_file" 2>/dev/null || echo 0)
    steps=$(grep -c '\[STEP' "$log_file" 2>/dev/null || echo 0)
    timings=$(grep -c '\[TIMING\]' "$log_file" 2>/dev/null || echo 0)

    local sessions
    sessions=$(grep -c 'Session Started' "$log_file" 2>/dev/null || echo 0)

    local archive_count=0 archive_size="0"
    local archive_dir="${BASE_DIR}/logs/archive"
    if [[ -d "$archive_dir" ]]; then
        archive_count=$(ls -1 "$archive_dir"/docker-services-*.log* 2>/dev/null | wc -l | tr -d ' ')
        archive_size=$(du -sh "$archive_dir" 2>/dev/null | awk '{print $1}')
    fi

    _api_success "{\"total_lines\": $total_lines, \"file_size\": \"$(_api_json_escape "${file_size:-0}")\", \"levels\": {\"error\": $errors, \"critical\": $criticals, \"warning\": $warnings, \"success\": $successes, \"info\": $infos, \"debug\": $debugs, \"step\": $steps, \"timing\": $timings}, \"sessions\": $sessions, \"archives\": {\"count\": $archive_count, \"total_size\": \"$(_api_json_escape "${archive_size:-0}")\"}}"
}

handle_logs_archives() {
    local archive_dir="${BASE_DIR}/logs/archive"

    if [[ ! -d "$archive_dir" ]]; then
        _api_success "{\"archives\": [], \"total_size\": \"0\"}"
        return
    fi

    local -a archives=()
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        local filename size date_str
        filename=$(echo "$entry" | awk '{print $NF}' | xargs basename 2>/dev/null)
        size=$(echo "$entry" | awk '{print $5}')
        date_str=$(echo "$entry" | awk '{print $6, $7, $8}')
        archives+=("{\"filename\": \"$(_api_json_escape "$filename")\", \"size\": \"$(_api_json_escape "$size")\", \"date\": \"$(_api_json_escape "$date_str")\"}")
    done < <(ls -lhtr "$archive_dir"/*.log* 2>/dev/null)

    local archives_json
    if [[ ${#archives[@]} -gt 0 ]]; then
        archives_json=$(printf '%s,' "${archives[@]}")
        archives_json="[${archives_json%,}]"
    else
        archives_json="[]"
    fi

    local total_size
    total_size=$(du -sh "$archive_dir" 2>/dev/null | awk '{print $1}')

    _api_success "{\"archives\": $archives_json, \"total_size\": \"$(_api_json_escape "${total_size:-0}")\"}"
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
# AUTHENTICATION ENDPOINT HANDLERS
# =============================================================================

# POST /auth/setup — Create the first admin account (only when no users exist)
handle_auth_setup() {
    local body="$1"

    _api_init_auth_dir

    local user_count
    user_count=$(_api_user_count)
    if [[ "$user_count" -gt 0 ]]; then
        _api_error 400 "Setup already complete. Users already exist."
        return
    fi

    local username password
    if command -v jq >/dev/null 2>&1; then
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)
    else
        username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
        password=$(echo "$body" | sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$username" ]] || [[ -z "$password" ]]; then
        _api_error 400 "Missing required fields: username and password"
        return
    fi

    # Validate username (alphanumeric, hyphens, underscores, 3-32 chars)
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        _api_error 400 "Invalid username. Use 3-32 alphanumeric characters, hyphens, or underscores."
        return
    fi

    # Validate password length
    if [[ ${#password} -lt 8 ]]; then
        _api_error 400 "Password must be at least 8 characters"
        return
    fi

    local salt
    salt=$(_api_generate_salt)
    local password_hash
    password_hash=$(_api_hash_password "$salt" "$password")

    _api_add_user "$username" "$password_hash" "$salt" "admin"

    local token
    token=$(_api_generate_token)
    _api_store_token "$token" "$username" "admin"

    _api_success "{\"success\": true, \"token\": \"$token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"admin\", \"message\": \"Admin account created successfully\"}"
}

# POST /auth/login — Authenticate and get a session token
handle_auth_login() {
    local body="$1"

    _api_init_auth_dir

    # Rate limit check (use SOCAT_PEERADDR if available, fallback to "unknown")
    local client_ip="${SOCAT_PEERADDR:-unknown}"
    if ! _api_check_rate_limit "$client_ip"; then
        _api_error 429 "Too many failed login attempts. Please try again later."
        return
    fi

    local username password
    if command -v jq >/dev/null 2>&1; then
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)
    else
        username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
        password=$(echo "$body" | sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$username" ]] || [[ -z "$password" ]]; then
        _api_error 400 "Missing required fields: username and password"
        return
    fi

    # Look up user
    if ! _api_user_exists "$username"; then
        _api_record_failed_login "$client_ip"
        _api_error 401 "Invalid username or password"
        return
    fi

    local user_record
    user_record=$(_api_get_user "$username")
    if [[ -z "$user_record" ]]; then
        _api_record_failed_login "$client_ip"
        _api_error 401 "Invalid username or password"
        return
    fi

    local stored_hash stored_salt role
    if command -v jq >/dev/null 2>&1; then
        stored_hash=$(echo "$user_record" | jq -r '.password_hash' 2>/dev/null)
        stored_salt=$(echo "$user_record" | jq -r '.salt' 2>/dev/null)
        role=$(echo "$user_record" | jq -r '.role' 2>/dev/null)
    else
        stored_hash=$(echo "$user_record" | sed -n 's/.*"password_hash" *: *"\([^"]*\)".*/\1/p')
        stored_salt=$(echo "$user_record" | sed -n 's/.*"salt" *: *"\([^"]*\)".*/\1/p')
        role=$(echo "$user_record" | sed -n 's/.*"role" *: *"\([^"]*\)".*/\1/p')
    fi

    # Verify password
    local computed_hash
    computed_hash=$(_api_hash_password "$stored_salt" "$password")

    if [[ "$computed_hash" != "$stored_hash" ]]; then
        _api_record_failed_login "$client_ip"
        _api_error 401 "Invalid username or password"
        return
    fi

    # Success — reset rate limit and create token
    _api_reset_rate_limit "$client_ip"

    # Clean up expired tokens periodically
    _api_cleanup_expired_tokens

    local token
    token=$(_api_generate_token)
    _api_store_token "$token" "$username" "$role"

    _api_success "{\"success\": true, \"token\": \"$token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"$(_api_json_escape "$role")\"}"
}

# POST /auth/invite — Generate an invite code (admin only)
handle_auth_invite() {
    local body="$1"

    _api_init_auth_dir

    # Must be admin
    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local role="user"
    if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
        local body_role
        body_role=$(echo "$body" | jq -r '.role // empty' 2>/dev/null)
        [[ -n "$body_role" ]] && role="$body_role"
    fi

    # Validate role
    if [[ "$role" != "user" ]] && [[ "$role" != "admin" ]]; then
        _api_error 400 "Invalid role. Must be 'user' or 'admin'."
        return
    fi

    local code
    code=$(_api_generate_token)
    # Use a shorter invite code (first 16 chars)
    code="${code:0:16}"

    _api_store_invite "$code" "$role" "${AUTH_USERNAME:-unknown}"

    local now
    now=$(_api_now_epoch)
    local expires_at=$(( now + API_INVITE_EXPIRY ))
    local expires_at_iso
    expires_at_iso=$(date -u -d "@$expires_at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

    _api_success "{\"success\": true, \"code\": \"$code\", \"role\": \"$(_api_json_escape "$role")\", \"expires_at\": \"$expires_at_iso\"}"
}

# POST /auth/register — Register a new account with an invite code
handle_auth_register() {
    local body="$1"

    _api_init_auth_dir

    local username password invite_code
    if command -v jq >/dev/null 2>&1; then
        username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
        password=$(echo "$body" | jq -r '.password // empty' 2>/dev/null)
        invite_code=$(echo "$body" | jq -r '.invite_code // empty' 2>/dev/null)
    else
        username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
        password=$(echo "$body" | sed -n 's/.*"password" *: *"\([^"]*\)".*/\1/p')
        invite_code=$(echo "$body" | sed -n 's/.*"invite_code" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$username" ]] || [[ -z "$password" ]] || [[ -z "$invite_code" ]]; then
        _api_error 400 "Missing required fields: username, password, and invite_code"
        return
    fi

    # Validate username
    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        _api_error 400 "Invalid username. Use 3-32 alphanumeric characters, hyphens, or underscores."
        return
    fi

    # Validate password length
    if [[ ${#password} -lt 8 ]]; then
        _api_error 400 "Password must be at least 8 characters"
        return
    fi

    # Check if username already exists
    if _api_user_exists "$username"; then
        _api_error 409 "Username already taken"
        return
    fi

    # Validate invite code
    local role
    role=$(_api_validate_invite "$invite_code") || {
        _api_error 400 "Invalid or expired invite code"
        return
    }

    if [[ -z "$role" ]]; then
        _api_error 400 "Invalid or expired invite code"
        return
    fi

    # Create user
    local salt
    salt=$(_api_generate_salt)
    local password_hash
    password_hash=$(_api_hash_password "$salt" "$password")

    _api_add_user "$username" "$password_hash" "$salt" "$role"

    # Consume the invite code
    _api_consume_invite "$invite_code" "$username"

    # Generate session token
    local token
    token=$(_api_generate_token)
    _api_store_token "$token" "$username" "$role"

    _api_success "{\"success\": true, \"token\": \"$token\", \"username\": \"$(_api_json_escape "$username")\", \"role\": \"$(_api_json_escape "$role")\"}"
}

# GET /auth/verify — Verify a token is valid
handle_auth_verify() {
    _api_init_auth_dir

    # Extract token from Authorization header
    local token=""
    if [[ -n "${REQUEST_AUTH_HEADER:-}" ]]; then
        token="${REQUEST_AUTH_HEADER#Bearer }"
        token="${token#bearer }"
    fi

    if [[ -z "$token" ]]; then
        _api_success "{\"valid\": false, \"message\": \"No token provided\"}"
        return
    fi

    if _api_validate_token "$token"; then
        _api_success "{\"valid\": true, \"username\": \"$(_api_json_escape "$AUTH_USERNAME")\", \"role\": \"$(_api_json_escape "$AUTH_ROLE")\"}"
    else
        _api_success "{\"valid\": false, \"message\": \"Token is invalid or expired\"}"
    fi
}

# GET /auth/users — List all users (admin only)
handle_auth_users() {
    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local users
    users=$(_api_read_auth_file "users.json")

    if command -v jq >/dev/null 2>&1; then
        # Strip sensitive fields (password_hash, salt)
        local safe_users
        safe_users=$(echo "$users" | jq '[.[] | {username: .username, role: .role, created_at: .created_at}]' 2>/dev/null)
        _api_success "{\"users\": $safe_users}"
    else
        # Fallback: return raw but note it may contain hashes
        _api_success "{\"users\": $users}"
    fi
}

# POST /auth/revoke — Revoke a user's access (admin only)
handle_auth_revoke() {
    local body="$1"

    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local target_username
    if command -v jq >/dev/null 2>&1; then
        target_username=$(echo "$body" | jq -r '.username // empty' 2>/dev/null)
    else
        target_username=$(echo "$body" | sed -n 's/.*"username" *: *"\([^"]*\)".*/\1/p')
    fi

    if [[ -z "$target_username" ]]; then
        _api_error 400 "Missing required field: username"
        return
    fi

    # Prevent self-revocation
    if [[ "$target_username" == "${AUTH_USERNAME:-}" ]]; then
        _api_error 400 "Cannot revoke your own access"
        return
    fi

    if ! _api_user_exists "$target_username"; then
        _api_error 404 "User not found: $target_username"
        return
    fi

    # Revoke all tokens for the user
    _api_revoke_user_tokens "$target_username"

    # Remove the user from users.json
    if command -v jq >/dev/null 2>&1; then
        local users
        users=$(_api_read_auth_file "users.json")
        local new_users
        new_users=$(echo "$users" | jq --arg u "$target_username" '[.[] | select(.username != $u)]' 2>/dev/null)
        _api_write_auth_file "users.json" "$new_users"
    fi

    _api_success "{\"success\": true, \"username\": \"$(_api_json_escape "$target_username")\", \"message\": \"User access revoked and all sessions invalidated\"}"
}

# DELETE /auth/invite/:code — Delete an invite code (admin only)
handle_auth_delete_invite() {
    local code="$1"

    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    if [[ -z "$code" ]]; then
        _api_error 400 "Missing invite code"
        return
    fi

    if _api_delete_invite "$code"; then
        _api_success "{\"success\": true, \"code\": \"$(_api_json_escape "$code")\", \"message\": \"Invite code deleted\"}"
    else
        _api_error 404 "Invite code not found: $code"
    fi
}

# GET /auth/invites — List active invite codes (admin only)
handle_auth_invites() {
    _api_init_auth_dir

    if ! _api_check_admin; then
        _api_error 403 "Admin access required"
        return
    fi

    local invites
    invites=$(_api_read_auth_file "invites.json")
    local now
    now=$(_api_now_epoch)

    if command -v jq >/dev/null 2>&1; then
        # Return all invites with proper ISO dates and used field handling
        local formatted_invites
        formatted_invites=$(echo "$invites" | jq --argjson n "$now" '
            [.[] | . + {
                "used": (if .used then .used else false end),
                "used_by": (if .used_by then .used_by else "" end),
                "expires_at": (if (.expires_at | type) == "number" then (.expires_at | todate) else .expires_at end),
                "expired": (if (.expires_at | type) == "number" then (.expires_at < $n) else false end)
            }]
        ' 2>/dev/null)
        local count
        count=$(echo "$formatted_invites" | jq 'length' 2>/dev/null)
        _api_success "{\"total\": ${count:-0}, \"invites\": ${formatted_invites:-[]}}"
    else
        _api_success "{\"total\": 0, \"invites\": ${invites:-[]}}"
    fi
}

# =============================================================================
# CONTAINER ACTION HANDLERS
# =============================================================================

handle_container_action() {
    local name="$1"
    local action="$2"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local output=""
    local success=true

    case "$action" in
        start)   output=$(docker start "$name" 2>&1) || success=false ;;
        stop)    output=$(docker stop "$name" 2>&1) || success=false ;;
        restart) output=$(docker restart "$name" 2>&1) || success=false ;;
        *)       _api_error 400 "Unknown action: $action"; return ;;
    esac

    local escaped_output
    escaped_output=$(_api_json_escape "$output")

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"action\": \"$action\", \"success\": $success, \"output\": \"$escaped_output\"}"
}

handle_container_logs() {
    local name="$1"

    if ! docker inspect "$name" >/dev/null 2>&1; then
        _api_error 404 "Container not found: $name"
        return
    fi

    local logs_raw
    logs_raw=$(docker logs --tail 100 "$name" 2>&1)
    local escaped
    escaped=$(_api_json_escape "$logs_raw")

    _api_success "{\"container\": \"$(_api_json_escape "$name")\", \"lines\": 100, \"logs\": \"$escaped\"}"
}

# =============================================================================
# MAINTENANCE HANDLERS
# =============================================================================

handle_maintenance_prune() {
    local output=""
    local success=true

    output=$(docker system prune -f 2>&1) || success=false
    local escaped
    escaped=$(_api_json_escape "$output")

    _api_success "{\"action\": \"prune\", \"success\": $success, \"output\": \"$escaped\"}"
}

handle_maintenance_image_prune() {
    local output=""
    local success=true

    if [[ "${AGGRESSIVE_IMAGE_PRUNE:-false}" == "true" ]]; then
        output=$(docker image prune -a -f 2>&1) || success=false
    else
        output=$(docker image prune -f 2>&1) || success=false
    fi
    local escaped
    escaped=$(_api_json_escape "$output")

    _api_success "{\"action\": \"image_prune\", \"success\": $success, \"output\": \"$escaped\"}"
}

# =============================================================================
# ADVANCED MAINTENANCE HANDLERS (Phase 2)
# =============================================================================

handle_maintenance_report() {
    local running stopped total_containers total_images dangling_images
    local total_volumes dangling_volumes total_networks custom_networks

    running=$(docker ps -q 2>/dev/null | wc -l | tr -d ' ')
    total_containers=$(docker ps -aq 2>/dev/null | wc -l | tr -d ' ')
    stopped=$(( total_containers - running ))
    total_images=$(docker images -q 2>/dev/null | wc -l | tr -d ' ')
    dangling_images=$(docker images -f 'dangling=true' -q 2>/dev/null | wc -l | tr -d ' ')
    total_volumes=$(docker volume ls -q 2>/dev/null | wc -l | tr -d ' ')
    dangling_volumes=$(docker volume ls -f 'dangling=true' -q 2>/dev/null | wc -l | tr -d ' ')
    total_networks=$(docker network ls -q 2>/dev/null | wc -l | tr -d ' ')
    custom_networks=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -cvE '^(bridge|host|none)$' || echo 0)

    local docker_df
    docker_df=$(_api_json_escape "$(docker system df 2>/dev/null)")

    local app_data_size="N/A"
    if [[ -d "$APP_DATA_DIR" ]]; then
        app_data_size=$(du -sh "$APP_DATA_DIR" 2>/dev/null | cut -f1)
    fi

    local log_size="N/A"
    local log_dir="${BASE_DIR}/logs"
    if [[ -d "$log_dir" ]]; then
        log_size=$(du -sh "$log_dir" 2>/dev/null | cut -f1)
    fi

    _api_success "{\"containers\": {\"total\": $total_containers, \"running\": $running, \"stopped\": $stopped}, \"images\": {\"total\": $total_images, \"dangling\": $dangling_images}, \"volumes\": {\"total\": $total_volumes, \"dangling\": $dangling_volumes}, \"networks\": {\"total\": $total_networks, \"custom\": $custom_networks}, \"docker_df\": \"$docker_df\", \"app_data_size\": \"$(_api_json_escape "$app_data_size")\", \"log_size\": \"$(_api_json_escape "$log_size")\"}"
}

handle_maintenance_orphans() {
    local -a orphan_containers=()
    while IFS='|' read -r name image status; do
        [[ -z "$name" ]] && continue
        orphan_containers+=("{\"name\": \"$(_api_json_escape "$name")\", \"image\": \"$(_api_json_escape "$image")\", \"status\": \"$(_api_json_escape "$status")\"}")
    done < <(docker ps -a --filter 'status=exited' --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null)

    local oc_json
    if [[ ${#orphan_containers[@]} -gt 0 ]]; then
        oc_json=$(printf '%s,' "${orphan_containers[@]}")
        oc_json="[${oc_json%,}]"
    else
        oc_json="[]"
    fi

    local -a dangling_imgs=()
    while IFS='|' read -r id size created; do
        [[ -z "$id" ]] && continue
        dangling_imgs+=("{\"id\": \"$(_api_json_escape "$id")\", \"size\": \"$(_api_json_escape "$size")\", \"created\": \"$(_api_json_escape "$created")\"}")
    done < <(docker images -f 'dangling=true' --format '{{.ID}}|{{.Size}}|{{.CreatedAt}}' 2>/dev/null)

    local di_json
    if [[ ${#dangling_imgs[@]} -gt 0 ]]; then
        di_json=$(printf '%s,' "${dangling_imgs[@]}")
        di_json="[${di_json%,}]"
    else
        di_json="[]"
    fi

    local -a dangling_vols=()
    while IFS='|' read -r name driver; do
        [[ -z "$name" ]] && continue
        dangling_vols+=("{\"name\": \"$(_api_json_escape "$name")\", \"driver\": \"$(_api_json_escape "$driver")\"}")
    done < <(docker volume ls -f 'dangling=true' --format '{{.Name}}|{{.Driver}}' 2>/dev/null)

    local dv_json
    if [[ ${#dangling_vols[@]} -gt 0 ]]; then
        dv_json=$(printf '%s,' "${dangling_vols[@]}")
        dv_json="[${dv_json%,}]"
    else
        dv_json="[]"
    fi

    _api_success "{\"containers\": $oc_json, \"images\": $di_json, \"volumes\": $dv_json}"
}

handle_maintenance_disk() {
    local -a stack_sizes=()
    if [[ -d "$APP_DATA_DIR" ]]; then
        while IFS=$'\t' read -r size dir; do
            [[ -z "$size" ]] && continue
            local dirname
            dirname=$(basename "$dir")
            stack_sizes+=("{\"name\": \"$(_api_json_escape "$dirname")\", \"size\": \"$(_api_json_escape "$size")\"}")
        done < <(du -sh "$APP_DATA_DIR"/*/ 2>/dev/null | sort -rh)
    fi

    local ss_json
    if [[ ${#stack_sizes[@]} -gt 0 ]]; then
        ss_json=$(printf '%s,' "${stack_sizes[@]}")
        ss_json="[${ss_json%,}]"
    else
        ss_json="[]"
    fi

    local -a df_entries=()
    while IFS='|' read -r type total active size reclaimable; do
        [[ -z "$type" || "$type" == "TYPE" ]] && continue
        df_entries+=("{\"type\": \"$(_api_json_escape "$type")\", \"total\": \"$(_api_json_escape "$total")\", \"active\": \"$(_api_json_escape "$active")\", \"size\": \"$(_api_json_escape "$size")\", \"reclaimable\": \"$(_api_json_escape "$reclaimable")\"}")
    done < <(docker system df --format '{{.Type}}|{{.TotalCount}}|{{.Active}}|{{.Size}}|{{.Reclaimable}}' 2>/dev/null)

    local df_json
    if [[ ${#df_entries[@]} -gt 0 ]]; then
        df_json=$(printf '%s,' "${df_entries[@]}")
        df_json="[${df_json%,}]"
    else
        df_json="[]"
    fi

    local total_app_data="N/A"
    if [[ -d "$APP_DATA_DIR" ]]; then
        total_app_data=$(du -sh "$APP_DATA_DIR" 2>/dev/null | cut -f1)
    fi

    _api_success "{\"stack_sizes\": $ss_json, \"docker_df\": $df_json, \"total_app_data\": \"$(_api_json_escape "$total_app_data")\"}"
}

handle_maintenance_deep_prune() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for deep prune"
        return
    fi

    local confirm
    confirm=$(printf '%s' "$body" | jq -r '.confirm // empty' 2>/dev/null)
    if [[ "$confirm" != "CONFIRM" ]]; then
        _api_error 400 "Deep prune requires {\"confirm\": \"CONFIRM\"} in request body"
        return
    fi

    local output
    local success=true
    output=$(docker system prune -af --volumes 2>&1) || success=false
    local escaped
    escaped=$(_api_json_escape "$output")

    _api_success "{\"action\": \"deep_prune\", \"success\": $success, \"output\": \"$escaped\"}"
}

handle_maintenance_log_rotate() {
    local log_file="${BASE_DIR}/logs/docker-services.log"
    local archive_dir="${BASE_DIR}/logs/archive"
    local retention_count="${LOG_BACKUP_COUNT:-12}"

    if [[ ! -f "$log_file" ]]; then
        _api_success "{\"success\": true, \"message\": \"No active log file to rotate\"}"
        return
    fi

    local log_size
    log_size=$(du -sh "$log_file" 2>/dev/null | cut -f1)
    local log_lines
    log_lines=$(wc -l < "$log_file" 2>/dev/null | tr -d ' ')

    mkdir -p "$archive_dir" 2>/dev/null

    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local archive_name="docker-services-${timestamp}.log"

    cp "$log_file" "$archive_dir/$archive_name" 2>/dev/null
    if command -v gzip >/dev/null 2>&1; then
        gzip "$archive_dir/$archive_name" 2>/dev/null
        archive_name="${archive_name}.gz"
    fi

    : > "$log_file"

    local archive_count
    archive_count=$(ls -1 "$archive_dir"/docker-services-*.log* 2>/dev/null | wc -l | tr -d ' ')
    local purged=0
    if [[ "$archive_count" -gt "$retention_count" ]]; then
        purged=$(( archive_count - retention_count ))
        ls -1t "$archive_dir"/docker-services-*.log* 2>/dev/null | tail -n "$purged" | while read -r old_file; do
            rm -f "$old_file"
        done
    fi

    _api_success "{\"success\": true, \"message\": \"Log rotated successfully\", \"archived_as\": \"$(_api_json_escape "$archive_name")\", \"previous_size\": \"$(_api_json_escape "$log_size")\", \"previous_lines\": $log_lines, \"purged_archives\": $purged}"
}

# =============================================================================
# BATCH OPERATION HANDLERS (Phase 4)
# =============================================================================

handle_batch_stacks() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for batch operations"
        return
    fi

    local action
    action=$(printf '%s' "$body" | jq -r '.action // empty' 2>/dev/null)
    if [[ -z "$action" || ! "$action" =~ ^(start|stop|restart)$ ]]; then
        _api_error 400 "Invalid or missing 'action'. Must be start, stop, or restart."
        return
    fi

    local stacks_input
    stacks_input=$(printf '%s' "$body" | jq -r '.stacks' 2>/dev/null)

    local -a ordered_stacks=(
        "core-infrastructure"
        "networking-security"
        "monitoring-management"
        "development-tools"
        "media-services"
        "web-applications"
        "storage-backup"
        "communication-collaboration"
        "entertainment-personal"
        "miscellaneous-services"
    )

    local -a target_stacks=()
    if [[ "$stacks_input" == '"all"' || "$stacks_input" == 'all' ]]; then
        for s in "${ordered_stacks[@]}"; do
            [[ -d "$COMPOSE_DIR/$s" && -f "$COMPOSE_DIR/$s/docker-compose.yml" ]] && target_stacks+=("$s")
        done
    else
        while IFS= read -r s; do
            [[ -n "$s" ]] && target_stacks+=("$s")
        done < <(printf '%s' "$body" | jq -r '.stacks[]' 2>/dev/null)
    fi

    # Reverse order for stop
    if [[ "$action" == "stop" ]]; then
        local -a reversed=()
        for (( i=${#target_stacks[@]}-1; i>=0; i-- )); do
            reversed+=("${target_stacks[$i]}")
        done
        target_stacks=("${reversed[@]}")
    fi

    local -a results=()
    for stack in "${target_stacks[@]}"; do
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        if [[ ! -f "$compose_file" ]]; then
            results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": false, \"message\": \"Stack not found\"}")
            continue
        fi

        local compose_args=(-f "$compose_file")
        [[ -f "$COMPOSE_DIR/$stack/.env" ]] && compose_args+=(--env-file "$COMPOSE_DIR/$stack/.env")

        local output success=true
        case "$action" in
            start)   output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d 2>&1) || success=false ;;
            stop)    output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" down 2>&1) || success=false ;;
            restart) output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" restart 2>&1) || success=false ;;
        esac

        results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": $success, \"message\": \"$(_api_json_escape "$output")\"}")
    done

    local results_json
    if [[ ${#results[@]} -gt 0 ]]; then
        results_json=$(printf '%s,' "${results[@]}")
        results_json="[${results_json%,}]"
    else
        results_json="[]"
    fi

    _api_success "{\"action\": \"$action\", \"total\": ${#target_stacks[@]}, \"results\": $results_json}"
}

handle_batch_update() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for batch operations"
        return
    fi

    local stacks_input
    stacks_input=$(printf '%s' "$body" | jq -r '.stacks' 2>/dev/null)

    local -a target_stacks=()
    if [[ "$stacks_input" == '"all"' || "$stacks_input" == 'all' ]]; then
        while IFS= read -r dir; do
            [[ -f "$dir/docker-compose.yml" ]] && target_stacks+=("$(basename "$dir")")
        done < <(find "$COMPOSE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    else
        while IFS= read -r s; do
            [[ -n "$s" ]] && target_stacks+=("$s")
        done < <(printf '%s' "$body" | jq -r '.stacks[]' 2>/dev/null)
    fi

    local -a results=()
    for stack in "${target_stacks[@]}"; do
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        if [[ ! -f "$compose_file" ]]; then
            results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": false, \"changes_detected\": false, \"message\": \"Stack not found\"}")
            continue
        fi

        local compose_args=(-f "$compose_file")
        [[ -f "$COMPOSE_DIR/$stack/.env" ]] && compose_args+=(--env-file "$COMPOSE_DIR/$stack/.env")

        local before_shas
        before_shas=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" images -q 2>/dev/null | sort)

        local pull_output
        pull_output=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" pull 2>&1)

        local after_shas
        after_shas=$($DOCKER_COMPOSE_CMD "${compose_args[@]}" images -q 2>/dev/null | sort)

        local changes_detected=false
        if [[ "$before_shas" != "$after_shas" ]]; then
            changes_detected=true
            $DOCKER_COMPOSE_CMD "${compose_args[@]}" up -d 2>&1 || true
        fi

        results+=("{\"stack\": \"$(_api_json_escape "$stack")\", \"success\": true, \"changes_detected\": $changes_detected, \"message\": \"$(_api_json_escape "$pull_output")\"}")
    done

    local results_json
    if [[ ${#results[@]} -gt 0 ]]; then
        results_json=$(printf '%s,' "${results[@]}")
        results_json="[${results_json%,}]"
    else
        results_json="[]"
    fi

    _api_success "{\"action\": \"update\", \"total\": ${#target_stacks[@]}, \"results\": $results_json}"
}

# =============================================================================
# ROOT ENVIRONMENT HANDLERS (Phase 5)
# =============================================================================

handle_root_env() {
    local env_file="$BASE_DIR/.env"

    if [[ ! -f "$env_file" ]]; then
        _api_success "{\"raw\": \"\", \"variables\": []}"
        return
    fi

    local raw
    raw=$(cat "$env_file" 2>/dev/null)
    local escaped_raw
    escaped_raw=$(_api_json_escape "$raw")

    local -a vars=()
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ ))
        if [[ -z "$line" ]]; then continue; fi
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            vars+=("{\"key\": \"\", \"value\": \"\", \"line\": $line_num, \"comment\": \"$(_api_json_escape "$line")\"}")
            continue
        fi
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            value="${value#\"}" ; value="${value%\"}"
            value="${value#\'}" ; value="${value%\'}"
            vars+=("{\"key\": \"$(_api_json_escape "$key")\", \"value\": \"$(_api_json_escape "$value")\", \"line\": $line_num, \"comment\": \"\"}")
        fi
    done < "$env_file"

    local vars_json
    if [[ ${#vars[@]} -gt 0 ]]; then
        vars_json=$(printf '%s,' "${vars[@]}")
        vars_json="[${vars_json%,}]"
    else
        vars_json="[]"
    fi

    _api_success "{\"raw\": \"$escaped_raw\", \"variables\": $vars_json}"
}

handle_root_env_update() {
    local body="$1"
    local env_file="$BASE_DIR/.env"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for env update"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    if [[ -f "$env_file" ]]; then
        cp "$env_file" "${env_file}.bak" 2>/dev/null
    fi

    printf '%s' "$content" > "$env_file" 2>/dev/null || {
        _api_error 500 "Failed to write .env file"
        return
    }

    _api_success "{\"success\": true, \"message\": \"Root .env file saved successfully\"}"
}

handle_env_validate() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for env validation"
        return
    fi

    local content
    content=$(printf '%s' "$body" | jq -r '.content // empty' 2>/dev/null)
    if [[ -z "$content" ]]; then
        _api_error 400 "Missing 'content' field in request body"
        return
    fi

    local -a errors=()
    local -a warnings=()
    local -a seen_keys=()
    local line_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ ))
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            errors+=("{\"line\": $line_num, \"message\": \"$(_api_json_escape "Invalid syntax: $line")\"}")
            continue
        fi
        local key="${line%%=*}"
        for seen in "${seen_keys[@]}"; do
            if [[ "$seen" == "$key" ]]; then
                warnings+=("{\"line\": $line_num, \"message\": \"$(_api_json_escape "Duplicate key: $key")\"}")
                break
            fi
        done
        seen_keys+=("$key")
    done <<< "$content"

    local valid=true
    [[ ${#errors[@]} -gt 0 ]] && valid=false

    local errors_json warnings_json
    if [[ ${#errors[@]} -gt 0 ]]; then
        errors_json=$(printf '%s,' "${errors[@]}")
        errors_json="[${errors_json%,}]"
    else
        errors_json="[]"
    fi
    if [[ ${#warnings[@]} -gt 0 ]]; then
        warnings_json=$(printf '%s,' "${warnings[@]}")
        warnings_json="[${warnings_json%,}]"
    else
        warnings_json="[]"
    fi

    _api_success "{\"valid\": $valid, \"errors\": $errors_json, \"warnings\": $warnings_json}"
}

# =============================================================================
# BACKUP & RESTORE HANDLERS (Phase 6)
# =============================================================================

handle_backup_list() {
    local backup_dir="${BACKUP_DEST_DIR:-}"

    if [[ -z "$backup_dir" || ! -d "$backup_dir" ]]; then
        _api_success "{\"backups\": [], \"total\": 0}"
        return
    fi

    local -a entries=()
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local filename size date_epoch
        filename=$(basename "$file")
        size=$(du -h "$file" 2>/dev/null | cut -f1)
        date_epoch=$(stat -c '%Y' "$file" 2>/dev/null || stat -f '%m' "$file" 2>/dev/null || echo "0")
        entries+=("{\"filename\": \"$(_api_json_escape "$filename")\", \"size\": \"$(_api_json_escape "$size")\", \"timestamp\": $date_epoch}")
    done < <(ls -1t "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null)

    local entries_json
    if [[ ${#entries[@]} -gt 0 ]]; then
        entries_json=$(printf '%s,' "${entries[@]}")
        entries_json="[${entries_json%,}]"
    else
        entries_json="[]"
    fi

    _api_success "{\"backups\": $entries_json, \"total\": ${#entries[@]}}"
}

handle_backup_status() {
    local status_file="$API_AUTH_DIR/backup-status.json"

    if [[ -f "$status_file" ]]; then
        local status_content
        status_content=$(cat "$status_file" 2>/dev/null)
        _api_success "$status_content"
    else
        _api_success "{\"status\": \"idle\", \"last_backup\": null, \"progress\": null}"
    fi
}

handle_backup_config() {
    local backup_dest="${BACKUP_DEST_DIR:-}"
    local backup_source="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
    local retention="${BACKUP_RETENTION_COUNT:-5}"
    local configured=false
    [[ -n "$backup_dest" ]] && configured=true

    _api_success "{\"configured\": $configured, \"destination\": \"$(_api_json_escape "$backup_dest")\", \"source\": \"$(_api_json_escape "$backup_source")\", \"retention_count\": $retention}"
}

handle_backup_trigger() {
    local body="$1"
    local backup_dir="${BACKUP_DEST_DIR:-}"

    if [[ -z "$backup_dir" ]]; then
        _api_error 400 "Backup not configured. Set BACKUP_DEST_DIR in .env"
        return
    fi

    mkdir -p "$backup_dir" 2>/dev/null

    local stack_filter=""
    if command -v jq >/dev/null 2>&1 && [[ -n "$body" ]]; then
        stack_filter=$(printf '%s' "$body" | jq -r '.stack // empty' 2>/dev/null)
    fi

    local status_file="$API_AUTH_DIR/backup-status.json"
    local backup_date
    backup_date=$(date '+%Y-%m-%d_%H%M%S')
    local backup_file="Docker-Compose-Backup-${backup_date}.tar.gz"
    local source_dir="${BACKUP_SOURCE_DIR:-$BASE_DIR}"

    printf '{"status": "running", "started_at": "%s", "filename": "%s", "progress": "Starting backup..."}' \
        "$(date -Iseconds)" "$backup_file" > "$status_file"

    (
        local tmpdir
        tmpdir=$(mktemp -d /tmp/dcs-backup-XXXXXX)

        printf '{"status": "running", "started_at": "%s", "filename": "%s", "progress": "Copying files..."}' \
            "$(date -Iseconds)" "$backup_file" > "$status_file"

        if [[ -n "$stack_filter" ]]; then
            [[ -d "$COMPOSE_DIR/$stack_filter" ]] && rsync -a "$COMPOSE_DIR/$stack_filter/" "$tmpdir/$stack_filter/" 2>/dev/null || true
            [[ -d "$APP_DATA_DIR/$stack_filter" ]] && rsync -a "$APP_DATA_DIR/$stack_filter/" "$tmpdir/App-Data/$stack_filter/" 2>/dev/null || true
        else
            rsync -a --exclude='.git' --exclude='node_modules' "$source_dir/" "$tmpdir/" 2>/dev/null || true
        fi

        printf '{"status": "running", "started_at": "%s", "filename": "%s", "progress": "Creating archive..."}' \
            "$(date -Iseconds)" "$backup_file" > "$status_file"

        if tar -czf "$backup_dir/$backup_file" -C "$tmpdir" . 2>/dev/null; then
            local final_size
            final_size=$(du -h "$backup_dir/$backup_file" 2>/dev/null | cut -f1)
            printf '{"status": "idle", "last_backup": {"filename": "%s", "size": "%s", "timestamp": "%s"}, "progress": null}' \
                "$backup_file" "$final_size" "$(date -Iseconds)" > "$status_file"
        else
            printf '{"status": "error", "error": "Archive creation failed", "progress": null}' > "$status_file"
        fi

        rm -rf "$tmpdir"

        local retention="${BACKUP_RETENTION_COUNT:-5}"
        local count
        count=$(ls -1 "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null | wc -l)
        if [[ "$count" -gt "$retention" ]]; then
            ls -1t "$backup_dir"/Docker-Compose-Backup-*.tar.gz 2>/dev/null | tail -n "$(( count - retention ))" | xargs -r rm -f
        fi
    ) &

    _api_success "{\"success\": true, \"message\": \"Backup started in background\", \"filename\": \"$(_api_json_escape "$backup_file")\"}"
}

handle_backup_restore() {
    local body="$1"
    local backup_dir="${BACKUP_DEST_DIR:-}"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for restore"
        return
    fi

    local filename confirm
    filename=$(printf '%s' "$body" | jq -r '.filename // empty' 2>/dev/null)
    confirm=$(printf '%s' "$body" | jq -r '.confirm // empty' 2>/dev/null)

    if [[ -z "$filename" ]]; then
        _api_error 400 "Missing 'filename' in request body"
        return
    fi

    if [[ "$confirm" != "RESTORE" ]]; then
        _api_error 400 "Restore requires {\"confirm\": \"RESTORE\"} in request body"
        return
    fi

    local archive_path="$backup_dir/$filename"
    if [[ ! -f "$archive_path" ]]; then
        _api_error 404 "Backup file not found: $filename"
        return
    fi

    if ! tar -tzf "$archive_path" >/dev/null 2>&1; then
        _api_error 400 "Backup archive is corrupt or invalid"
        return
    fi

    local status_file="$API_AUTH_DIR/backup-status.json"
    printf '{"status": "restoring", "filename": "%s", "progress": "Restoring from backup..."}' "$filename" > "$status_file"

    (
        local target="${BACKUP_SOURCE_DIR:-$BASE_DIR}"
        if tar -xzf "$archive_path" -C "$target" 2>/dev/null; then
            printf '{"status": "idle", "last_restore": {"filename": "%s", "timestamp": "%s"}, "progress": null}' \
                "$filename" "$(date -Iseconds)" > "$status_file"
        else
            printf '{"status": "error", "error": "Restore failed", "progress": null}' > "$status_file"
        fi
    ) &

    _api_success "{\"success\": true, \"message\": \"Restore started in background\", \"filename\": \"$(_api_json_escape "$filename")\"}"
}

# =============================================================================
# STACK CREATE / DELETE HANDLERS
# =============================================================================

handle_create_stack() {
    local body="$1"

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for stack creation"
        return
    fi

    local name
    name=$(echo "$body" | jq -r '.name // empty' 2>/dev/null)

    if [[ -z "$name" ]]; then
        _api_error 400 "Missing required field: name"
        return
    fi

    # Validate name: lowercase letters, numbers, hyphens only
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]] && [[ ! "$name" =~ ^[a-z0-9]$ ]]; then
        _api_error 400 "Invalid stack name. Use lowercase letters, numbers, and hyphens only."
        return
    fi

    local stack_dir="$COMPOSE_DIR/$name"

    if [[ -d "$stack_dir" ]]; then
        _api_error 409 "Stack already exists: $name"
        return
    fi

    # Create directory
    mkdir -p "$stack_dir" 2>/dev/null
    if [[ ! -d "$stack_dir" ]]; then
        _api_error 500 "Failed to create stack directory"
        return
    fi

    # Create base docker-compose.yml
    cat > "$stack_dir/docker-compose.yml" <<'COMPOSE_EOF'
services:
  # Add your services here
  # Example:
  # my-service:
  #   container_name: my-service
  #   image: alpine:latest
  #   restart: unless-stopped
  #   environment:
  #     - TZ=${TZ:-UTC}
  #   volumes:
  #     - ${APP_DATA_DIR:-./App-Data}/my-service:/data
COMPOSE_EOF

    # Create base .env
    cat > "$stack_dir/.env" <<ENV_EOF
# =============================================================================
# Stack: $name
# =============================================================================
# Stack-specific environment variables.
# Variables are inherited from the root .env file.
# Add any stack-specific overrides below.
# =============================================================================

# APP_DATA_DIR is inherited from root .env
# TZ is inherited from root .env
# PUID and PGID are inherited from root .env
ENV_EOF

    # Create App-Data directory
    mkdir -p "$stack_dir/App-Data" 2>/dev/null

    _api_success "{\"success\": true, \"name\": \"$name\", \"message\": \"Stack '$name' created successfully\"}"
}

handle_delete_stack() {
    local name="$1"

    if [[ -z "$name" ]]; then
        _api_error 400 "Missing stack name"
        return
    fi

    local stack_dir="$COMPOSE_DIR/$name"

    if [[ ! -d "$stack_dir" ]]; then
        _api_error 404 "Stack not found: $name"
        return
    fi

    # Safety: check if stack has running containers
    local running_count=0
    if [[ -f "$stack_dir/docker-compose.yml" ]]; then
        running_count=$($DOCKER_COMPOSE_CMD -f "$stack_dir/docker-compose.yml" ps -q 2>/dev/null | wc -l || true)
    fi

    if [[ "$running_count" -gt 0 ]] 2>/dev/null; then
        _api_error 409 "Cannot delete stack with running containers. Stop the stack first."
        return
    fi

    # Remove the stack directory
    rm -rf "$stack_dir" 2>/dev/null

    if [[ -d "$stack_dir" ]]; then
        _api_error 500 "Failed to delete stack directory"
        return
    fi

    _api_success "{\"success\": true, \"name\": \"$name\", \"message\": \"Stack '$name' deleted successfully\"}"
}

# =============================================================================
# CONFIG UPDATE HANDLER
# =============================================================================

handle_config_update() {
    local body="$1"
    local env_file="$BASE_DIR/.env"

    if [[ ! -f "$env_file" ]]; then
        _api_error 500 "Configuration file not found: $env_file"
        return
    fi

    if ! command -v jq >/dev/null 2>&1; then
        _api_error 500 "jq is required for config updates"
        return
    fi

    # Parse the JSON body and update .env file
    # Expected format: { "key": "value", "key2": "value2" }
    local -A updates=()
    local keys
    keys=$(echo "$body" | jq -r 'keys[]' 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$keys" ]]; then
        _api_error 400 "Invalid JSON body"
        return
    fi

    # Allowed config keys that can be updated (safety whitelist)
    local -A allowed_keys=(
        [ENVIRONMENT]=1 [LOG_LEVEL]=1 [SKIP_HEALTHCHECK_WAIT]=1
        [CONTINUE_ON_FAILURE]=1 [REMOVE_VOLUMES_ON_STOP]=1
        [AGGRESSIVE_IMAGE_PRUNE]=1 [UPDATE_NOTIFICATION]=1
        [SHOW_BANNERS]=1 [API_PORT]=1 [API_BIND]=1 [API_ENABLED]=1
        [SERVER_NAME]=1 [TZ]=1 [NTFY_URL]=1 [NTFY_TOPIC]=1
        [NTFY_PRIORITY]=1 [ENABLE_COLORS]=1 [COLOR_MODE]=1
    )

    local changed=0
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if [[ -z "${allowed_keys[$key]:-}" ]]; then
            _api_error 400 "Key not allowed: $key"
            return
        fi
        local value
        value=$(echo "$body" | jq -r ".[\"$key\"]" 2>/dev/null)
        updates["$key"]="$value"
    done <<< "$keys"

    # Backup current .env
    cp "$env_file" "${env_file}.bak" 2>/dev/null

    # Apply updates to .env file
    for key in "${!updates[@]}"; do
        local value="${updates[$key]}"
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            # Update existing key
            sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
        else
            # Append new key
            echo "${key}=${value}" >> "$env_file"
        fi
        changed=$(( changed + 1 ))
    done

    # Re-source .env to pick up changes
    set -a
    source "$env_file"
    set +a

    _api_success "{\"success\": true, \"updated\": $changed, \"message\": \"Configuration updated. Some changes may require a restart.\"}"
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

    # Consume remaining headers and capture Content-Length and Authorization
    local header="" content_length=0
    REQUEST_AUTH_HEADER=""
    while IFS= read -r header; do
        header="${header%%$'\r'}"
        [[ -z "$header" ]] && break
        # Capture content-length (case-insensitive)
        if [[ "${header,,}" == content-length:* ]]; then
            content_length="${header#*: }"
            content_length="${content_length// /}"
        fi
        # Capture authorization header (case-insensitive)
        if [[ "${header,,}" == authorization:* ]]; then
            REQUEST_AUTH_HEADER="${header#*: }"
            REQUEST_AUTH_HEADER="${REQUEST_AUTH_HEADER// /}"
            # Re-extract preserving the space after "Bearer "
            REQUEST_AUTH_HEADER="${header#*: }"
        fi
    done

    # Read request body if present
    local request_body=""
    if [[ "$content_length" -gt 0 ]] 2>/dev/null; then
        request_body=$(dd bs=1 count="$content_length" 2>/dev/null)
    fi

    # Normalize path: strip trailing slash, lowercase
    path="${path%/}"
    [[ -z "$path" ]] && path="/"

    # Parse query string and strip from path for clean routing
    _api_parse_query "$path"
    path="${path%%\?*}"

    # Handle CORS preflight
    if [[ "$method" == "OPTIONS" ]]; then
        _api_response 200 ""
        return
    fi

    # Log the request
    local client_ip="${SOCAT_PEERADDR:-127.0.0.1}"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $method $path [${client_ip}]" >> "$API_LOG_FILE" 2>/dev/null

    # IP whitelist check — reject before any processing
    if ! _api_check_ip_whitelist; then
        _api_error 403 "Access denied: IP ${client_ip} is not in the allowed list."
        return
    fi

    # Global rate limit check — reject if too many requests from this IP
    if ! _api_check_global_rate_limit; then
        _api_error 429 "Rate limit exceeded. Maximum ${API_RATE_LIMIT} requests per ${API_RATE_WINDOW} seconds."
        return
    fi

    # ── Route: GET endpoints ──────────────────────────────────────────
    if [[ "$method" == "GET" ]]; then

        # Auth endpoints that do NOT require authentication
        case "$path" in
            /)              handle_root; return ;;
            /auth/verify)   handle_auth_verify; return ;;
        esac

        # All other GET endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        # Admin-only auth endpoints
        case "$path" in
            /auth/users)    handle_auth_users; return ;;
            /auth/invites)  handle_auth_invites; return ;;
        esac

        # Standard authenticated GET endpoints
        case "$path" in
            /status)                    handle_status ;;
            /health)                    handle_health ;;
            /stacks)                    handle_stacks ;;
            /images)                    handle_images false ;;
            /images/stale)              handle_images true ;;
            /containers)                handle_containers ;;
            /config)                    handle_config ;;
            /system)                    handle_system ;;
            /disks)                     handle_disks ;;
            /networks)                  handle_networks ;;
            /volumes)                   handle_volumes ;;
            /logs)                      handle_logs ;;
            /logs/stats)                handle_logs_stats ;;
            /logs/archives)             handle_logs_archives ;;
            /events)                    handle_events ;;
            /version)                   handle_version ;;
            /maintenance/report)        handle_maintenance_report ;;
            /maintenance/orphans)       handle_maintenance_orphans ;;
            /maintenance/disk)          handle_maintenance_disk ;;
            /env)                       handle_root_env ;;
            /backups)                   handle_backup_list ;;
            /backups/status)            handle_backup_status ;;
            /backups/config)            handle_backup_config ;;

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
            /stacks/*/compose)
                local stack="${path#/stacks/}"
                stack="${stack%/compose}"
                handle_stack_compose "$stack"
                ;;
            /stacks/*/env)
                local stack="${path#/stacks/}"
                stack="${stack%/env}"
                handle_stack_env "$stack"
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
            /containers/*/logs)
                local container="${path#/containers/}"
                container="${container%/logs}"
                handle_container_logs "$container"
                ;;
            /containers/*/processes)
                local container="${path#/containers/}"
                container="${container%/processes}"
                handle_container_processes "$container"
                ;;
            /networks/*)
                local network="${path#/networks/}"
                handle_network_detail "$network"
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

        # Auth endpoints that do NOT require authentication
        case "$path" in
            /auth/setup)    handle_auth_setup "$request_body"; return ;;
            /auth/login)    handle_auth_login "$request_body"; return ;;
            /auth/register) handle_auth_register "$request_body"; return ;;
        esac

        # All other POST endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        # Auth endpoints that require admin
        case "$path" in
            /auth/invite)   handle_auth_invite "$request_body"; return ;;
            /auth/revoke)   handle_auth_revoke "$request_body"; return ;;
        esac

        # Standard authenticated POST endpoints
        case "$path" in
            /stacks)
                handle_create_stack "$request_body"
                ;;
            /stacks/*/delete)
                local stack="${path#/stacks/}"
                stack="${stack%/delete}"
                handle_delete_stack "$stack"
                ;;
            /config)
                handle_config_update "$request_body"
                ;;
            /containers/*/start)
                local container="${path#/containers/}"
                container="${container%/start}"
                handle_container_action "$container" "start"
                ;;
            /containers/*/stop)
                local container="${path#/containers/}"
                container="${container%/stop}"
                handle_container_action "$container" "stop"
                ;;
            /containers/*/restart)
                local container="${path#/containers/}"
                container="${container%/restart}"
                handle_container_action "$container" "restart"
                ;;
            /networks)
                handle_create_network "$request_body"
                ;;
            /networks/*/delete)
                local network="${path#/networks/}"
                network="${network%/delete}"
                handle_delete_network "$network"
                ;;
            /networks/*/connect)
                local network="${path#/networks/}"
                network="${network%/connect}"
                handle_network_connect "$network" "$request_body"
                ;;
            /networks/*/disconnect)
                local network="${path#/networks/}"
                network="${network%/disconnect}"
                handle_network_disconnect "$network" "$request_body"
                ;;
            /volumes/*/delete)
                local volume="${path#/volumes/}"
                volume="${volume%/delete}"
                handle_delete_volume "$volume"
                ;;
            /maintenance/prune)
                handle_maintenance_prune
                ;;
            /maintenance/image-prune)
                handle_maintenance_image_prune
                ;;
            /maintenance/deep-prune)
                handle_maintenance_deep_prune "$request_body"
                ;;
            /maintenance/log-rotate)
                handle_maintenance_log_rotate
                ;;
            /batch/stacks)
                handle_batch_stacks "$request_body"
                ;;
            /batch/update)
                handle_batch_update "$request_body"
                ;;
            /env)
                handle_root_env_update "$request_body"
                ;;
            /env/validate)
                handle_env_validate "$request_body"
                ;;
            /backups/trigger)
                handle_backup_trigger "$request_body"
                ;;
            /backups/restore)
                handle_backup_restore "$request_body"
                ;;
            /stacks/*/compose/validate)
                local stack="${path#/stacks/}"
                stack="${stack%/compose/validate}"
                handle_stack_compose_validate "$stack" "$request_body"
                ;;
            /stacks/*/compose)
                local stack="${path#/stacks/}"
                stack="${stack%/compose}"
                handle_stack_compose_save "$stack" "$request_body"
                ;;
            /stacks/*/env)
                local stack="${path#/stacks/}"
                stack="${stack%/env}"
                handle_stack_env_save "$stack" "$request_body"
                ;;
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

    # ── Route: DELETE endpoints ────────────────────────────────────────
    if [[ "$method" == "DELETE" ]]; then

        # All DELETE endpoints require authentication
        if ! _api_check_auth; then
            _api_error 401 "Authentication required. Provide Authorization: Bearer <token> header."
            return
        fi

        case "$path" in
            /auth/invite/*)
                local code="${path#/auth/invite/}"
                handle_auth_delete_invite "$code"
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
    echo "  ${_A_BOLD}${_A_WHITE}Auth${_A_RST}       $([[ "$API_AUTH_ENABLED" == "true" ]] && echo "${_A_GREEN}Enabled${_A_RST}" || echo "${_A_GRAY}Disabled (localhost)${_A_RST}")"
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

    # Write PID file (use $BASHPID for the actual process PID, not $$ which is always the parent)
    echo "${BASHPID:-$$}" > "$API_PID_FILE"

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
        # Disable errexit for request handling — we handle errors via JSON responses
        set +e
        handle_request
        exit 0
    fi

    if [[ "$DAEMON_MODE" == "true" ]]; then
        start_server >> "$API_LOG_FILE" 2>&1 &
        bg_pid=$!
        disown
        # Overwrite PID file with the actual background PID
        echo "$bg_pid" > "$API_PID_FILE"
        echo "API server started in background (PID: $bg_pid)"
        echo "Log: $API_LOG_FILE"
        echo "Stop: $0 --stop"
    else
        start_server
    fi
fi
