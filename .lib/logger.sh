#!/bin/bash
# Enhanced Logger System v2.0
# Provides comprehensive logging functionalities for Bash scripts
# Dependencies: settings.cfg, palette.sh

#===============================================================================
# GLOBAL VARIABLES AND INITIALIZATION
#===============================================================================

# Logger state tracking
declare -g LOGGER_INITIALIZED=false
declare -g LOGGER_VERSION="2.0"
declare -g LOGGER_START_TIME=""

# Error handling for missing dependencies with flexible path detection
_check_dependencies() {
    # Find configuration files using flexible path detection
    local settings_found=false
    local palette_found=false
    
    # Common path variations to check for settings.cfg
    local possible_settings=(
        "${BASE_DIR}/.config/settings.cfg"
        "${BASE_DIR}/.scripts/settings.cfg"
        "${COMPOSE_DIR}/../.config/settings.cfg"
        "${COMPOSE_DIR}/settings.cfg"
        "./settings.cfg"
        "./.config/settings.cfg"
    )
    
    # Common path variations to check for palette.sh
    local possible_palettes=(
        "${BASE_DIR}/.config/palette.sh"
        "${BASE_DIR}/.scripts/palette.sh"
        "${COMPOSE_DIR}/../.config/palette.sh"
        "${COMPOSE_DIR}/palette.sh"
        "./palette.sh"
        "./.config/palette.sh"
    )
    
    # Find settings.cfg
    for config in "${possible_settings[@]}"; do
        if [[ -f "$config" ]]; then
            export FOUND_SETTINGS_PATH="$config"
            settings_found=true
            break
        fi
    done
    
    # Find palette.sh
    for palette in "${possible_palettes[@]}"; do
        if [[ -f "$palette" ]]; then
            export FOUND_PALETTE_PATH="$palette"
            palette_found=true
            break
        fi
    done
    
    # Report what we found/didn't find
    local missing_deps=()
    [[ "$settings_found" != "true" ]] && missing_deps+=("settings.cfg")
    [[ "$palette_found" != "true" ]] && missing_deps+=("palette.sh")
    [[ -z "${LOG_FILE:-}" ]] && missing_deps+=("LOG_FILE variable")
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "❌ Logger Error: Missing dependencies: ${missing_deps[*]}" >&2
        echo "   Searched paths for settings.cfg: ${possible_settings[*]}" >&2
        echo "   Searched paths for palette.sh: ${possible_palettes[*]}" >&2
        return 1
    fi
    
    return 0
}

#===============================================================================
# LOGGER INITIALIZATION AND MANAGEMENT
#===============================================================================

# Initialize the logger system
initiate_logger() {
    # Prevent double initialization
    if [[ "$LOGGER_INITIALIZED" == "true" ]]; then
        return 0
    fi
    
    # Check dependencies before initialization
    if ! _check_dependencies; then
        echo "❌ Logger initialization failed due to missing dependencies" >&2
        return 1
    fi
    
    # Source required files using discovered paths
    export PALETTE_QUIET=true  # Suppress palette validation warnings
    source "${FOUND_SETTINGS_PATH}" || {
        echo "❌ Failed to source settings.cfg from ${FOUND_SETTINGS_PATH}" >&2
        return 1
    }
    source "${FOUND_PALETTE_PATH}" || {
        echo "❌ Failed to source palette.sh from ${FOUND_PALETTE_PATH}" >&2
        return 1
    }
    unset PALETTE_QUIET  # Re-enable palette warnings for future use
    
    # Create log directory if it doesn't exist
    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"
    
    # Create archive directory if it doesn't exist
    local archive_dir="${LOG_DIR}/archive"
    [[ ! -d "$archive_dir" ]] && mkdir -p "$archive_dir"
    
    # Archive existing log file if it exists and has content
    if [[ -f "$LOG_FILE" ]] && [[ -s "$LOG_FILE" ]]; then
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local archive_file="${archive_dir}/docker-services_${timestamp}.log"
        
        # Move existing log to archive with timestamp
        mv "$LOG_FILE" "$archive_file"
        
        # Compress the archived log file to save space
        if command -v gzip >/dev/null 2>&1; then
            gzip "$archive_file"
            log_nodate_info "Previous log archived to: ${archive_file}.gz" >&2
        else
            log_nodate_info "Previous log archived to: $archive_file" >&2
        fi
    fi
    
    # Initialize fresh log file with header
    {
        echo "==============================================================================="
        echo "Logger System v${LOGGER_VERSION} - Session Started: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Application: ${APPLICATION_TITLE:-Unknown Application}"
        echo "Script Version: ${SCRIPT_VERSION:-Unknown Version}"
        echo "Log Level: ${LOG_LEVEL:-INFO}"
        echo "Verbose Mode: ${VERBOSE_MODE:-false}"
        echo "==============================================================================="
        echo ""
    } > "$LOG_FILE"
    
    # Set global variables
    export LOGGER_INITIALIZED=true
    export LOGGER_START_TIME="$(date '+%s')"
    
    # Log successful initialization
    _log_event "SUCCESS" "Logger System v${LOGGER_VERSION} initialized successfully" "NODATE"
    
    return 0
}

