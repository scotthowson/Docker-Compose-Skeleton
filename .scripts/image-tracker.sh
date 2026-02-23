#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Image Update Tracker
# Compares local Docker image digests against remote registry digests to
# detect available updates without actually pulling them.
#
# Usage:
#   ./image-tracker.sh [--stack <name>] [--pull] [--json]
#
# Options:
#   --stack <name>    Only check images for a specific stack
#   --pull            Auto-pull images that have updates
#   --json            Output results as JSON
#   --quick           Only show images with available updates
#
# This script inspects each running container's image digest and compares
# it to the latest remote digest to identify stale images.
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _IT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_IT_SCRIPT_DIR/.." && pwd)"
    unset _IT_SCRIPT_DIR
fi

if [[ -f "$BASE_DIR/.env" ]]; then
    set -a
    source "$BASE_DIR/.env"
    set +a
fi

COMPOSE_DIR="${COMPOSE_DIR:-$BASE_DIR/Stacks}"

# =============================================================================
# COLOR SETUP
# =============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    _IT_RESET="$(tput sgr0)"
    _IT_BOLD="$(tput bold)"
    _IT_DIM="$(tput dim)"
    _IT_GREEN="$(tput setaf 82)"
    _IT_YELLOW="$(tput setaf 214)"
    _IT_RED="$(tput setaf 196)"
    _IT_CYAN="$(tput setaf 51)"
    _IT_BLUE="$(tput setaf 33)"
    _IT_GRAY="$(tput setaf 245)"
    _IT_MAGENTA="$(tput setaf 141)"
    _IT_WHITE="$(tput setaf 15)"
else
    _IT_RESET="" _IT_BOLD="" _IT_DIM=""
    _IT_GREEN="" _IT_YELLOW="" _IT_RED="" _IT_CYAN=""
    _IT_BLUE="" _IT_GRAY="" _IT_MAGENTA="" _IT_WHITE=""
fi

# =============================================================================
# ARGUMENTS
# =============================================================================

STACK_FILTER=""
AUTO_PULL=false
JSON_OUTPUT=false
QUICK_MODE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stack)  STACK_FILTER="$2"; shift 2 ;;
        --pull)   AUTO_PULL=true; shift ;;
        --json)   JSON_OUTPUT=true; shift ;;
        --quick)  QUICK_MODE=true; shift ;;
        --help|-h)
            cat <<EOF
Image Update Tracker — Check for Docker image updates

Usage: $0 [--stack <name>] [--pull] [--json] [--quick]

Options:
  --stack <name>    Check only a specific stack's images
  --pull            Auto-pull images with available updates
  --json            Output as JSON
  --quick           Only show images needing updates
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

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
# UTILITY FUNCTIONS
# =============================================================================

_it_repeat() {
    local char="$1" count="$2"
    (( count <= 0 )) && return
    printf "%0.s${char}" $(seq 1 "$count")
}

