#!/bin/bash
# =============================================================================
# Docker Services Backup Script
# Simple, reliable backup with comprehensive error handling
# =============================================================================

# Base Directory Configuration
BASE_DIR="/home/howson/.Docker-Services"
export BASE_DIR

# Source the logger system
if [[ -f "$BASE_DIR/.config/settings.cfg" && -f "$BASE_DIR/.lib/logger.sh" ]]; then
    source "$BASE_DIR/.config/settings.cfg"
    source "$BASE_DIR/.lib/logger.sh"
    
    # Override log file for backup operations
    if [[ -n "${BACKUP_LOG_FILE:-}" ]]; then
        LOG_FILE="$BACKUP_LOG_FILE"
    fi
    
    initiate_logger
    LOGGER_AVAILABLE=true
else
    LOGGER_AVAILABLE=false
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

SOURCE_DIR="/home/howson/.Docker-Services/"
BACKUP_ROOT="/mnt/Storage/Backups/Docker/Backups/"
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$DATE"
BACKUP_FILE="Docker-Compose-Backup-$DATE.tar.gz"
RETENTION_COUNT=6

# =============================================================================
# MAIN BACKUP FUNCTION
# =============================================================================

perform_docker_backup() {
    log_focus "Starting Docker services backup"
    log_info "Backup target: $BACKUP_FILE"
    
    # Verify prerequisites
    if [[ ! -d "$SOURCE_DIR" ]]; then
        log_error "Source directory does not exist: $SOURCE_DIR"
        return 1
    fi
    
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        log_info "Creating backup root directory"
        if ! mkdir -p "$BACKUP_ROOT"; then
            log_error "Failed to create backup root directory"
            return 1
        fi
    fi
    
    # Create backup directory
    log_status "Creating temporary backup directory"
    if ! mkdir -p "$BACKUP_DIR"; then
        log_error "Failed to create backup directory: $BACKUP_DIR"
        return 1
    fi
    
    # Perform rsync backup with elevated permissions to capture all files
    log_status "Performing comprehensive rsync backup"
    
    # First attempt: try with current permissions
    if rsync -av --delete --partial --stats \
             --exclude='App-Data/NextCloud/' \
             "$SOURCE_DIR" "$BACKUP_DIR" 2>/tmp/rsync_errors.$; then
        log_success "Rsync backup completed successfully"
    else
        local rsync_exit_code=$?
        log_warning "Initial rsync failed with exit code: $rsync_exit_code"
        
        # Check if it's a permission issue
        if grep -q "Permission denied\|Operation not permitted" /tmp/rsync_errors.$ 2>/dev/null; then
            log_info "Attempting backup with elevated permissions"
            
            # Second attempt: try with sudo to capture protected files
            if sudo rsync -av --delete --partial --stats \
                          --exclude='App-Data/NextCloud/' \
                          "$SOURCE_DIR" "$BACKUP_DIR" 2>/tmp/rsync_errors_sudo.$; then
                log_success "Rsync backup completed successfully with elevated permissions"
                # Fix ownership of backup files
                sudo chown -R "$(whoami):$(id -gn)" "$BACKUP_DIR"
            else
                local sudo_exit_code=$?
                log_error "Rsync backup failed even with elevated permissions (exit code: $sudo_exit_code)"
                log_error "Error details:"
                cat /tmp/rsync_errors_sudo.$ 2>/dev/null | head -10 | while read -r line; do
                    log_error "  $line"
                done
                rm -f /tmp/rsync_errors.$ /tmp/rsync_errors_sudo.$
                rm -rf "$BACKUP_DIR"
                return 1
            fi
        else
            log_error "Rsync backup failed with non-permission related errors"
            log_error "Error details:"
            cat /tmp/rsync_errors.$ 2>/dev/null | head -10 | while read -r line; do
                log_error "  $line"
            done
            rm -f /tmp/rsync_errors.$
            rm -rf "$BACKUP_DIR"
            return 1
        fi
    fi
    
    # Clean up error files
    rm -f /tmp/rsync_errors.$ /tmp/rsync_errors_sudo.$
    
    # Create compressed archive
    log_status "Creating compressed archive"
    if tar -czf "$BACKUP_ROOT/$BACKUP_FILE" -C "$BACKUP_DIR" .; then
        log_success "Archive created successfully"
        
        # Verify archive integrity
        if tar -tzf "$BACKUP_ROOT/$BACKUP_FILE" >/dev/null 2>&1; then
            log_success "Archive integrity verified"
        else
            log_error "Archive integrity check failed"
            rm -f "$BACKUP_ROOT/$BACKUP_FILE"
            rm -rf "$BACKUP_DIR"
            return 1
        fi
    else
        log_error "Archive creation failed"
        rm -rf "$BACKUP_DIR"
        return 1
    fi
    
    # Remove temporary directory
    log_status "Cleaning up temporary files"
    rm -rf "$BACKUP_DIR"
    
    # Clean up old backups
    log_status "Cleaning up old backups"
    cd "$BACKUP_ROOT" || return 1
    
    local backup_count=$(ls -1 Docker-Compose-Backup-*.tar.gz 2>/dev/null | wc -l)
    if [[ $backup_count -gt $RETENTION_COUNT ]]; then
        local removed_count=0
        ls -t Docker-Compose-Backup-*.tar.gz | tail -n +$((RETENTION_COUNT + 1)) | while read -r old_backup; do
            rm -f "$old_backup"
            ((removed_count++))
        done
        log_info "Removed old backups, keeping $RETENTION_COUNT most recent"
    else
        log_info "No old backups to remove"
    fi
    
    # Report final status
    local backup_size=$(du -h "$BACKUP_ROOT/$BACKUP_FILE" | cut -f1)
    log_success "Docker backup completed successfully"
    log_info "Final archive size: $backup_size"
    log_info "Location: $BACKUP_ROOT/$BACKUP_FILE"
    
    return 0
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

main() {
    local start_time=$(date +%s)
    
    log_info "Docker Services Backup Started"
    log_info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    
    if perform_docker_backup; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        log_confirmation "Backup operation completed in ${duration} seconds"
        exit 0
    else
        log_error "Backup operation failed"
        exit 1
    fi
}

# Run main function
main "$@"
