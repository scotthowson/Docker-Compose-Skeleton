#!/bin/bash
# =============================================================================
# Docker Services Start Library v2.0
# Professional Docker Compose service management with enhanced logging
# 
# Description: Provides controlled startup of Docker Compose services
# Author: System Administrator
# Dependencies: Enhanced Logger System v2.0
# =============================================================================

#===============================================================================
# CONFIGURATION AND CONSTANTS
#===============================================================================

# Service Configuration - NO readonly declarations
NTFY_URL="http://192.168.2.11:9280/server_notifications"
COMPOSE_DIR="/home/howson/.Docker-Services/Stacks"
BASE_DIR="/home/howson/.Docker-Services"

# Services that require startup notifications
declare -ra NOTIFICATION_SERVICES=(
    "core-infrastructure"
    "web-applications" 
    "communication-collaboration"
)

# Service startup order (dependency order)
declare -ra DOCKER_SERVICES=(
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

#===============================================================================
# CORE SERVICE MANAGEMENT FUNCTIONS
#===============================================================================

# Start services for a specific service stack
# Args: $1 - service name
# Returns: 0 on success, 1 on failure
start_service_stack() {
    local -r service="$1"
    local -r service_path="$COMPOSE_DIR/$service"
    local -r env_file="$service_path/.env"
    local -r compose_file="$service_path/docker-compose.yml"
    
    # Validate service directory exists
    if [[ ! -d "$service_path" ]]; then
        log_error "Service directory not found: $service_path"
        return 1
    fi
    
    log_info "Starting services in $service stack..."
    
    # Load environment variables if .env file exists
    if [[ -f "$env_file" ]]; then
        log_debug "Loading environment variables from: $env_file"
        set -a # automatically export all variables
        source "$env_file"
        set +a
    else
        log_warning "No .env file found for $service, using defaults"
    fi
    
    # Execute docker-compose up with comprehensive options
    if docker-compose \
        -f "$compose_file" \
        up -d \
        --remove-orphans \
        --timeout 60 \
        --wait >> "$LOG_FILE" 2>&1; then
        
        log_success "$service service stack started successfully"
        
        # Send notification for specific services
        if _should_notify_service "$service"; then
            _send_start_notification "$service"
        fi
        
        return 0
    else
        log_error "Failed to start $service service stack. Check $LOG_FILE for details"
        _send_failure_notification "$service"
        return 1
    fi
}

# Check if a service should trigger notifications
# Args: $1 - service name
# Returns: 0 if should notify, 1 if not
_should_notify_service() {
    local service="$1"
    
    for notify_service in "${NOTIFICATION_SERVICES[@]}"; do
        [[ "$service" == "$notify_service" ]] && return 0
    done
    return 1
}

# Start multiple Docker Compose services
# Args: $@ - list of service names (optional, defaults to all services)
# Returns: 0 if all services started successfully, 1 if any failed
start_docker_compose_services() {
    local services_to_start=("$@")
    local failed_services=()
    local started_count=0
    local total_services=${#services_to_start[@]}
    
    log_info "Initiating startup of $total_services Docker services..."
    log_separator "=" 60 "SERVICE STARTUP SEQUENCE" "INFO"
    
    # Process each service with startup delay
    for service in "${services_to_start[@]}"; do
        if [[ -d "$COMPOSE_DIR/$service" ]]; then
            if start_service_stack "$service"; then
                ((started_count++))
                log_status "Progress: $started_count/$total_services services started"
                
                # Brief pause between services for system stability
                sleep 2
            else
                failed_services+=("$service")
                log_warning "Service '$service' failed to start cleanly"
            fi
        else
            log_warning "Service directory for '$service' does not exist, skipping..."
            failed_services+=("$service")
        fi
    done
    
    # Report final results
    log_separator "=" 60 "STARTUP SUMMARY" "INFO"
    
    if [[ ${#failed_services[@]} -eq 0 ]]; then
        log_success "All $started_count services started successfully"
        return 0
    else
        log_error "Failed to start ${#failed_services[@]} services: ${failed_services[*]}"
        log_info "Successfully started: $started_count/$total_services services"
        return 1
    fi
}

#===============================================================================
# NOTIFICATION FUNCTIONS
#===============================================================================

# Send service-specific startup notification
# Args: $1 - service name
_send_start_notification() {
    local service="$1"
    
    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Icon: https://dash.scotthowson.io/icons/howson_icon.png" \
            -H "Title: Service Alert - $service stack active" \
            -H "Priority: high" \
            -H "X-Tags: white_check_mark,scotthowson-io,howson-server,$service" \
            -d "🚀 $service is up and running! | Started without any issues. Explore the features now! 🎉" \
            "$NTFY_URL" >/dev/null 2>&1
        
        log_alert "Startup notification sent for $service"
    else
        log_warning "curl not available, skipping service notification"
    fi
}

# Send service failure notification
# Args: $1 - service name
_send_failure_notification() {
    local service="$1"
    
    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Title: Docker Compose - $service Failed" \
            -H "Priority: urgent" \
            -H "X-Tags: warning,no_entry_sign,howson-server,$service" \
            -d "🔥 Urgent: $service failed to start! Immediate action required. Check logs for troubleshooting." \
            -H "Actions: view, View in Portainer, https://portainer.scotthowson.io" \
            "$NTFY_URL" >/dev/null 2>&1
        
        log_alert "Failure notification sent for $service"
    else
        log_warning "curl not available, skipping error notification"
    fi
}

# Send general success notification
_send_success_notification() {
    local message="${1:-All Docker services started successfully}"
    
    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Title: Docker Services - Startup Complete" \
            -H "Priority: normal" \
            -H "X-Tags: white_check_mark,docker,startup" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true
        
        log_alert "General success notification sent to monitoring system"
    else
        log_warning "curl not available, skipping general notification"
    fi
}

# Send general failure notification
_send_general_failure_notification() {
    local message="${1:-Some Docker services failed to start}"
    
    if command -v curl >/dev/null 2>&1; then
        curl -s \
            -H "Title: Docker Services - Startup Issues" \
            -H "Priority: high" \
            -H "X-Tags: warning,docker,error" \
            -d "$message" \
            "$NTFY_URL" >/dev/null 2>&1 || true
        
        log_alert "General failure notification sent to monitoring system"
    else
        log_warning "curl not available, skipping error notification"
    fi
}

#===============================================================================
# MAIN SERVICE FUNCTION
#===============================================================================

# Main Docker services start function
# Args: $@ - optional list of specific services to start
# Returns: 0 on complete success, 1 if any issues occurred
start_docker_services() {
    local services_to_start
    local exit_code=0
    
    # Initialize execution
    log_info_header "Docker Services Startup Initiated"
    log_info "Startup requested at: $(date '+%Y-%m-%d %H:%M:%S')"
    
    # Determine which services to start
    if [[ "$#" -gt 0 ]]; then
        services_to_start=("$@")
        log_info "Selective startup requested for: ${services_to_start[*]}"
    else
        services_to_start=("${DOCKER_SERVICES[@]}")
        log_info "Full system startup requested for all ${#DOCKER_SERVICES[@]} services"
    fi
    
    # Validate at least one service specified
    if [[ ${#services_to_start[@]} -eq 0 ]]; then
        log_error "No services specified for startup"
        return 1
    fi
    
    # Execute the startup sequence
    log_focus "Beginning controlled Docker services startup..."
    
    if start_docker_compose_services "${services_to_start[@]}"; then
        log_highlight "All specified Docker resources started successfully"
        _send_success_notification "Successfully started ${#services_to_start[@]} Docker services"
        exit_code=0
    else
        log_error "Startup completed with errors. Check log file for details"
        _send_general_failure_notification "Docker services startup encountered issues"
        exit_code=1
    fi
    
    # Final status report
    log_separator "=" 60 "OPERATION COMPLETE" "SUCCESS"
    log_info "Startup operation completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Docker services startup completed successfully"
    else
        log_warning "Docker services startup completed with warnings"
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
    start_docker_services "$@"
    exit $?
fi

#===============================================================================
# EXPORT FUNCTIONS FOR EXTERNAL USE
#===============================================================================

# Export public functions for use by other scripts
export -f start_docker_services start_docker_compose_services
export -f start_service_stack