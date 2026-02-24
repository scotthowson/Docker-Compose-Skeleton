#!/bin/bash
# =============================================================================
# Docker Compose Skeleton - First-Run Setup Script
# Configures permissions, creates directories, and validates the environment
# =============================================================================

set -euo pipefail

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
export BASE_DIR

# Load root .env if it exists (for APP_DATA_DIR and other overrides)
if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="$BASE_DIR/Stacks"
export COMPOSE_DIR

# Resolve APP_DATA_DIR (default to $BASE_DIR/App-Data)
APP_DATA_DIR="${APP_DATA_DIR:-$BASE_DIR/App-Data}"

# Detect current user (never hardcode)
CURRENT_USER="$(whoami)"
CURRENT_GROUP="$(id -gn)"

# =============================================================================
# SIMPLE COLOR OUTPUT (no dependency on the full logger)
# =============================================================================

_setup_colors() {
    if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        local colors
        colors="$(tput colors 2>/dev/null || echo 0)"
        if [[ "$colors" -ge 8 ]]; then
            C_GREEN="$(tput setaf 82 2>/dev/null || tput setaf 2)"
            C_YELLOW="$(tput setaf 208 2>/dev/null || tput setaf 3)"
            C_RED="$(tput setaf 124 2>/dev/null || tput setaf 1)"
            C_BLUE="$(tput setaf 33 2>/dev/null || tput setaf 4)"
            C_CYAN="$(tput setaf 51 2>/dev/null || tput setaf 6)"
            C_BOLD="$(tput bold 2>/dev/null || true)"
            C_DIM="$(tput dim 2>/dev/null || true)"
            C_RESET="$(tput sgr0 2>/dev/null || true)"
            return
        fi
    fi
    # No color support -- all codes are empty
    C_GREEN="" C_YELLOW="" C_RED="" C_BLUE="" C_CYAN="" C_BOLD="" C_DIM="" C_RESET=""
}

_setup_colors

# Print helpers
_ok()      { echo -e "  ${C_GREEN}[OK]${C_RESET}    $1"; }
_skip()    { echo -e "  ${C_YELLOW}[SKIP]${C_RESET}  $1"; }
_fail()    { echo -e "  ${C_RED}[FAIL]${C_RESET}  $1"; }
_info()    { echo -e "  ${C_BLUE}[INFO]${C_RESET}  $1"; }
_header()  { echo -e "\n${C_BOLD}${C_CYAN}$1${C_RESET}"; }
_divider() { echo -e "${C_DIM}$(printf '%.0s-' {1..60})${C_RESET}"; }

# =============================================================================
# HELP / USAGE
# =============================================================================

show_help() {
    cat <<EOF
${C_BOLD}Docker Compose Skeleton - Setup${C_RESET}

Usage: ./setup.sh [OPTIONS]

First-run setup script that configures the project directory.

OPTIONS:
  --help, -h      Show this help message and exit
  --dry-run       Show what would be done without making changes
  --verbose, -v   Show extra detail during setup

WHAT IT DOES:
  1. Copies .env.example -> .env (if .env does not exist)
  2. Creates App-Data/ and logs/ directories
  3. Creates stack directories from DOCKER_STACKS in .env
     (each gets a base docker-compose.yml and .env template)
  4. Sets executable permissions on all .sh scripts
  5. Sets ownership to the current user (${CURRENT_USER})
  6. Verifies Docker and Docker Compose are installed

EOF
    exit 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

DRY_RUN=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)   show_help ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --verbose|-v) VERBOSE=true; shift ;;
        *)
            echo "Unknown option: $1"
            echo "Run './setup.sh --help' for usage."
            exit 1
            ;;
    esac
done

# Wrapper that respects --dry-run
_run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        _info "DRY RUN: $*"
    else
        "$@"
    fi
}

# =============================================================================
# BANNER
# =============================================================================

echo ""
echo -e "${C_BOLD}${C_CYAN}+======================================================+${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}|         Docker Compose Skeleton  --  Setup            |${C_RESET}"
echo -e "${C_BOLD}${C_CYAN}+======================================================+${C_RESET}"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    _info "Running in DRY RUN mode -- no changes will be made"
    echo ""
