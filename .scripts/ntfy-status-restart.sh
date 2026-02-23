#!/bin/bash

# Define the NTFY URL and load necessary configurations
NTFY_URL="http://192.168.2.11:9280/server_notifications"

# Define containers to monitor
declare -a containers_to_check=("Docker-Socket", "Traefik-v3.0", "Authelia", "Pterodactyl_Daemon", "Redis", "Spotify_DB", "Tautulli", "Universal_Database")

# Function to check the running status of specified containers
check_containers_running_status() {
    local all_stopped=true
    local still_running_containers=""

    # Check the running status of each container
    for container in "${containers_to_check[@]}"; do
        local status=$(docker inspect --format '{{.State.Running}}' $container 2>/dev/null)
        
        if [ "$status" == "true" ]; then
            all_stopped=false
            still_running_containers+="🔥 $container 🔸 (still running) 🚧 "
        fi
    done

    # Send notifications based on the status
    if [ "$all_stopped" == true ]; then
        curl -H "Title: Server Status - All Containers Stopped" \
             -H "Priority: high" \
             -H "X-Tags: server,stopped,howson-server" \
             -d "🌑 All specified containers have been successfully stopped. System is now idle. 🛑" \
             -H "Actions: view, View in Portainer, https://portainer.scotthowson.io/" \
             "$NTFY_URL" > /dev/null 2>&1
        log_nodate_alert "Notification sent for all containers stopped."
    else
        curl -H "Title: Server Alert - Running Containers" \
             -H "Priority: urgent" \
             -H "X-Tags: server,running,howson-server" \
             -d "⚠️ Some containers are still running: $still_running_containers Immediate action may be necessary to manage them. 🚨" \
             -H "Actions: view, View in Portainer, https://portainer.scotthowson.io/" \
             "$NTFY_URL" > /dev/null 2>&1
        log_nodate_alert "Notification sent for some containers still running."
    fi
}
