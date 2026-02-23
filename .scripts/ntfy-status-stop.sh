#!/bin/bash

# Define the NTFY notification URL (only if not already set)
if [[ -z "${NTFY_URL:-}" ]]; then
    NTFY_URL="http://192.168.2.11:9280/server_notifications"
fi

# Define an array of container names you want to monitor for stoppage
declare -a containers_to_check=("Docker-Socket" "Traefik-v3.0" "Authelia" "Redis" "Spotify_DB" "Tautulli" "Universal_Database")

# Function to check the stoppage status of specified containers
check_stop_containers_status() {
    local all_stopped=true
    local still_running_containers=""

    log_info "Checking container stop status for ${#containers_to_check[@]} monitored containers..."

    # Loop through the list of containers to check
    for container in "${containers_to_check[@]}"; do
        local status=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)
        
        if [[ "$status" == "true" ]]; then
            all_stopped=false
            still_running_containers+="🔥 $container 🔸 (still running) 🚧 "
            log_warning "Container '$container' is still running"
        else
            log_info "Container '$container' is stopped"
        fi
    done

    # Send appropriate notification based on results
    if [[ "$all_stopped" == "true" ]]; then
        curl -s \
             -H "Title: Server Status - All Containers Stopped" \
             -H "Priority: high" \
             -H "X-Tags: server,stopped,howson-server" \
             -d "🌑 All specified containers have been successfully stopped. System is now idle. 🛑" \
             -H "Actions: view, View in Portainer, https://portainer.scotthowson.io/" \
             "$NTFY_URL" >/dev/null 2>&1
        log_alert "Notification sent for all containers stopped."
    else
        curl -s \
             -H "Title: Server Alert - Stop Failure" \
             -H "Priority: urgent" \
             -H "X-Tags: server,running,howson-server" \
             -d "⚠️ Some containers are still running: $still_running_containers Immediate action may be necessary to stop them. 🚨" \
             -H "Actions: view, View in Portainer, https://portainer.scotthowson.io/" \
             "$NTFY_URL" >/dev/null 2>&1
        log_alert "Notification sent for failure to stop some containers."
    fi
}