fi

_info "Base directory  : $BASE_DIR"
_info "Stacks directory: $COMPOSE_DIR"
_info "App-Data target : $APP_DATA_DIR"
_info "Running as user : ${CURRENT_USER}:${CURRENT_GROUP}"

# =============================================================================
# STEP 1: Environment File
# =============================================================================

_header "Step 1/5: Environment Configuration"
_divider

if [[ -f "$BASE_DIR/.env" ]]; then
    _skip ".env already exists -- not overwriting"
elif [[ -f "$BASE_DIR/.env.example" ]]; then
    _run cp "$BASE_DIR/.env.example" "$BASE_DIR/.env"
    _ok "Copied .env.example -> .env"
    _info "Edit .env to customize for your server"
else
    _fail ".env.example not found -- cannot create .env"
    _info "Create .env manually based on the project documentation"
fi

# =============================================================================
# STEP 2: Create Directories
# =============================================================================

_header "Step 2/5: Directory Structure"
_divider

declare -a REQUIRED_DIRS=(
    "$APP_DATA_DIR"
    "$BASE_DIR/logs"
    "$BASE_DIR/logs/archive"
)

for dir in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        _skip "Directory exists: ${dir#"$BASE_DIR/"}"
    else
        _run mkdir -p "$dir"
        _ok "Created: ${dir#"$BASE_DIR/"}"
    fi
done

# =============================================================================
# STEP 3: Stack Directories
# =============================================================================

_header "Step 3/6: Stack Directories"
_divider

# Read stack list from .env (DOCKER_STACKS), or use defaults
if [[ -n "${DOCKER_STACKS:-}" ]]; then
    read -ra _SETUP_STACKS <<< "$DOCKER_STACKS"
    _info "Using DOCKER_STACKS from .env (${#_SETUP_STACKS[@]} stacks)"