# Gracefully close the logger
close_logger() {
    if [[ "$LOGGER_INITIALIZED" != "true" ]]; then
        return 0
    fi
    
    local session_duration=""
    if [[ -n "$LOGGER_START_TIME" ]]; then
        local end_time current_time
        end_time="$(date '+%s')"
        current_time=$((end_time - LOGGER_START_TIME))
        session_duration=" (Duration: ${current_time}s)"
    fi
    
    _log_event "INFO" "Logger session ended${session_duration}" "NODATE"
    
    {
        echo ""
        echo "--- Session Ended: $(date '+%Y-%m-%d %H:%M:%S')${session_duration} ---"
        echo ""
    } >> "$LOG_FILE"
    
    export LOGGER_INITIALIZED=false
}

#===============================================================================
# CORE LOGGING ENGINE
#===============================================================================

# Core logging function - handles all log processing
_log_event() {
    local mood="$1"
    local message="$2"
    local flags="${3:-}"
    
    # Validate inputs
    [[ -z "$mood" ]] && { echo "❌ Logger Error: No mood specified" >&2; return 1; }
    [[ -z "$message" ]] && { echo "❌ Logger Error: No message specified" >&2; return 1; }
    
    # Initialize if not already done
    [[ "$LOGGER_INITIALIZED" != "true" ]] && initiate_logger
    
    # Parse flags
    local is_bold=false
    local is_nodate=false
    local is_custom=false
    
    [[ "$flags" == *"BOLD"* ]] && is_bold=true
    [[ "$flags" == *"NODATE"* ]] && is_nodate=true
    [[ "$flags" == *"CUSTOM"* ]] && is_custom=true
    
    # Check if we should log this level
    if ! _should_log_level "$mood"; then
        return 0
    fi
    
    # Build console and file outputs
    local console_output
    local file_output
    
    console_output="$(_build_console_output "$mood" "$message" "$is_bold" "$is_nodate" "$is_custom")"
    file_output="$(_build_file_output "$mood" "$message" "$is_nodate" "$is_custom")"
    
    # Output to console and file
    echo -e "$console_output"
    echo "$file_output" >> "$LOG_FILE"
    
    # Handle special actions for certain log levels
    _handle_special_actions "$mood" "$message"
    
    return 0
}

