#!/bin/bash
# =============================================================================
# Docker Services Stop Library v2.0
# Professional Docker Compose service management with enhanced logging
# 
# Description: Provides controlled shutdown of Docker Compose services
# Author: System Administrator
# Dependencies: Enhanced Logger System v2.0
# =============================================================================

#===============================================================================
# CONFIGURATION AND CONSTANTS
#===============================================================================

# Service Configuration
declare -r NTFY_URL="http://192.168.2.11:9280/server_notifications"
declare -r COMPOSE_DIR="/home/howson/.Docker-Services/Stacks"
declare -r BASE_DIR="/home/howson/.Docker-Services"

# Service shutdown order (reverse dependency order)
declare -ra DOCKER_SERVICES=(
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

#===============================================================================
# CORE SERVICE MANAGEMENT FUNCTIONS
#===============================================================================

# Stop and remove containers for a specific service
# Args: $1 - service name
# Returns: 0 on success, 1 on failure
stop_and_remove_containers() {
    local -r service="$1"
    local -r service_path="$COMPOSE_DIR/$service"
    local -r env_file="$service_path/.env"
    local -r compose_file="$service_path/docker-compose.yml"
    
    # Validate service directory exists
    if [[ ! -d "$service_path" ]]; then
        log_error "Service directory not found: $service_path"
        return 1
    fi
    
    log_info "Stopping and removing containers in $service..."
    
    # Execute docker-compose down with comprehensive options
    if docker-compose \
        --env-file "$env_file" \
        -f "$compose_file" \
        down \
        --remove-orphans \
        --volumes \
        --timeout 30 >> "$LOG_FILE" 2>&1; then
        
        log_success "Successfully stopped and removed containers in $service"
        return 0
    else
        log_error "Failed to stop containers in $service. Check $LOG_FILE for details"
        return 1
    fi
}

# Stop multiple Docker Compose services
# Args: $@ - list of service names (optional, defaults to all services)
# Returns: 0 if all services stopped successfully, 1 if any failed
stop_docker_compose_services() {
    local services_to_stop=("$@")
    local failed_services=()
    local stopped_count=0
    local total_services=${#services_to_stop[@]}
    
    log_info "Initiating shutdown of $total_services Docker services..."
    log_separator "=" 60 "SERVICE SHUTDOWN SEQUENCE" "SUCCESS"
    
    # Process each service
    for service in "${services_to_stop[@]}"; do
        if [[ -d "$COMPOSE_DIR/$service" ]]; then
            if stop_and_remove_containers "$service"; then
                ((stopped_count++))
                log_status "Progress: $stopped_count/$total_services services stopped"
            else
                failed_services+=("$service")
                log_warning "Service '$service' failed to stop cleanly"
            fi
        else
            log_warning "Service directory for '$service' does not exist, skipping..."
            failed_services+=("$service")
        fi
        
        # Brief pause between services for system stability
        sleep 1
    done
    
    # Report final results
    log_separator "=" 60 "SHUTDOWN SUMMARY"
    
    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All $stopped_count services stopped successfully"
        return 0
    else
        log_error "Failed to stop ${#failed_services[@]} services: ${failed_services[*]}"
        log_info "Successfully stopped: $stopped_count/$total_services services"
        return 1
    fi
}

#===============================================================================
# NOTIFICATION FUNCTIONS
#===============================================================================

# Send success notification via NTFY
send_success_notification() {
    local message="${1:-Docker services stopped successfully}"
    
    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Title: Docker Services - Shutdown Complete" \
            -H "Priority: normal" \
            -H "X-Tags: white_check_mark,docker,shutdown" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true
        
        log_alert "Success notification sent to monitoring system"
    else
        log_warning "curl not available, skipping notification"
    fi
}

# Send failure notification via NTFY
send_failure_notification() {
    local message="${1:-Some Docker services failed to stop}"
    
    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Title: Docker Services - Shutdown Issues" \
            -H "Priority: high" \
            -H "X-Tags: warning,docker,error" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true
        
        log_alert "Failure notification sent to monitoring system"
    else
        log_warning "curl not available, skipping error notification"
    fi
}

#===============================================================================
# MAIN SERVICE FUNCTION
#===============================================================================

# Main Docker services stop function
# Args: $@ - optional list of specific services to stop
# Returns: 0 on complete success, 1 if any issues occurred
stop_docker_services() {
    local services_to_stop
    local exit_code=0
    
    # Initialize execution
    log_info_header "Docker Services Shutdown Initiated"
    log_info "Shutdown requested at: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Determine which services to stop
    if [[ "$#" -gt 0 ]]; then
        services_to_stop=("$@")
        log_info "Selective shutdown requested for: ${services_to_stop[*]}"
    else
        services_to_stop=("${DOCKER_SERVICES[@]}")
        log_info "Full system shutdown requested for all ${#DOCKER_SERVICES[@]} services"
    fi
    
    # Validate at least one service specified
    if [[ ${#services_to_stop[@]} -eq 0 ]]; then
        log_error "No services specified for shutdown"
        return 1
    fi
    
    # Execute the shutdown sequence
    log_focus "Beginning controlled Docker services shutdown..."
    
    if stop_docker_compose_services "${services_to_stop[@]}"; then
        log_highlight "All specified Docker resources stopped and removed successfully"
        send_success_notification "Successfully stopped ${#services_to_stop[@]} Docker services"
        exit_code=0
    else
        log_error "Shutdown completed with errors. Check log file for details"
        send_failure_notification "Docker services shutdown encountered issues"
        exit_code=1
    fi
    
    # Final status report
    log_separator "=" 60 "OPERATION COMPLETE"
    log_info "Shutdown operation completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Docker services shutdown completed successfully"
    else
        log_warning "Docker services shutdown completed with warnings"
    fi
    
    return $exit_code
}

#===============================================================================
# SCRIPT EXECUTION HANDLER
#===============================================================================

# Execute the function if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Ensure logger is available
    if ! command -v log_info >/dev/null 2>&1; then
        echo "Error: Enhanced logger not available. Please source the logger first." >&2
        exit 1
    fi
    
    # Execute main function with all arguments
    stop_docker_services "$@"
    exit $?
fi

#===============================================================================
# EXPORT FUNCTIONS FOR EXTERNAL USE
#===============================================================================

# Export public functions for use by other scripts
export -f stop_docker_services stop_docker_compose_services
export -f stop_and_remove_containers send_success_notification send_failure_notification