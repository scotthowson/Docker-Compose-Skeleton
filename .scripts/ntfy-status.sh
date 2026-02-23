#!/bin/bash
# =============================================================================
# Enhanced Container Status Monitor with NTFY Notifications
# Advanced monitoring with performance metrics and intelligent alerting
# =============================================================================

NTFY_URL="http://192.168.2.11:9280/server_notifications"
SERVER_NAME="Howson Server"
PORTAINER_URL="https://portainer.scotthowson.io/"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Critical containers that must always be running
declare -a critical_containers=(
    "Docker-Socket"
    "Traefik-v3.0" 
    "Authelia"
    "Redis"
    "Universal_Database"
)

# Important containers (alerts but not urgent)
declare -a important_containers=(
    "Spotify_DB"
    "Tautulli"
)

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

get_container_uptime() {
    local container=$1
    local started=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null)
    if [[ -n "$started" ]]; then
        local start_epoch=$(date -d "$started" +%s)
        local now_epoch=$(date +%s)
        local uptime_seconds=$((now_epoch - start_epoch))
        
        if [[ $uptime_seconds -lt 60 ]]; then
            echo "${uptime_seconds}s"
        elif [[ $uptime_seconds -lt 3600 ]]; then
            echo "$((uptime_seconds / 60))m"
        elif [[ $uptime_seconds -lt 86400 ]]; then
            echo "$((uptime_seconds / 3600))h $((uptime_seconds % 3600 / 60))m"
        else
            echo "$((uptime_seconds / 86400))d $((uptime_seconds % 86400 / 3600))h"
        fi
    else
        echo "unknown"
    fi
}

get_container_memory_usage() {
    local container=$1
    local stats=$(docker stats --no-stream --format "{{.MemUsage}}" "$container" 2>/dev/null)
    echo "${stats:-"N/A"}"
}

get_container_cpu_usage() {
    local container=$1
    local stats=$(docker stats --no-stream --format "{{.CPUPerc}}" "$container" 2>/dev/null)
    echo "${stats:-"N/A"}"
}

get_system_info() {
    local total_containers=$(docker ps -q | wc -l)
    local total_images=$(docker images -q | wc -l)
    local disk_usage=$(df -h / | tail -1 | awk '{print $5}' | sed 's/%//')
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    
    echo "Containers: $total_containers | Images: $total_images | Disk: ${disk_usage}% | Load: $load_avg"
}

# =============================================================================
# MAIN STATUS CHECK FUNCTION
# =============================================================================