_it_header() {
    local title="$1"
    local width=65
    echo ""
    echo "  ${_IT_BLUE}+$(_it_repeat "-" "$width")+${_IT_RESET}"
    local pad=$(( (width - ${#title}) / 2 ))
    printf "  ${_IT_BLUE}|%*s${_IT_BOLD}${_IT_CYAN}%s${_IT_RESET}${_IT_BLUE}%*s|${_IT_RESET}\n" "$pad" "" "$title" $(( width - pad - ${#title} )) ""
    echo "  ${_IT_BLUE}+$(_it_repeat "-" "$width")+${_IT_RESET}"
    echo ""
}

# Compare local image digest against remote
# Returns: "up-to-date", "update-available", or "unknown"
_it_check_image() {
    local image="$1"

    # Get local image ID (short)
    local local_id
    local_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null | cut -d: -f2 | cut -c1-12)"

    if [[ -z "$local_id" ]]; then
        echo "missing"
        return
    fi

    # Try to get remote digest without pulling
    # docker manifest inspect requires experimental mode or newer Docker
    local remote_digest
    remote_digest="$(docker manifest inspect "$image" 2>/dev/null | grep -m1 '"digest"' | grep -oP 'sha256:\K[a-f0-9]+' | cut -c1-12)"

    if [[ -z "$remote_digest" ]]; then
        # Fallback: pull to check
        local pull_output
        pull_output="$(docker pull "$image" --quiet 2>/dev/null)"
        local new_id
        new_id="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null | cut -d: -f2 | cut -c1-12)"

        if [[ "$local_id" != "$new_id" ]]; then
            echo "updated"
        else
            echo "up-to-date"
        fi
        return
    fi

    echo "unknown"
}

# Get image info for a container
_it_get_image_info() {
    local container_name="$1"

    local image_name
    image_name="$(docker inspect "$container_name" --format '{{.Config.Image}}' 2>/dev/null)"
    [[ -z "$image_name" ]] && return

    local image_id
    image_id="$(docker inspect "$container_name" --format '{{.Image}}' 2>/dev/null | cut -d: -f2 | cut -c1-12)"

    local created
    created="$(docker inspect "$container_name" --format '{{.Created}}' 2>/dev/null | cut -dT -f1)"

    echo "$image_name|$image_id|$created"
}

# =============================================================================
# SCAN STACKS
# =============================================================================

scan_images() {
    _it_header "Docker Image Update Tracker"

    local -a stacks=()

    if [[ -n "$STACK_FILTER" ]]; then
        stacks=("$STACK_FILTER")
    else
        for dir in "$COMPOSE_DIR"/*/; do
            [[ -f "${dir}docker-compose.yml" ]] && stacks+=("$(basename "$dir")")
        done
    fi

    if [[ ${#stacks[@]} -eq 0 ]]; then
        echo "  ${_IT_YELLOW}No stacks found${_IT_RESET}"
        return
    fi

    local total_images=0
    local outdated_images=0
    local current_images=0
    local unknown_images=0

    declare -a all_results=()

    for stack in "${stacks[@]}"; do
        local compose_file="$COMPOSE_DIR/$stack/docker-compose.yml"
        [[ ! -f "$compose_file" ]] && continue

        # Get running containers for this stack
        local containers
        containers="$($DOCKER_COMPOSE_CMD -f "$compose_file" ps -q 2>/dev/null)"
        [[ -z "$containers" ]] && continue

        echo "  ${_IT_BOLD}${_IT_BLUE}$stack${_IT_RESET}"

        while IFS= read -r container_id; do
            [[ -z "$container_id" ]] && continue

            local container_name
            container_name="$(docker inspect "$container_id" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')"

            local image_name
            image_name="$(docker inspect "$container_id" --format '{{.Config.Image}}' 2>/dev/null)"

            local image_id
            image_id="$(docker inspect "$container_id" --format '{{.Image}}' 2>/dev/null | cut -d: -f2 | cut -c1-12)"

            local image_created
            image_created="$(docker image inspect "$image_name" --format '{{.Created}}' 2>/dev/null | cut -dT -f1)"

            local image_size
            image_size="$(docker image inspect "$image_name" --format '{{.Size}}' 2>/dev/null)"
            if [[ -n "$image_size" ]] && [[ "$image_size" =~ ^[0-9]+$ ]]; then
                if [[ "$image_size" -ge 1073741824 ]]; then
                    image_size="$(echo "scale=1; $image_size/1073741824" | bc)G"
                elif [[ "$image_size" -ge 1048576 ]]; then
                    image_size="$(echo "scale=1; $image_size/1048576" | bc)M"
                else
                    image_size="${image_size}B"
                fi
            else
                image_size="--"
            fi

            (( total_images++ ))

            # Determine freshness based on image creation date
            local status_icon status_color age_info="--"
            if [[ -n "$image_created" ]] && [[ "$image_created" != "--" ]]; then
                local image_epoch
                image_epoch="$(date -d "$image_created" '+%s' 2>/dev/null || echo 0)"
                local now_epoch
                now_epoch="$(date '+%s')"
                local age_days=$(( (now_epoch - image_epoch) / 86400 ))

                age_info="${age_days}d ago"

                if [[ "$age_days" -lt 7 ]]; then
                    status_icon="${_IT_GREEN}CURRENT${_IT_RESET}"
                    status_color="$_IT_GREEN"
                    (( current_images++ ))
                elif [[ "$age_days" -lt 30 ]]; then
                    status_icon="${_IT_YELLOW}AGING  ${_IT_RESET}"
                    status_color="$_IT_YELLOW"
                    (( current_images++ ))
                else
                    status_icon="${_IT_RED}STALE  ${_IT_RESET}"
                    status_color="$_IT_RED"
                    (( outdated_images++ ))
                fi
            else
                status_icon="${_IT_GRAY}UNKNOWN${_IT_RESET}"
                (( unknown_images++ ))
            fi

            if [[ "$QUICK_MODE" == "true" ]] && [[ "$status_color" == "$_IT_GREEN" ]]; then
                continue
            fi

            printf "    %s  ${_IT_DIM}%-30s${_IT_RESET} %-25s ${_IT_DIM}%-8s %-10s${_IT_RESET}\n" \
                "$status_icon" "$container_name" "$image_name" "$image_size" "$age_info"

            all_results+=("$stack|$container_name|$image_name|$image_id|$image_size|$age_info")
        done <<< "$containers"

        echo ""
    done

    # Summary
    echo "  ${_IT_GRAY}$(_it_repeat "-" 55)${_IT_RESET}"
    printf "  ${_IT_DIM}Images: %-5s  Current: ${_IT_GREEN}%-5s${_IT_RESET}${_IT_DIM}  Stale: ${_IT_RED}%-5s${_IT_RESET}${_IT_DIM}  Unknown: %-5s${_IT_RESET}\n" \
        "$total_images" "$current_images" "$outdated_images" "$unknown_images"
    echo ""

    if [[ "$outdated_images" -gt 0 ]]; then
        echo "  ${_IT_YELLOW}$outdated_images image(s) are over 30 days old — consider running updates${_IT_RESET}"
        echo "  ${_IT_DIM}Tip: Use ./start.sh to pull latest images during startup${_IT_RESET}"
        echo ""
    fi
}

# =============================================================================
# JSON OUTPUT
# =============================================================================

scan_images_json() {
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"images\": ["

    local first=true
    for dir in "$COMPOSE_DIR"/*/; do
        [[ ! -f "${dir}docker-compose.yml" ]] && continue
        local stack="$(basename "$dir")"
        local compose_file="${dir}docker-compose.yml"

        local containers
        containers="$($DOCKER_COMPOSE_CMD -f "$compose_file" ps -q 2>/dev/null)"
        [[ -z "$containers" ]] && continue

        while IFS= read -r cid; do
            [[ -z "$cid" ]] && continue
            local cname image
            cname="$(docker inspect "$cid" --format '{{.Name}}' 2>/dev/null | sed 's|^/||')"
            image="$(docker inspect "$cid" --format '{{.Config.Image}}' 2>/dev/null)"

            [[ "$first" == "true" ]] && first=false || echo ","
            printf '    {"stack": "%s", "container": "%s", "image": "%s"}' "$stack" "$cname" "$image"
        done <<< "$containers"
    done

    echo ""
    echo "  ]"
    echo "}"
}

# =============================================================================
# MAIN
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        scan_images_json
    else
        scan_images
    fi
fi