# Determine if we should log based on level hierarchy
_should_log_level() {
    local mood="$1"
    
    # Log level hierarchy (lower number = higher priority)
    declare -A level_priority=(
        ["ERROR"]=1
        ["ALERT"]=1
        ["CRITICAL"]=1
        ["WARNING"]=2
        ["CAUTION"]=2
        ["IMPORTANT"]=3
        ["SUCCESS"]=3
        ["CONFIRMATION"]=3
        ["INFO"]=4
        ["STATUS"]=4
        ["FOCUS"]=4
        ["HIGHLIGHT"]=5
        ["NOTE"]=5
        ["TIP"]=5
        ["DEBUG"]=6
        ["VERBOSE"]=7
        ["NEUTRAL"]=8
    )
    
    # Current log level priority
    declare -A current_priority=(
        ["ERROR"]=1
        ["WARNING"]=2
        ["INFO"]=4
        ["DEBUG"]=6
        ["VERBOSE"]=7
    )
    
    local mood_priority="${level_priority[$mood]:-4}"
    local current_level_priority="${current_priority[${LOG_LEVEL:-INFO}]:-4}"
    
    # Log if mood priority is equal or higher (lower number)
    [[ $mood_priority -le $current_level_priority ]]
}

# Build console output with colors and formatting
_build_console_output() {
    local mood="$1"
    local message="$2"
    local is_bold="$3"
    local is_nodate="$4"
    local is_custom="$5"
    
    local prefix=""
    local color_code=""
    local reset_code="${COLOR_PALETTE[RESET]}"
    
    # Get color for mood
    color_code="${COLOR_PALETTE[$mood]:-${COLOR_PALETTE[NEUTRAL]}}"
    
    # Apply bold if requested
    [[ "$is_bold" == "true" ]] && color_code="$(tput bold)${color_code}"
    
    # Build timestamp prefix
    if [[ "$ENABLE_LOG_DATE" == "true" && "$is_nodate" == "false" ]]; then
        prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi
    
    # Build mood prefix
    if [[ "$mood" == "INFO_HEADER" && "$ENABLE_INFO_HEADER" == "true" ]]; then
        if [[ "$USE_CUSTOM_INFO_HEADER" == "true" ]]; then
            prefix="${prefix}${color_code}${CUSTOM_INFO_HEADER_TEXT}${reset_code}"
        else
            prefix="${prefix}${color_code}[INFO_HEADER]${reset_code}"
        fi
    else
        prefix="${prefix}${color_code}[${mood}]${reset_code}"
    fi
    
    # Add separator and message
    [[ -n "$prefix" ]] && prefix="${prefix} - "
    
    echo "${prefix}${color_code}${message}${reset_code}"
}

# Build file output without colors
_build_file_output() {
    local mood="$1"
    local message="$2"
    local is_nodate="$3"
    local is_custom="$4"
    
    local prefix=""
    
    # Build timestamp prefix
    if [[ "$ENABLE_LOG_DATE" == "true" && "$is_nodate" == "false" ]]; then
        prefix="[$(date '+%b/%d/%Y — %-l:%M %p')] "
    fi
    
    # Build mood prefix
    if [[ "$mood" == "INFO_HEADER" && "$ENABLE_INFO_HEADER" == "true" ]]; then
        if [[ "$USE_CUSTOM_INFO_HEADER" == "true" ]]; then
            prefix="${prefix}${CUSTOM_INFO_HEADER_TEXT}"
        else
            prefix="${prefix}[INFO_HEADER]"
        fi
    else
        prefix="${prefix}[${mood}]"
    fi
    
    # Add separator and message
    [[ -n "$prefix" ]] && prefix="${prefix} - "
    
    echo "${prefix}${message}"
}

# Handle special actions for certain log levels
_handle_special_actions() {
    local mood="$1"
    local message="$2"
    
    case "$mood" in
        "ERROR"|"CRITICAL")
            # Could add error counting, notifications, etc.
            ;;
        "DEBUG")
            # Could add debug-specific handling
            [[ "$VERBOSE_MODE" == "true" ]] && echo "  ↳ Debug context: ${BASH_SOURCE[3]:-unknown}:${BASH_LINENO[2]:-unknown}" >&2
            ;;
    esac
}

#===============================================================================
# STANDARD LOGGING FUNCTIONS
#===============================================================================

