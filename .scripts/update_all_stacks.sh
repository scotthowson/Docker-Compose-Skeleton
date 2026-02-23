#!/bin/bash
# =============================================================================
# Docker Stack Updater -- Intelligent Stack Update System
# Pulls latest images in parallel, compares SHA256 digests to detect real
# changes, applies rolling updates only when needed, and cleans up old images.
#
# This file is SOURCED by start.sh -- do not execute directly.
#
# Expected environment (set by caller):
#   $COMPOSE_DIR         -- path to Stacks/ directory
#   $DOCKER_COMPOSE_CMD  -- "docker compose" or "docker-compose"
#
# Logger functions (log_info, log_error, etc.) must be available.
# =============================================================================

# =============================================================================
# MAIN UPDATE FUNCTION
# =============================================================================

update_all_stacks() {
    log_focus "Starting intelligent Docker stack updates"

    local updated_stacks=0
    local skipped_stacks=0
    local failed_stacks=0
    local stacks_dir="$COMPOSE_DIR"

    # =========================================================================
    # PHASE 1: PARALLEL IMAGE PULLING
    # =========================================================================

    log_info_header "Phase 1: Pulling latest images for all stacks"

    local pull_pids=()
    local found_stacks=0
    local pull_results
    pull_results="/tmp/pull_results.$$"
    > "$pull_results"

    for dir in "$stacks_dir"/*/; do
        [[ -f "$dir/docker-compose.yml" ]] || continue

        local stack_name
        stack_name=$(basename "$dir")
        (( found_stacks++ ))

        (
            cd "$dir" || exit 1
            if $DOCKER_COMPOSE_CMD pull --quiet 2>/dev/null; then
                echo "SUCCESS:$stack_name" >> "$pull_results"
            else
                echo "FAILED:$stack_name" >> "$pull_results"
            fi
        ) &
        pull_pids+=($!)
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

    # Report pull results
    local pull_failures=0
    while IFS=':' read -r status stack_name; do
        case "$status" in
            SUCCESS) log_success "$stack_name - Images pulled successfully" ;;
            FAILED)
                log_error "$stack_name - Failed to pull images"
                (( pull_failures++ ))
                ;;
        esac
    done < "$pull_results"
    rm -f "$pull_results"

    if [[ $pull_failures -gt 0 ]]; then
        log_caution "$pull_failures stacks failed to pull images, continuing with available images"
    else
        log_confirmation "All images pulled successfully"
    fi

    # =========================================================================
    # PHASE 2: INTELLIGENT UPDATE DETECTION & APPLICATION
    # =========================================================================

    log_info_header "Phase 2: Analyzing image changes and applying updates"

    local temp_results="/tmp/stack_update_results.$$"
    > "$temp_results"

    for dir in "$stacks_dir"/*/; do
        [[ -f "$dir/docker-compose.yml" ]] || continue

        local stack_name
        stack_name=$(basename "$dir")

        (
            cd "$dir" || exit 1

            # Count running containers for this stack
            local running_containers
            running_containers=$($DOCKER_COMPOSE_CMD ps --format "{{.Name}}" 2>/dev/null | wc -l)

            if [[ $running_containers -eq 0 ]]; then
                log_info "$stack_name - No running containers, images ready for next startup"
                echo "SKIPPED" >> "$temp_results"
                exit 0
            fi

            # Collect SHA256 hashes for currently running images
            local current_hashes=()
            while IFS= read -r img_name; do
                [[ -z "$img_name" ]] && continue
                local sha
                sha=$(docker inspect --format='{{.Id}}' "$img_name" 2>/dev/null)
                [[ -n "$sha" ]] && current_hashes+=("$sha")
            done < <($DOCKER_COMPOSE_CMD ps --format "{{.Image}}" 2>/dev/null | sort -u)

            # Collect SHA256 hashes for latest pulled images
            local latest_hashes=()
            while IFS= read -r img_name; do
                [[ -z "$img_name" ]] && continue
                local sha
                sha=$(docker inspect --format='{{.Id}}' "$img_name" 2>/dev/null)
                [[ -n "$sha" ]] && latest_hashes+=("$sha")
            done < <($DOCKER_COMPOSE_CMD config 2>/dev/null | grep 'image:' | awk '{print $2}' | sort -u)

            # Compare hashes to detect real changes
            local images_changed=false

            if [[ ${#current_hashes[@]} -eq 0 ]] || [[ ${#latest_hashes[@]} -eq 0 ]]; then
                images_changed=true
            elif [[ ${#current_hashes[@]} -ne ${#latest_hashes[@]} ]]; then
                images_changed=true
            else
                IFS=$'\n' read -r -d '' -a current_sorted < <(printf '%s\n' "${current_hashes[@]}" | sort && printf '\0')
                IFS=$'\n' read -r -d '' -a latest_sorted  < <(printf '%s\n' "${latest_hashes[@]}"  | sort && printf '\0')

                for i in "${!current_sorted[@]}"; do
                    if [[ "${current_sorted[i]}" != "${latest_sorted[i]}" ]]; then
                        images_changed=true
                        break
                    fi
                done
            fi

            # Apply rolling update only when images have changed
            if [[ "$images_changed" == "true" ]]; then
                log_important "$stack_name - Applying rolling update to $running_containers containers"

                if $DOCKER_COMPOSE_CMD up -d --remove-orphans 2>/dev/null; then
                    log_success "$stack_name - Successfully updated with new images"
                    echo "UPDATED" >> "$temp_results"
                    sleep 1
                else
                    log_error "$stack_name - Update operation failed"
                    echo "FAILED" >> "$temp_results"
                fi
            else
                log_success "$stack_name - Already running latest images ($running_containers containers)"
                echo "UP_TO_DATE" >> "$temp_results"
            fi
        )
    done

    # =========================================================================
    # RESULTS AGGREGATION
    # =========================================================================

    while IFS= read -r result; do
        case "$result" in
            UPDATED)    (( updated_stacks++ )) ;;
            UP_TO_DATE) (( skipped_stacks++ )) ;;
            SKIPPED)    (( skipped_stacks++ )) ;;
            FAILED)     (( failed_stacks++ ))  ;;
        esac
    done < "$temp_results"
    rm -f "$temp_results"

    # =========================================================================
    # PHASE 3: SYSTEM CLEANUP
    # =========================================================================

    log_info_header "Phase 3: Cleaning up unused Docker images"

    # Remove dangling (untagged) images
    log_status "Removing dangling images"
    local dangling_output
    dangling_output=$(docker image prune -f 2>/dev/null)
    local dangling_freed
    dangling_freed=$(echo "$dangling_output" | grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?B' | tail -1 || echo "0B")

    # Remove unused images older than 24 hours
    log_status "Removing unused images older than 24 hours"
    local unused_output
    unused_output=$(docker image prune -a -f --filter "until=24h" 2>/dev/null)
    local unused_freed
    unused_freed=$(echo "$unused_output" | grep -oE '[0-9]+(\.[0-9]+)?[KMGT]?B' | tail -1 || echo "0B")

    # Report space freed
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
        log_info "No images cleaned up"
        log_debug "Dangling output: $dangling_output"
        log_debug "Unused output: $unused_output"
    fi

    # =========================================================================
    # FINAL SUMMARY
    # =========================================================================

    log_confirmation "Docker stack update sequence completed"
    log_info_header "Update Summary Report"

    [[ $updated_stacks -gt 0 ]] && log_success "Stacks updated: $updated_stacks"
    [[ $skipped_stacks -gt 0 ]] && log_success "Stacks up-to-date: $skipped_stacks"
    [[ $failed_stacks  -gt 0 ]] && log_error   "Failed updates: $failed_stacks"

    log_info "Space freed: $total_cleanup"

    return "$failed_stacks"
}
