#!/bin/bash
# Base Directory of the Script
BASE_DIR="/home/howson/.Docker-Services"
COMPOSE_DIR="/home/howson/.Docker-Services"
export BASE_DIR COMPOSE_DIR

# Source the enhanced logger system
source "$BASE_DIR/.config/settings.cfg"
source "$BASE_DIR/.lib/logger.sh"
initiate_logger

# Source only the specific scripts we need
source "$BASE_DIR/.scripts/stop.sh"

# Check if the ntfy status script exists before sourcing
if [[ -f "$BASE_DIR/.scripts/ntfy-status-stop.sh" ]]; then
    source "$BASE_DIR/.scripts/ntfy-status-stop.sh"
else
    log_warning "NTFY status script not found, skipping notification status check"
fi

# Main Function
main() {
    log_info_header "Docker Services Stop Script Started"
    
    stop_docker_services
    
    if command -v check_stop_containers_status >/dev/null 2>&1; then
        check_stop_containers_status
    else
        log_info "Container status check function not available, skipping"
    fi
    
    log_success "Main script execution complete."
}

# Execute Main Function
main