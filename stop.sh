#!/bin/bash

# Base Directory of the Script
COMPOSE_DIR="/home/howson/.Docker-Services"
export COMPOSE_DIR

# Source Configuration files and Libraries
for lib in "$COMPOSE_DIR/.config"/*.sh "$COMPOSE_DIR/.lib"/*.sh; do
    source "$lib"
done

# Source Scripts
for script in "$COMPOSE_DIR/.scripts"/*.sh; do
    source "$script"
done

# Initialize Logger
if [[ -z $LOGGER_INITIALIZED ]]; then
    initiate_logger
    export LOGGER_INITIALIZED=true
fi

# Set Terminal Title
set_terminal_title "$APPLICATION_TITLE"

# Main Function
main() {
    # Log Headers and Environment Verification
    log_bold_nodate_info_header "[ Made by: Scott Howson ]"
    verify_environment
    toggle_debug_mode "Debugger Enabled."

    # Update Docker-Compose
    stop_docker_services

    # Finalize Execution
    log_nodate_success "Main script execution complete."
}

# Error Handling
trap 'graceful_exit' ERR

# Execute Main Function
main
