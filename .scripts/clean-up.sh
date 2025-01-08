#!/bin/bash
cleanup_docker_services() {
    # Base directory where volumes are stored
    export BASE_DIR="/home/howson/.Docker-Services/App-Data"
    log_bold_nodate_info "Base directory set to: $BASE_DIR"

    # Directory containing Docker Compose files
    COMPOSE_DIR="/home/howson/.Docker-Services/Stacks"

    # List all volume directories
    volume_dirs=$(find $BASE_DIR -mindepth 1 -maxdepth 1 -type d | awk -F'/' '{print $NF}')
    # echo -e "Volumes found in the filesystem:"
    # echo -e "$volume_dirs"
    # echo ""

    # Prepare to collect used volumes
    log_bold_nodate_highlight "Scanning Docker Compose files at: $COMPOSE_DIR"
    find $COMPOSE_DIR -name "docker-compose.yml" | while read file; do
        log_bold_nodate_focus "Reading file: $file"
        # Use envsubst to replace ${BASE_DIR} and then use awk to ensure only base directories are extracted
        volumes_in_file=$(cat "$file" | envsubst | grep -oP "${BASE_DIR}/[^:/]*" | awk -F'/' '{print $NF}')
        echo "$volumes_in_file" >> volumes.txt
    done

    # Read unique volumes from file
    used_volumes=$(sort -u volumes.txt)
    # echo -e "Consolidated volumes from all Docker Compose files:"
    # echo -e "$used_volumes"
    # echo ""

    # Cleanup temporary file
    rm volumes.txt

    # Check which directories are not referenced
    log_bold_nodate_info "Checking for unreferenced directories..."
    to_be_deleted=()
    for dir in $volume_dirs; do
        if ! grep -q "^$dir$" <<< "$used_volumes"; then
            to_be_deleted+=("$dir")
        fi
    done

    if [ ${#to_be_deleted[@]} -eq 0 ]; then
        log_bold_nodate_success "No unused directories found. Nothing to delete."
    else
        log_bold_nodate_warning "The following directories are not referenced in any docker-compose.yml and can be deleted:"
        for dir in "${to_be_deleted[@]}"; do
            log_bold_nodate_caution "$BASE_DIR/$dir"
        done

        if confirm_deletion "[WARNING] Are you sure you want to delete these directories?"; then
            for dir in "${to_be_deleted[@]}"; do
                sudo rm -rf "$BASE_DIR/$dir"
                log_bold_nodate_success "Deleted $BASE_DIR/$dir"
            done
        else
            log_bold_nodate_error "Deletion aborted by user or timeout reached."
        fi
    fi
    log_bold_nodate_status "Verification complete."
}