# Core log levels
log_info() { _log_event "INFO" "$1" "${2:-}"; }
log_success() { _log_event "SUCCESS" "$1" "${2:-}"; }
log_warning() { _log_event "WARNING" "$1" "${2:-}"; }
log_error() { _log_event "ERROR" "$1" "${2:-}"; }
log_debug() { _log_event "DEBUG" "$1" "${2:-}"; }

# Extended log levels
log_info_header() { _log_event "INFO_HEADER" "$1" "${2:-}"; }
log_important() { _log_event "IMPORTANT" "$1" "${2:-}"; }
log_note() { _log_event "NOTE" "$1" "${2:-}"; }
log_tip() { _log_event "TIP" "$1" "${2:-}"; }
log_confirmation() { _log_event "CONFIRMATION" "$1" "${2:-}"; }
log_alert() { _log_event "ALERT" "$1" "${2:-}"; }
log_caution() { _log_event "CAUTION" "$1" "${2:-}"; }
log_focus() { _log_event "FOCUS" "$1" "${2:-}"; }
log_highlight() { _log_event "HIGHLIGHT" "$1" "${2:-}"; }
log_neutral() { _log_event "NEUTRAL" "$1" "${2:-}"; }
log_prompt() { _log_event "PROMPT" "$1" "${2:-}"; }
log_status() { _log_event "STATUS" "$1" "${2:-}"; }
log_verbose() { _log_event "VERBOSE" "$1" "${2:-}"; }
log_question() { _log_event "QUESTION" "$1" "${2:-}"; }
log_critical() { _log_event "CRITICAL" "$1" "${2:-}"; }

#===============================================================================
# CONVENIENCE FUNCTION VARIANTS
#===============================================================================

# Bold variants
log_bold_info() { _log_event "INFO" "$1" "BOLD"; }
log_bold_success() { _log_event "SUCCESS" "$1" "BOLD"; }
log_bold_warning() { _log_event "WARNING" "$1" "BOLD"; }
log_bold_error() { _log_event "ERROR" "$1" "BOLD"; }
log_bold_debug() { _log_event "DEBUG" "$1" "BOLD"; }
log_bold_important() { _log_event "IMPORTANT" "$1" "BOLD"; }
log_bold_note() { _log_event "NOTE" "$1" "BOLD"; }
log_bold_tip() { _log_event "TIP" "$1" "BOLD"; }
log_bold_confirmation() { _log_event "CONFIRMATION" "$1" "BOLD"; }
log_bold_alert() { _log_event "ALERT" "$1" "BOLD"; }
log_bold_caution() { _log_event "CAUTION" "$1" "BOLD"; }
log_bold_focus() { _log_event "FOCUS" "$1" "BOLD"; }
log_bold_highlight() { _log_event "HIGHLIGHT" "$1" "BOLD"; }
log_bold_neutral() { _log_event "NEUTRAL" "$1" "BOLD"; }
log_bold_prompt() { _log_event "PROMPT" "$1" "BOLD"; }
log_bold_status() { _log_event "STATUS" "$1" "BOLD"; }
log_bold_verbose() { _log_event "VERBOSE" "$1" "BOLD"; }
log_bold_question() { _log_event "QUESTION" "$1" "BOLD"; }
log_bold_critical() { _log_event "CRITICAL" "$1" "BOLD"; }

