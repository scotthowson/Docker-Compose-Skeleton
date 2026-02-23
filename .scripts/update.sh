#!/bin/bash

initiate_docker_update() {
    # Define constants
    local INSTALL_LOCATION="/usr/bin/docker-compose"
    local GITHUB_API_URL="https://api.github.com/repos/docker/compose/releases/latest"
    
    # Detect system architecture
    local ARCH=$(uname -m)
    local ARCH_SUFFIX
    case $ARCH in
        x86_64) ARCH_SUFFIX="linux-x86_64" ;;
        aarch64|arm64) ARCH_SUFFIX="linux-aarch64" ;;
        *) 
            log_bold_nodate_error "Unsupported architecture: $ARCH"
            return 1
            ;;
    esac

    # Check for required dependencies
    for cmd in curl jq sudo; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_bold_nodate_error "Required command '$cmd' not found. Please install it first."
            return 1
        fi
    done

    # Get current version if installed
    local CURRENT_VERSION
    if [ -f "$INSTALL_LOCATION" ]; then
        CURRENT_VERSION=$(docker-compose --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_bold_nodate_info "Current Docker Compose version: v$CURRENT_VERSION"
    else
        CURRENT_VERSION=""
        log_bold_nodate_warning "Docker Compose is not installed."
    fi

    # Fetch latest release info in single API call
    log_bold_nodate_info "Fetching latest Docker Compose release information..."
    local RELEASE_DATA
    if ! RELEASE_DATA=$(curl -sf --connect-timeout 10 --max-time 30 "$GITHUB_API_URL"); then
        log_bold_nodate_error "Failed to fetch release data from GitHub API. Check your internet connection."
        return 1
    fi

    # Extract version and download URL
    local LATEST_VERSION
    local DOWNLOAD_URL
    LATEST_VERSION=$(echo "$RELEASE_DATA" | jq -r '.tag_name' | sed 's/^v//')
    DOWNLOAD_URL=$(echo "$RELEASE_DATA" | jq -r --arg suffix "docker-compose-$ARCH_SUFFIX" '.assets[] | select(.name == $suffix) | .browser_download_url')

    if [ -z "$LATEST_VERSION" ] || [ "$LATEST_VERSION" == "null" ]; then
        log_bold_nodate_error "Failed to parse latest version from GitHub API response."
        return 1
    fi

    if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
        log_bold_nodate_error "No compatible binary found for architecture: $ARCH"
        return 1
    fi

    log_bold_nodate_highlight "Latest version available: v$LATEST_VERSION"

    # Compare versions (skip if current version matches latest)
    if [ "$CURRENT_VERSION" == "$LATEST_VERSION" ]; then
        log_bold_nodate_success "Docker Compose is already up to date (v$LATEST_VERSION)."
        return 0
    fi

    # User confirmation
    log_bold_nodate_question "Update Docker Compose from v${CURRENT_VERSION:-"none"} to v$LATEST_VERSION? (y/N): "
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        log_bold_nodate_tip "Update cancelled by user."
        return 0
    fi

    # Create backup of existing installation
    if [ -f "$INSTALL_LOCATION" ]; then
        log_bold_nodate_info "Creating backup of current installation..."
        if ! sudo cp "$INSTALL_LOCATION" "${INSTALL_LOCATION}.backup.$(date +%Y%m%d_%H%M%S)"; then
            log_bold_nodate_warning "Failed to create backup, but continuing with update..."
        fi
    fi

    # Download and install with progress
    log_bold_nodate_info "Downloading Docker Compose v$LATEST_VERSION..."
    if sudo curl -fL --progress-bar --connect-timeout 10 --max-time 300 "$DOWNLOAD_URL" -o "$INSTALL_LOCATION"; then
        log_bold_nodate_success "Download completed successfully."
    else
        log_bold_nodate_error "Download failed. Restoring from backup if available..."
        [ -f "${INSTALL_LOCATION}.backup.*" ] && sudo mv "${INSTALL_LOCATION}.backup."* "$INSTALL_LOCATION" 2>/dev/null
        return 1
    fi

    # Set executable permissions
    if ! sudo chmod +x "$INSTALL_LOCATION"; then
        log_bold_nodate_error "Failed to set executable permissions."
        return 1
    fi

    # Verify installation
    local INSTALLED_VERSION
    if INSTALLED_VERSION=$(docker-compose --version 2>/dev/null); then
        log_bold_nodate_success "Docker Compose successfully updated!"
        log_bold_nodate_info "Installed version: $INSTALLED_VERSION"
        
        # Clean up old backups (keep only 3 most recent)
        find /usr/bin -name "docker-compose.backup.*" -type f 2>/dev/null | sort | head -n -3 | xargs -r sudo rm -f
    else
        log_bold_nodate_error "Installation verification failed. Docker Compose may not be working correctly."
        return 1
    fi

    return 0
}