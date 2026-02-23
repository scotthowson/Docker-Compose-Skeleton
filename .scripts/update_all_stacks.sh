#!/bin/bash
# =============================================================================
# Docker Stack Updater - Intelligent Stack Update System
# Production version with comprehensive logging and timestamp tracking
# =============================================================================

update_all_stacks() {
    log_focus "Starting intelligent Docker stack updates"
    
    local updated_stacks=0
    local skipped_stacks=0
    local failed_stacks=0
    local STACKS_DIR="$COMPOSE_DIR"
    
    # ==========================================================================
    # PHASE 1: PARALLEL IMAGE PULLING
    # ==========================================================================
    
    log_info_header "Phase 1: Pulling latest images for all stacks"
    local pull_pids=()
    local found_stacks=0
    local pull_results="/tmp/pull_results.$$"
    > "$pull_results"
    
    for dir in "$STACKS_DIR"/*; do
        if [[ -f "$dir/docker-compose.yml" ]]; then
            STACK_NAME=$(basename "$dir")
            found_stacks=$((found_stacks + 1))
            (
                cd "$dir" || exit 1
                if docker compose pull --quiet 2>/dev/null; then
                    echo "SUCCESS:$STACK_NAME" >> "$pull_results"
                else
                    echo "FAILED:$STACK_NAME" >> "$pull_results"
                fi
            ) &
            pull_pids+=($!)
        fi
    done
    
    if [[ $found_stacks -eq 0 ]]; then
        log_warning "No valid Docker stacks found"
        return 0
    fi
    
    log_status "Pulling images for $found_stacks stacks in parallel"
    
    # Wait for all pulls to complete
    for pid in "${pull_pids[@]}"; do
        wait "$pid"
    done
    
    # Display pull results with timestamps
    local pull_failures=0
    while IFS=':' read -r status stack_name; do
        case "$status" in
            "SUCCESS")
                log_success "$stack_name - Images pulled successfully"
                ;;
            "FAILED")
                log_error "$stack_name - Failed to pull images"
                ((pull_failures++))
                ;;
        esac
    done < "$pull_results"
    
    rm -f "$pull_results"
    
    if [[ $pull_failures -gt 0 ]]; then
        log_caution "$pull_failures stacks failed to pull images, continuing with available images"
    else
        log_confirmation "All images pulled successfully"
    fi
    
    # ==========================================================================
    # PHASE 2: INTELLIGENT UPDATE DETECTION & APPLICATION
    # ==========================================================================
    
    log_info_header "Phase 2: Analyzing image changes and applying updates"
    
    local temp_results="/tmp/stack_update_results.$$"
    > "$temp_results"
    
    for dir in "$STACKS_DIR"/*; do
        if [[ -f "$dir/docker-compose.yml" ]]; then
            STACK_NAME=$(basename "$dir")
            
            (
                cd "$dir" || exit 1
                
                # Check running container count
                local running_containers
                running_containers=$(docker compose ps --format "{{.Name}}" 2>/dev/null | wc -l)
                
                if [[ $running_containers -eq 0 ]]; then
                    log_info "$STACK_NAME - No running containers, images ready for next startup"
                    echo "SKIPPED" >> "$temp_results"
                    exit 0
                fi
                
                # Collect current running image SHA256 hashes
                local current_hashes=()
                while IFS= read -r img_name; do
                    if [[ -n "$img_name" ]]; then
                        local sha=$(docker inspect --format='{{.Id}}' "$img_name" 2>/dev/null)
                        [[ -n "$sha" ]] && current_hashes+=("$sha")
                    fi
                done < <(docker compose ps --format "{{.Image}}" 2>/dev/null | sort -u)
                
                # Collect latest available image SHA256 hashes
                local latest_hashes=()
                while IFS= read -r img_name; do
                    if [[ -n "$img_name" ]]; then
                        local sha=$(docker inspect --format='{{.Id}}' "$img_name" 2>/dev/null)
                        [[ -n "$sha" ]] && latest_hashes+=("$sha")
                    fi
                done < <(docker compose config | grep 'image:' | awk '{print $2}' | sort -u)
                
                # Intelligent hash comparison
                local images_changed=false
                
                if [[ ${#current_hashes[@]} -eq 0 ]] || [[ ${#latest_hashes[@]} -eq 0 ]]; then
                    # Fallback to update if detection fails
                    images_changed=true
                elif [[ ${#current_hashes[@]} -ne ${#latest_hashes[@]} ]]; then
                    # Different number of images indicates changes
                    images_changed=true
                else
                    # Sort arrays and compare element by element
                    IFS=$'\n' current_sorted=($(sort <<<"${current_hashes[*]}"))
                    IFS=$'\n' latest_sorted=($(sort <<<"${latest_hashes[*]}"))
                    
                    for i in "${!current_sorted[@]}"; do
                        if [[ "${current_sorted[i]}" != "${latest_sorted[i]}" ]]; then
                            images_changed=true
                            break
                        fi
                    done
                fi
                
                # Apply updates only when needed
                if [[ "$images_changed" = true ]]; then
                    log_important "$STACK_NAME - Applying rolling update to $running_containers containers"
                    
                    if docker compose up -d --remove-orphans 2>/dev/null; then
                        log_success "$STACK_NAME - Successfully updated with new images"
                        echo "UPDATED" >> "$temp_results"
                        sleep 1
                    else
                        log_error "$STACK_NAME - Update operation failed"
                        echo "FAILED" >> "$temp_results"
                    fi
                else
                    log_success "$STACK_NAME - Already running latest images ($running_containers containers)"
                    echo "UP_TO_DATE" >> "$temp_results"
                fi
            )
        fi
    done
    
    # ==========================================================================
    # RESULTS AGGREGATION
    # ==========================================================================
    
    # Process results from temporary file to avoid subshell variable scoping
    while IFS= read -r result; do
        case "$result" in
            "UPDATED")    ((updated_stacks++)) ;;
            "UP_TO_DATE") ((skipped_stacks++)) ;;
            "SKIPPED")    ((skipped_stacks++)) ;;
            "FAILED")     ((failed_stacks++)) ;;
        esac
    done < "$temp_results"
    
    rm -f "$temp_results"
    
    # ==========================================================================
    # PHASE 3: SYSTEM CLEANUP
    # ==========================================================================
    
    log_info_header "Phase 3: Cleaning up unused Docker images"
    
    # First, clean dangling images (untagged)
    log_status "Removing dangling images"
    local dangling_output
    dangling_output=$(docker image prune -f 2>/dev/null)
    local dangling_freed=$(echo "$dangling_output" | grep -E "Total reclaimed space|freed" | grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?B' | tail -1 || echo "0B")
    
    # Then, clean unused images (not referenced by any container)
    log_status "Removing unused images older than 24 hours"
    local unused_output
    unused_output=$(docker image prune -a -f --filter "until=24h" 2>/dev/null)
    local unused_freed=$(echo "$unused_output" | grep -E "Total reclaimed space|freed" | grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?B' | tail -1 || echo "0B")
    
    # Calculate total cleanup
    local total_cleanup="0B"
    if [[ "$dangling_freed" != "0B" ]] || [[ "$unused_freed" != "0B" ]]; then
        if [[ "$dangling_freed" != "0B" ]] && [[ "$unused_freed" != "0B" ]]; then
            total_cleanup="$dangling_freed + $unused_freed"
        elif [[ "$dangling_freed" != "0B" ]]; then
            total_cleanup="$dangling_freed"
        else
            total_cleanup="$unused_freed"
        fi
        log_success "Freed $total_cleanup of disk space"
    else
        # Debug: Show what Docker actually returned
        log_info "No images cleaned up"
        log_debug "Dangling output: $dangling_output"
        log_debug "Unused output: $unused_output"
    fi
    
    # ==========================================================================
    # FINAL SUMMARY REPORT
    # ==========================================================================
    
    log_confirmation "Docker stack update sequence completed"
    log_info_header "Update Summary Report"
    
    if [[ $updated_stacks -gt 0 ]]; then
        log_success "Stacks updated: $updated_stacks"
    fi
    
    if [[ $skipped_stacks -gt 0 ]]; then
        log_success "Stacks up-to-date: $skipped_stacks"
    fi
    
    if [[ $failed_stacks -gt 0 ]]; then
        log_error "Failed updates: $failed_stacks"
    fi
    
    log_info "Space freed: $total_cleanup"
    
    # Return appropriate exit code
    return $failed_stacks
}