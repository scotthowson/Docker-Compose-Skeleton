#!/bin/bash
initiate_docker_update() {
    # Define the location where Docker Compose binary will be installed
    INSTALL_LOCATION="/usr/local/bin/docker-compose"

    # Display current Docker Compose version if installed
    if [ -f "$INSTALL_LOCATION" ]; then
        CURRENT_VERSION=$(docker-compose --version)
        log_bold_nodate_info "Current installed Docker Compose version: $CURRENT_VERSION"
    else
        CURRENT_VERSION="None"
        log_bold_nodate_warning "Docker Compose is not installed."
    fi

    # Fetch the latest Docker Compose version from GitHub
    log_bold_nodate_info "Fetching the latest release of Docker Compose from GitHub..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name')
    log_bold_nodate_highlight "Latest Docker Compose version on GitHub: $LATEST_VERSION"

    # Compare current and latest versions
    if [[ "$CURRENT_VERSION" == *"$LATEST_VERSION"* ]]; then
        log_bold_nodate_success "Your Docker Compose is up to date."
        return 0
    fi

    # Fetch the download URL for the latest Docker Compose release
    LATEST_RELEASE_URL=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.assets[] | select(.name | contains("linux-x86_64") and (endswith(".sha256") | not)) | .browser_download_url')

    # Check if the URL was successfully retrieved
    if [ -z "$LATEST_RELEASE_URL" ]; then
        log_bold_nodate_error "Failed to retrieve the download URL. Please check your internet connection or GitHub API."
        return 1
    else
        log_bold_nodate_status "Download URL retrieved successfully: $LATEST_RELEASE_URL"
    fi

    # Ask for confirmation to proceed with updating Docker Compose
    if log_bold_nodate_question "A new version of Docker Compose is available, do you want to update?"; then
        read -p " (y/n) " answer
        if [[ "$answer" != "y" ]]; then
            log_bold_nodate_tip "Update aborted by user."
            return 0
        fi
    fi

    # Download the latest release of Docker Compose
    log_bold_nodate_info "Downloading Docker Compose from the retrieved URL..."
    if sudo curl -L "$LATEST_RELEASE_URL" -o "$INSTALL_LOCATION"; then
        log_bold_nodate_success "Docker Compose downloaded successfully."
    else
        log_bold_nodate_error "Download failed. Please check the URL and your internet connection, and try again."
        return 1
    fi

    # Set executable permissions for Docker Compose
    log_bold_nodate_info "Setting executable permissions for Docker Compose..."
    if sudo chmod +x "$INSTALL_LOCATION"; then
        log_bold_nodate_success "Executable permissions set successfully."
    else
        log_bold_nodate_error "Failed to set executable permissions on Docker Compose. Please check your permissions."
        return 1
    fi

    # Confirm successful update and show the installed version
    log_bold_nodate_success "Docker Compose has been successfully updated to the latest version."
    log_bold_nodate_info "Installed Docker Compose version: $(docker-compose --version)"
}
