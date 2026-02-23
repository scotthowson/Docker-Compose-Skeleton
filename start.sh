#!/bin/bash
# =============================================================================
# Docker Services Start Script - Main Entry Point
# Coordinates Docker service startup with enhanced logging
# =============================================================================

# Set TERM if it's not set (for systemd execution)
if [[ -z "$TERM" ]]; then
    export TERM=xterm-256color
fi

# =============================================================================
# CONFIGURATION & INITIALIZATION
# =============================================================================

# Base Directory Configuration
BASE_DIR="/home/howson/.Docker-Services"
COMPOSE_DIR="/home/howson/.Docker-Services"
export BASE_DIR COMPOSE_DIR

# Suppress palette validation warnings during initialization
export PALETTE_QUIET=true

# Source the enhanced logger system
source "$BASE_DIR/.config/settings.cfg"
source "$BASE_DIR/.lib/logger.sh"
initiate_logger

# IMPORTANT: Export the logger state so sourced scripts can see it
export LOGGER_INITIALIZED=true

# =============================================================================
# SCRIPT LIBRARY IMPORTS
# =============================================================================

# Source required script libraries
source "$BASE_DIR/.scripts/run.sh"                 # start_docker_services function
source "$BASE_DIR/.scripts/update.sh"              # initiate_docker_update function
source "$BASE_DIR/.scripts/update_all_stacks.sh"   # cleanly update docker stacks
source "$BASE_DIR/.scripts/clean-up.sh"            # cleanup_docker_services function

# Check if optional status script exists before sourcing
if [[ -f "$BASE_DIR/.scripts/ntfy-status.sh" ]]; then
    source "$BASE_DIR/.scripts/ntfy-status.sh"
else
    log_info "NTFY status script not found, skipping container status monitoring"
fi

# Re-enable palette warnings after sourcing
unset PALETTE_QUIET

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

set_terminal_title() {
    local title="${1:-Docker Services Manager}"
    echo -ne "\033]0;${title}\007" 2>/dev/null || true
}

verify_environment() {
    log_info "Verifying Docker environment..."
    
    # Check if Docker is running
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not running or accessible"
        return 1
    fi
    
    # Check if docker-compose is available
    if ! command -v docker-compose >/dev/null 2>&1; then
        log_error "docker-compose command not found"
        return 1
    fi
    
    # Check base directories exist
    if [[ ! -d "$BASE_DIR/Stacks" ]]; then
        log_error "Docker Stacks directory not found: $BASE_DIR/Stacks"
        return 1
    fi
    
    log_success "Environment verification completed successfully"
    return 0
}

toggle_debug_mode() {
    local message="${1:-Debug mode toggled}"
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
        log_debug "$message"
        set -x  # Enable debug output
    else
        log_info "Debug mode disabled"
    fi
}

graceful_exit() {
    local exit_code="${1:-1}"
    log_warning "Script execution interrupted or failed"
    log_info "Performing graceful cleanup..."
    close_logger
    exit "$exit_code"
}

confirm_deletion() {
    local message="${1:-Are you sure you want to delete? [y/N]}"
    log_question "$message"
    read -n 1 -r reply
    echo
    case "$reply" in
        [Yy]) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# MAIN EXECUTION FUNCTION
# =============================================================================

main() {
    # Initialize session
    log_info_header "Docker Services Management System Started"
    log_info "Session initiated by: $(whoami)"
    log_info "Execution started at: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Set terminal title
    set_terminal_title "$APPLICATION_TITLE"
    
    # Environment verification
    log_focus "Performing environment verification..."
    if ! verify_environment; then
        log_error "Environment verification failed, aborting startup"
        graceful_exit 1
    fi
    
    # Optional debug mode toggle
    toggle_debug_mode "Debug mode enabled for startup sequence"
    
    # Execute startup sequence
    log_separator "=" 60 "STARTUP SEQUENCE"
    
    # Step 1: Update Docker Compose
    if command -v initiate_docker_update >/dev/null 2>&1; then
        log_focus "Step 1: Updating Docker Compose..."
        initiate_docker_update
    else
        log_info "Step 1: Docker update function not available, skipping"
    fi
    
    # Step 2: Cleanup services
    if command -v cleanup_docker_services >/dev/null 2>&1; then
        log_focus "Step 2: Cleaning up Docker services..."
        cleanup_docker_services
    else
        log_info "Step 2: Cleanup function not available, skipping"
    fi

    # Step 3: Start Docker services
    log_focus "Step 3: Starting Docker services..."
    if ! start_docker_services; then
        log_error "Failed to start Docker services"
        graceful_exit 1
    fi

    # Step 4: Update Docker stacks intelligently
    if command -v update_all_stacks >/dev/null 2>&1; then
        log_focus "Step 4: Updating Docker stacks..."
        if ! update_all_stacks; then
            log_warning "Some stacks failed to update, but continuing startup"
        fi
    else
        log_info "Step 4: Stack update function not available, skipping"
    fi
    
    # Step 5: Check container status
    if command -v check_containers_status >/dev/null 2>&1; then
        log_focus "Step 5: Checking container status..."
        check_containers_status
    else
        log_info "Step 5: Container status check function not available, skipping"
    fi
    
    # Completion
    log_separator "=" 60 "STARTUP COMPLETE" "SUCCESS"
    log_success "Docker services startup sequence completed successfully"
    log_info "All operations finished at: $(date '+%Y-%m-%d %H:%M:%S')"
}

# =============================================================================
# ERROR HANDLING AND SCRIPT EXECUTION
# =============================================================================

# Set up error handling
trap 'graceful_exit $?' ERR
trap 'graceful_exit 130' INT TERM

# Execute main function
main "$@"