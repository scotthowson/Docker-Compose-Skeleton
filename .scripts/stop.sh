#!/bin/bash
stop_docker_services() {

# Define the base directory for Docker Compose files
COMPOSE_DIR="/home/howson/.Docker-Services/Stacks"
BASE_DIR="/home/howson/.Docker-Services"
# Log file location
LOG_FILE="$BASE_DIR/Docker.log"

# Function to stop and remove Docker containers for a given service
stop_and_remove_containers() {
    local service="$1"
    log_bold_nodate_info "Stopping and removing containers in $service..." | tee -a "$LOG_FILE"
    if docker-compose --env-file "$COMPOSE_DIR/$service/.env" -f "$COMPOSE_DIR/$service/docker-compose.yml" down --remove-orphans >> "$LOG_FILE" 2>&1; then
        log_bold_nodate_success "Successfully stopped and removed containers in $service." | tee -a "$LOG_FILE"
    else
        log_bold_nodate_error "Failed to stop containers in $service. Check $LOG_FILE for details." | tee -a "$LOG_FILE"
    fi
}

# List of services in the reverse order they should be stopped
services=(
    "miscellaneous-services"
    "entertainment-personal"
    "communication-collaboration"
    "storage-backup"
    "web-applications"
    "media-services"
    "development-tools"
    "monitoring-management"
    "networking-security"
    "core-infrastructure"
)

# Function to stop Docker Compose services based on command-line arguments or predefined list
stop_docker_compose_services() {
    local services_to_stop=("$@")
    log_bold_nodate_info "Stopping Docker Compose services..." | tee -a "$LOG_FILE"
    for service in "${services_to_stop[@]}"; do
        if [ -d "$COMPOSE_DIR/$service" ]; then
            stop_and_remove_containers "$service"
        else
            log_bold_nodate_warning "Service directory for $service does not exist, skipping..." | tee -a "$LOG_FILE"
        fi
    done
}

# Main script

# Clear log file
> "$LOG_FILE"

# Check for command-line arguments to selectively stop services
if [ "$#" -gt 0 ]; then
    # Use command-line arguments if specified
    stop_docker_compose_services "$@"
else
    # Use predefined list if no arguments are provided
    stop_docker_compose_services "${services[@]}"
fi

# Report success
log_bold_nodate_highlight "All specified Docker resources stopped and removed successfully." | tee -a "$LOG_FILE"


}