else
    _SETUP_STACKS=(
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
    _info "Using default stack list (${#_SETUP_STACKS[@]} stacks)"
fi

stacks_created=0
stacks_existed=0

for stack_name in "${_SETUP_STACKS[@]}"; do
    stack_dir="$COMPOSE_DIR/$stack_name"
    if [[ -d "$stack_dir" ]]; then
        ((stacks_existed++))
        [[ "$VERBOSE" == "true" ]] && _skip "Stack exists: $stack_name"
    else
        _run mkdir -p "$stack_dir"

        # Create base docker-compose.yml
        if [[ "$DRY_RUN" != "true" ]]; then
            cat > "$stack_dir/docker-compose.yml" <<COMPOSE_EOF
# =============================================================================
# $stack_name — Docker Compose Stack
# Add your services below. See https://docs.docker.com/compose/ for reference.
# =============================================================================

services:
  # example:
  #   image: hello-world
  #   container_name: example
  #   restart: unless-stopped
  #   env_file:
  #     - .env
  #   # ports:
  #   #   - "8080:80"
  #   # volumes:
  #   #   - \${APP_DATA_DIR}/example:/data
COMPOSE_EOF
        fi

        # Create base .env
        if [[ "$DRY_RUN" != "true" ]]; then
            cat > "$stack_dir/.env" <<ENV_EOF
# =============================================================================
# $stack_name — Stack Environment Variables
# These override root .env values for services in this stack.
# =============================================================================

# Inherit from root .env:
# PUID, PGID, TZ, APP_DATA_DIR, PROXY_DOMAIN
ENV_EOF
        fi

        _ok "Created stack: $stack_name (with docker-compose.yml + .env)"
        ((stacks_created++))
    fi
done

if [[ "$stacks_created" -gt 0 ]]; then
    _ok "Created $stacks_created new stack director${stacks_created:+ies}"
fi
if [[ "$stacks_existed" -gt 0 ]]; then
    _info "$stacks_existed stack directories already existed"
fi

unset _SETUP_STACKS

# =============================================================================
# STEP 4: Set Executable Permissions
# =============================================================================

_header "Step 4/6: Script Permissions"
_divider

chmod_count=0

# Root-level scripts
for script in "$BASE_DIR"/*.sh; do
    [[ -f "$script" ]] || continue
    _run chmod +x "$script"
    ((chmod_count++))
    [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: $(basename "$script")"
done

# .lib/ scripts
if [[ -d "$BASE_DIR/.lib" ]]; then
    for script in "$BASE_DIR/.lib/"*.sh; do
        [[ -f "$script" ]] || continue
        _run chmod +x "$script"
        ((chmod_count++))
        [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: .lib/$(basename "$script")"
    done
fi

# .scripts/ scripts
if [[ -d "$BASE_DIR/.scripts" ]]; then
    for script in "$BASE_DIR/.scripts/"*.sh; do
        [[ -f "$script" ]] || continue
        _run chmod +x "$script"
        ((chmod_count++))
        [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: .scripts/$(basename "$script")"
    done
fi

# .config/ scripts
if [[ -d "$BASE_DIR/.config" ]]; then
    for script in "$BASE_DIR/.config/"*.sh; do
        [[ -f "$script" ]] || continue
        _run chmod +x "$script"
        ((chmod_count++))
        [[ "$VERBOSE" == "true" ]] && _ok "chmod +x: .config/$(basename "$script")"
    done
fi

_ok "Set executable on $chmod_count script files"

# =============================================================================
# STEP 4: Set Ownership
# =============================================================================

_header "Step 5/6: File Ownership"
_divider

# Only attempt chown if we can (avoids errors in unprivileged containers)
if [[ "$(id -u)" -eq 0 ]] || id -nG "$CURRENT_USER" 2>/dev/null | grep -qw "$(stat -c '%G' "$BASE_DIR" 2>/dev/null || echo "")"; then
    _run chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR/.lib" 2>/dev/null || true
    _run chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR/.scripts" 2>/dev/null || true
    _run chown -R "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR/.config" 2>/dev/null || true
    _run chown "${CURRENT_USER}:${CURRENT_GROUP}" "$BASE_DIR"/*.sh 2>/dev/null || true
    _ok "Ownership set to ${CURRENT_USER}:${CURRENT_GROUP}"
else
    _skip "Not adjusting ownership (current user already owns files)"
fi

# =============================================================================
# STEP 5: Verify Docker Environment
# =============================================================================

_header "Step 6/6: Docker Environment"
_divider

docker_ok=true

# Check Docker daemon
if command -v docker >/dev/null 2>&1; then
    _ok "Docker binary found: $(command -v docker)"
    if docker info >/dev/null 2>&1; then
        _ok "Docker daemon is running"
        docker_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
        _info "Docker version: $docker_version"
    else
        _fail "Docker daemon is not running or not accessible"
        _info "Start Docker with: sudo systemctl start docker"
        docker_ok=false
    fi
else
    _fail "Docker is not installed"
    _info "Install Docker: https://docs.docker.com/engine/install/"
    docker_ok=false
fi

# Check Docker Compose
compose_found=false
if docker compose version &>/dev/null; then
    compose_version="$(docker compose version --short 2>/dev/null || echo 'unknown')"
    _ok "Docker Compose plugin (v2): $compose_version"
    compose_found=true
fi
if command -v docker-compose &>/dev/null; then
    compose_version="$(docker-compose --version 2>/dev/null | head -1 || echo 'unknown')"
    _ok "docker-compose binary (v1): $compose_version"
    compose_found=true
fi
if [[ "$compose_found" == "false" ]]; then
    _fail "No Docker Compose installation found"
    _info "Install: https://docs.docker.com/compose/install/"
    docker_ok=false
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
_divider
_header "Setup Complete"
_divider
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    _info "This was a DRY RUN -- no changes were made"
    _info "Remove --dry-run to apply changes"
elif [[ "$docker_ok" == "true" ]]; then
    _ok "Everything is configured and ready"
    echo ""
    _info "Next steps:"
    _info "  1. Edit ${C_BOLD}.env${C_RESET} with your server settings"
    _info "  2. Configure your stacks in ${C_BOLD}Stacks/*/${C_RESET}"
    _info "  3. Run ${C_BOLD}./start.sh${C_RESET} to launch all services"
else
    _fail "Setup completed with warnings (Docker issues above)"
    _info "Resolve the Docker issues above, then run ./start.sh"
fi

echo ""