# No-date variants
log_nodate_info() { _log_event "INFO" "$1" "NODATE"; }
log_nodate_success() { _log_event "SUCCESS" "$1" "NODATE"; }
log_nodate_warning() { _log_event "WARNING" "$1" "NODATE"; }
log_nodate_error() { _log_event "ERROR" "$1" "NODATE"; }
log_nodate_debug() { _log_event "DEBUG" "$1" "NODATE"; }
log_nodate_info_header() { _log_event "INFO_HEADER" "$1" "NODATE"; }
log_nodate_important() { _log_event "IMPORTANT" "$1" "NODATE"; }
log_nodate_note() { _log_event "NOTE" "$1" "NODATE"; }
log_nodate_tip() { _log_event "TIP" "$1" "NODATE"; }
log_nodate_confirmation() { _log_event "CONFIRMATION" "$1" "NODATE"; }
log_nodate_alert() { _log_event "ALERT" "$1" "NODATE"; }
log_nodate_caution() { _log_event "CAUTION" "$1" "NODATE"; }
log_nodate_focus() { _log_event "FOCUS" "$1" "NODATE"; }
log_nodate_highlight() { _log_event "HIGHLIGHT" "$1" "NODATE"; }
log_nodate_neutral() { _log_event "NEUTRAL" "$1" "NODATE"; }
log_nodate_prompt() { _log_event "PROMPT" "$1" "NODATE"; }
log_nodate_status() { _log_event "STATUS" "$1" "NODATE"; }
log_nodate_verbose() { _log_event "VERBOSE" "$1" "NODATE"; }
log_nodate_question() { _log_event "QUESTION" "$1" "NODATE"; }
log_nodate_critical() { _log_event "CRITICAL" "$1" "NODATE"; }

# Bold no-date variants
log_bold_nodate_info() { _log_event "INFO" "$1" "BOLD NODATE"; }
log_bold_nodate_success() { _log_event "SUCCESS" "$1" "BOLD NODATE"; }
log_bold_nodate_warning() { _log_event "WARNING" "$1" "BOLD NODATE"; }
log_bold_nodate_error() { _log_event "ERROR" "$1" "BOLD NODATE"; }
log_bold_nodate_debug() { _log_event "DEBUG" "$1" "BOLD NODATE"; }
log_bold_nodate_info_header() { _log_event "INFO_HEADER" "$1" "BOLD NODATE"; }
log_bold_nodate_important() { _log_event "IMPORTANT" "$1" "BOLD NODATE"; }
log_bold_nodate_note() { _log_event "NOTE" "$1" "BOLD NODATE"; }
log_bold_nodate_tip() { _log_event "TIP" "$1" "BOLD NODATE"; }
log_bold_nodate_confirmation() { _log_event "CONFIRMATION" "$1" "BOLD NODATE"; }
log_bold_nodate_alert() { _log_event "ALERT" "$1" "BOLD NODATE"; }
log_bold_nodate_caution() { _log_event "CAUTION" "$1" "BOLD NODATE"; }
log_bold_nodate_focus() { _log_event "FOCUS" "$1" "BOLD NODATE"; }
log_bold_nodate_highlight() { _log_event "HIGHLIGHT" "$1" "BOLD NODATE"; }
log_bold_nodate_neutral() { _log_event "NEUTRAL" "$1" "BOLD NODATE"; }
log_bold_nodate_prompt() { _log_event "PROMPT" "$1" "BOLD NODATE"; }
log_bold_nodate_status() { _log_event "STATUS" "$1" "BOLD NODATE"; }
log_bold_nodate_verbose() { _log_event "VERBOSE" "$1" "BOLD NODATE"; }
log_bold_nodate_question() { _log_event "QUESTION" "$1" "BOLD NODATE"; }
log_bold_nodate_critical() { _log_event "CRITICAL" "$1" "BOLD NODATE"; }

#===============================================================================
# UTILITY AND HELPER FUNCTIONS
#===============================================================================

# Log system information
log_system_info() {
    log_info_header "System Information"
    log_info "Hostname: $(hostname)"
    log_info "User: $(whoami)"
    log_info "PWD: $(pwd)"
    log_info "Shell: $SHELL"
    log_info "Date: $(date)"
}

# Log script start with metadata
log_script_start() {
    local script_name="${1:-$(basename "$0")}"
    local script_args="${2:-$*}"
    
    log_info_header "Script Execution Started"
    log_info "Script: $script_name"
    [[ -n "$script_args" ]] && log_info "Arguments: $script_args"
    log_info "PID: $$"
    log_info "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
}

