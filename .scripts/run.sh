#!/bin/bash
start_docker_services() {
    # Define the directory for Docker Compose configurations
    COMPOSE_DIR="/home/howson/.Docker-Services/Stacks"
    BASE_DIR="/home/howson/.Docker-Services"

    # Source Scripts
    for script in "$BASE_DIR/.scripts"/*.sh; do
        source "$script"
    done

    # Log file location
    LOG_FILE="$BASE_DIR/Docker.log"

    # Function to load environment variables and start services
    start_service() {
        local service="$1"
        log_bold_nodate_info "Starting Docker Compose service stacks..." | tee -a "$LOG_FILE"
        log_bold_nodate_note "Starting services in $service stack..." | tee -a "$LOG_FILE"
        set -a # automatically export all variables
        if [ -f "$COMPOSE_DIR/$service/.env" ]; then
            source "$COMPOSE_DIR/$service/.env"
        fi
        set +a
        if docker-compose -f "$COMPOSE_DIR/$service/docker-compose.yml" up -d --remove-orphans >> "$LOG_FILE" 2>&1; then
            log_bold_nodate_success "$service service stack started successfully." | tee -a "$LOG_FILE"
        else
            log_bold_nodate_error "Error starting $service service stack. Check $LOG_FILE for details." | tee -a "$LOG_FILE" >&2
            # No exit here; continue to the next service
        fi
    }

    # List of services in the order they should be started
    services=("core-infrastructure" "networking-security" "monitoring-management" 
              "development-tools" "media-services" "web-applications" 
              "storage-backup" "communication-collaboration" "entertainment-personal" 
              "miscellaneous-services")

    # Start all specified services, whether default or from command-line arguments
    for service in "${services[@]}"; do
        if [[ -d "$COMPOSE_DIR/$service" ]]; then
            start_service "$service"
        else
            log_bold_nodate_tip "Service directory for $service does not exist, skipping..." | tee -a "$LOG_FILE"
        fi
    done

    log_bold_nodate_highlight "All requested services processed." | tee -a "$LOG_FILE"
}