check_containers_status() {
    local critical_down=()
    local important_down=()
    local critical_issues=()
    local status_details=""
    local healthy_count=0
    local total_monitored=$((${#critical_containers[@]} + ${#important_containers[@]}))
    
    log_bold_status "🔍 Checking container status..."
    
    # Check critical containers
    for container in "${critical_containers[@]}"; do
        local status=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)
        local health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)
        
        if [[ "$status" != "true" ]]; then
            critical_down+=("$container")
            critical_issues+=("🔴 $container (STOPPED)")
        elif [[ "$health" == "unhealthy" ]]; then
            critical_issues+=("🟡 $container (UNHEALTHY)")
            ((healthy_count++))
        else
            local uptime=$(get_container_uptime "$container")
            status_details+="✅ $container ($uptime) "
            ((healthy_count++))
        fi
    done
    
    # Check important containers
    for container in "${important_containers[@]}"; do
        local status=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)
        local health=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)
        
        if [[ "$status" != "true" ]]; then
            important_down+=("$container")
        elif [[ "$health" == "unhealthy" ]]; then
            status_details+="🟡 $container (unhealthy) "
            ((healthy_count++))
        else
            local uptime=$(get_container_uptime "$container")
            status_details+="✅ $container ($uptime) "
            ((healthy_count++))
        fi
    done
    
    # System information
    local system_info=$(get_system_info)
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Wait for services to stabilize
    log_bold_status "⏳ Allowing services to stabilize..."
    sleep 8
    
    # =============================================================================
    # SEND NOTIFICATIONS BASED ON STATUS
    # =============================================================================
    
    if [[ ${#critical_down[@]} -gt 0 ]]; then
        # CRITICAL ALERT
        local critical_list=$(printf " • %s\n" "${critical_down[@]}")
        local message="🚨 CRITICAL SYSTEM FAILURE 🚨

Critical services are down:
$critical_list

System Status: ${healthy_count}/${total_monitored} containers operational
Time: $timestamp
Info: $system_info

Immediate intervention required!"

        curl -H "Title: 🚨 CRITICAL: $SERVER_NAME Down" \
             -H "Priority: urgent" \
             -H "X-Tags: critical,server,down,emergency" \
             -d "$message" \
             -H "Actions: view, Emergency Dashboard, $PORTAINER_URL; http, Restart Services, $PORTAINER_URL/restart, method=POST" \
             "$NTFY_URL" &>/dev/null
             
    elif [[ ${#important_down[@]} -gt 0 ]] || [[ ${#critical_issues[@]} -gt 0 ]]; then
        # WARNING ALERT
        local issue_list=""
        [[ ${#important_down[@]} -gt 0 ]] && issue_list+=$(printf " • %s (stopped)\n" "${important_down[@]}")
        [[ ${#critical_issues[@]} -gt 0 ]] && issue_list+=$(printf " • %s\n" "${critical_issues[@]}")
        
        local message="⚠️ SERVICE ISSUES DETECTED ⚠️

Issues requiring attention:
$issue_list

System Status: ${healthy_count}/${total_monitored} containers operational
Time: $timestamp
Info: $system_info"

        curl -H "Title: ⚠️ Service Issues - $SERVER_NAME" \
             -H "Priority: high" \
             -H "X-Tags: warning,server,issues" \
             -d "$message" \
             -H "Actions: view, Check Dashboard, $PORTAINER_URL" \
             "$NTFY_URL" &>/dev/null
             
    else
        # ALL SYSTEMS OPERATIONAL
        local uptime_info=$(uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
        local message="🌐 ALL SYSTEMS OPERATIONAL 🌐

Status: All ${total_monitored} monitored containers are healthy
Uptime: $uptime_info
Time: $timestamp
Info: $system_info

$status_details

Infrastructure running optimally! 🚀"

        curl -H "Title: ✅ $SERVER_NAME - All Systems GO" \
             -H "Priority: default" \
             -H "X-Tags: success,server,operational,healthy" \
             -d "$message" \
             -H "Actions: view, View Dashboard, $PORTAINER_URL" \
             "$NTFY_URL" &>/dev/null
    fi
    
    log_success "📱 Notification sent successfully"
}

# =============================================================================
# EXTENDED MONITORING FUNCTIONS
# =============================================================================

check_resource_usage() {
    log_bold_info "📊 Gathering system metrics..."
    
    local high_cpu_containers=()
    
    for container in "${critical_containers[@]}" "${important_containers[@]}"; do
        if docker ps --format "{{.Names}}" | grep -q "^${container}$"; then
            local cpu=$(docker stats --no-stream --format "{{.CPUPerc}}" "$container" 2>/dev/null)
            
            # Extract numeric value from CPU percentage
            if [[ "$cpu" =~ ^([0-9]+\.?[0-9]*)% ]]; then
                local cpu_num=${BASH_REMATCH[1]}
                if (( $(echo "$cpu_num > 80" | bc -l) )); then
                    high_cpu_containers+=("$container ($cpu)")
                fi
            fi
        fi
    done
    
    if [[ ${#high_cpu_containers[@]} -gt 0 ]]; then
        local message="📊 RESOURCE USAGE ALERT 📊

High CPU usage detected:
$(printf " • %s\n" "${high_cpu_containers[@]}")

Monitor system performance closely."

        curl -H "Title: 📊 Resource Alert - $SERVER_NAME" \
             -H "Priority: default" \
             -H "X-Tags: performance,monitoring,resources" \
             -d "$message" \
             "$NTFY_URL" &>/dev/null
    fi
}

# =============================================================================
# SCRIPT EXECUTION (Only when called directly, not when sourced)
# =============================================================================

# Only execute if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main() {
        echo "🚀 Starting enhanced container monitoring..."
        echo "⏰ Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "🎯 Monitoring ${#critical_containers[@]} critical + ${#important_containers[@]} important containers"
        
        check_containers_status
        
        # Optional: Enable resource monitoring
        # check_resource_usage
        
        echo "✅ Monitoring cycle completed"
    }

    # Run the main function
    main "$@"
fi