# Log script end with execution time
log_script_end() {
    local exit_code="${1:-0}"
    local script_name="${2:-$(basename "$0")}"
    
    if [[ -n "$LOGGER_START_TIME" ]]; then
        local end_time duration
        end_time="$(date '+%s')"
        duration=$((end_time - LOGGER_START_TIME))
        log_info "Execution time: ${duration}s"
    fi
    
    if [[ "$exit_code" -eq 0 ]]; then
        log_success "Script '$script_name' completed successfully"
    else
        log_error "Script '$script_name' exited with code: $exit_code"
    fi
    
    log_info_header "Script Execution Completed"
}

# Log command execution with timing
log_command() {
    local cmd="$1"
    local description="${2:-Executing command}"
    
    log_info "$description: $cmd"
    
    local start_time end_time duration exit_code
    start_time="$(date '+%s')"
    
    # Execute command and capture exit code
    eval "$cmd"
    exit_code=$?
    
    end_time="$(date '+%s')"
    duration=$((end_time - start_time))
    
    if [[ $exit_code -eq 0 ]]; then
        log_success "Command completed successfully (${duration}s)"
    else
        log_error "Command failed with exit code $exit_code (${duration}s)"
    fi
    
    return $exit_code
}

# Create a colored log separator
log_separator() {
    local char="${1:--}"
    local length="${2:-80}"
    local message="$3"
    local color="${4:-FOCUS}"  # Default color for separators
    
    # Get color codes
    local color_code="${COLOR_PALETTE[$color]:-${COLOR_PALETTE[FOCUS]}}"
    local reset_code="${COLOR_PALETTE[RESET]}"
    
    local separator
    separator="$(printf "%*s" "$length" "" | tr ' ' "$char")"
    
    if [[ -n "$message" ]]; then
        local msg_length=${#message}
        local padding=$(( (length - msg_length - 2) / 2 ))
        separator="$(printf "%*s" "$padding" "" | tr ' ' "$char") $message $(printf "%*s" "$padding" "" | tr ' ' "$char")"
    fi
    
    # Console output with color
    echo -e "${color_code}${separator}${reset_code}"
    
    # File output without color
    echo "$separator" >> "$LOG_FILE"
}

# Validate logger configuration
validate_logger_config() {
    local errors=()
    
    # Check required variables
    [[ -z "${LOG_FILE:-}" ]] && errors+=("LOG_FILE not set")
    [[ -z "${APPLICATION_TITLE:-}" ]] && errors+=("APPLICATION_TITLE not set")
    [[ -z "${LOG_LEVEL:-}" ]] && errors+=("LOG_LEVEL not set")
    
    # Check log file permissions
    if [[ -n "${LOG_FILE:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        [[ ! -w "$log_dir" ]] && errors+=("Log directory not writable: $log_dir")
    fi
    
    # Report errors
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "❌ Logger configuration errors:" >&2
        printf "   - %s\n" "${errors[@]}" >&2
        return 1
    fi
    
    log_success "Logger configuration validated successfully"
    return 0
}

#===============================================================================
# TRAP HANDLERS AND CLEANUP
#===============================================================================

# Set up trap for clean logger shutdown
_setup_logger_traps() {
    trap 'close_logger' EXIT
    trap 'log_warning "Script interrupted by user"; close_logger; exit 130' INT TERM
}

# Call trap setup when logger is sourced
_setup_logger_traps

#===============================================================================
# EXPORT FUNCTIONS FOR EXTERNAL USE
#===============================================================================

# Export all public functions
export -f initiate_logger close_logger validate_logger_config
export -f log_info log_success log_warning log_error log_debug
export -f log_info_header log_important log_note log_tip log_confirmation
export -f log_alert log_caution log_focus log_highlight log_neutral
export -f log_prompt log_status log_verbose log_question log_critical
export -f log_system_info log_script_start log_script_end log_command log_separator

# Mark logger as loaded
export LOGGER_LOADED=true