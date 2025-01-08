#!/bin/bash
# debugger.sh

# Get the absolute directory of debugger.sh
DEBUGGER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load necessary configurations and libraries
source "$DEBUGGER_DIR/../.config/settings.cfg"
source "$DEBUGGER_DIR/logger.sh"

# Function to log debug messages and toggle Bash debug and verbose modes
toggle_debug_mode() {
    local message=$1

    # Check if debug or verbose mode should be enabled
    if [ "$LOG_LEVEL" == "DEBUG" ] || [ "$VERBOSE_MODE" == "true" ]; then
        log_event "DEBUG" "$message"  # Log the debug message
        set -x  # Enable Bash debug mode
        set -o verbose  # Enable Bash verbose mode
    else
        set +x  # Disable Bash debug mode
        set +o verbose  # Disable Bash verbose mode
    fi
}

# Additional debugging functions can be added here
