#!/bin/bash
# Logger.sh - Provides enhanced logging functionalities for Bash scripts

# Initializes the logger by clearing the log file
initiate_logger() {
    if [[ -z $LOGGER_INITIALIZED ]]; then
        > "$LOG_FILE"  # Clear the log file only if not already initialized
        log_nodate_success "Logger Initialized."
        export LOGGER_INITIALIZED=true
    fi
}

# Core Logging Function
log_event() {
    local original_mood=$1
    local narrative=$2
    local mood=$original_mood
    local is_bold=false
    local is_nodate=false
    local is_custom=false
    local is_verbose=false
    local is_debug=false

    # Extracting flags from the mood
    if [[ $mood == "BOLD_"* ]]; then
        is_bold=true
        mood="${mood#BOLD_}"
    fi
    if [[ $mood == "NODATE_"* ]]; then
        is_nodate=true
        mood="${mood#NODATE_}"
    fi
    if [[ $mood == "CUSTOM_"* ]]; then
        is_custom=true
        mood="${mood#CUSTOM_}"
    fi
    if [[ $mood == "VERBOSE_"* ]]; then
        is_verbose=true
        mood="${mood#VERBOSE_}"
    fi
    if [[ "$LOG_LEVEL" == "DEBUG" ]]; then
        is_debug=true
    fi

    # Apply debug and verbose color based on settings.cfg for console output
    local debug_color_console="${COLOR_DEBUG}"
    local verbose_color_console="${COLOR_VERBOSE}"
    local debug_prefix_console=""
    local verbose_prefix_console=""

    if [[ "$VERBOSE_MODE" == true ]]; then
        verbose_prefix_console="${verbose_color_console}[VERBOSE]\033[0m "
    fi
    if [[ "$is_debug" == true ]]; then
        debug_prefix_console="${debug_color_console}[DEBUG]\033[0m "
    fi

    # Apply color and possibly bold style based on mood for console output
    local style_console="${COLOR_PALETTE[$mood]}"
    local mood_style_console="${COLOR_PALETTE[$mood]}"
    [[ "$is_bold" == true ]] && mood_style_console="\033[1m${mood_style_console}"

    # Constructing console prefixes
    local console_prefix=""
    local logfile_prefix=""
    if [[ "$ENABLE_LOG_DATE" == true && "$is_nodate" == false ]]; then
        logfile_prefix="[$(date '+%b/%d/%Y — %-l:%M %p')]"
    fi
    console_prefix="$logfile_prefix"

    # Handling custom, mood, and INFO_HEADER prefixes for console
    if [[ "$ENABLE_CUSTOM_LOG_PREFIX" == true && "$is_custom" == true ]]; then
        case $mood in
            "CUSTOM_PREFIX_1") 
                console_prefix="[$LOG_PREFIX_1]${console_prefix}${mood_style_console}"
                logfile_prefix="${logfile_prefix}[$LOG_PREFIX_1]"  # Apply custom log prefix for logfile
                ;;
            "CUSTOM_PREFIX_2") 
                console_prefix="[$LOG_PREFIX_2]${console_prefix}${mood_style_console}"
                logfile_prefix="${logfile_prefix}[$LOG_PREFIX_2]"  # Apply custom log prefix for logfile
                ;;
            "CUSTOM_PREFIX_3") 
                console_prefix="[$LOG_PREFIX_3]${console_prefix}${mood_style_console}"
                logfile_prefix="${logfile_prefix}[$LOG_PREFIX_3]"  # Apply custom log prefix for logfile
                ;;
            *) 
                console_prefix="[$CUSTOM_LOG_PREFIX]${console_prefix}${mood_style_console}"
                logfile_prefix="${logfile_prefix}[$CUSTOM_LOG_PREFIX]"  # Apply custom log prefix for logfile
                ;;
        esac
    elif [[ "$mood" == "INFO_HEADER" ]]; then
        if [[ "$ENABLE_INFO_HEADER" == true ]]; then
            local info_header_color="${COLOR_INFO_HEADER}"
            if [[ "$USE_CUSTOM_INFO_HEADER" == true ]]; then
                console_prefix="${info_header_color}${CUSTOM_INFO_HEADER_TEXT}\033[0m"
                logfile_prefix="${logfile_prefix}${CUSTOM_INFO_HEADER_TEXT}"  # No separator for logfile
            else
                console_prefix="${info_header_color}[INFO_HEADER]\033[0m"
                logfile_prefix="${logfile_prefix}[INFO_HEADER]"  # No separator for logfile
            fi
        fi
    else
        console_prefix="${console_prefix}${mood_style_console}[$mood]"
        logfile_prefix="${logfile_prefix}[$mood]"
    fi

    # Logfile prefix (without color codes)
    local verbose_prefix_logfile=""
    local debug_prefix_logfile=""
    if [[ "$VERBOSE_MODE" == true ]]; then
        verbose_prefix_logfile="[VERBOSE] "
    fi
    if [[ "$is_debug" == true ]]; then
        debug_prefix_logfile="[DEBUG] "
    fi

    # Add separator if there is a prefix section
    local separator=""
    [[ -n "$console_prefix" ]] && console_prefix="${console_prefix} - "
    [[ -n "$logfile_prefix" ]] && logfile_prefix="${logfile_prefix} - "

    # Constructing and displaying the console message with color
    local console_message="${verbose_prefix_console}${debug_prefix_console}${console_prefix}${separator}${style_console}${narrative}${COLOR_PALETTE[RESET]}"
    echo -e "$console_message"

    # Constructing and displaying the log message without color
    local logfile_message="${verbose_prefix_logfile}${debug_prefix_logfile}${logfile_prefix}${separator}${narrative}"
    echo "$logfile_message" >> "$LOG_FILE"
}

# Standard Log Level Functions
log_info() { log_event "INFO" "$1"; }
log_success() { log_event "SUCCESS" "$1"; }
log_warning() { log_event "WARNING" "$1"; }
log_error() { log_event "ERROR" "$1"; }
log_info_header() { log_event "INFO_HEADER" "$1"; }
log_important() { log_event "IMPORTANT" "$1"; }
log_note() { log_event "NOTE" "$1"; }
log_tip() { log_event "TIP" "$1"; }
log_debug() { log_event "DEBUG" "$1"; }
log_confirmation() { log_event "CONFIRMATION" "$1"; }
log_alert() { log_event "ALERT" "$1"; }
log_caution() { log_event "CAUTION" "$1"; }
log_focus() { log_event "FOCUS" "$1"; }
log_highlight() { log_event "HIGHLIGHT" "$1"; }
log_neutral() { log_event "NEUTRAL" "$1"; }
log_prompt() { log_event "PROMPT" "$1"; }
log_status() { log_event "STATUS" "$1"; }
log_verbose() { log_event "VERBOSE" "$1"; }
log_question() { log_event "QUESTION" "$1"; }

# Bold Log Level Variants
log_bold_info() { log_event "BOLD_INFO" "$1"; }
log_bold_success() { log_event "BOLD_SUCCESS" "$1"; }
log_bold_warning() { log_event "BOLD_WARNING" "$1"; }
log_bold_error() { log_event "BOLD_ERROR" "$1"; }
log_bold_important() { log_event "BOLD_IMPORTANT" "$1"; }
log_bold_note() { log_event "BOLD_NOTE" "$1"; }
log_bold_tip() { log_event "BOLD_TIP" "$1"; }
log_bold_debug() { log_event "BOLD_DEBUG" "$1"; }
log_bold_confirmation() { log_event "BOLD_CONFIRMATION" "$1"; }
log_bold_alert() { log_event "BOLD_ALERT" "$1"; }
log_bold_caution() { log_event "BOLD_CAUTION" "$1"; }
log_bold_focus() { log_event "BOLD_FOCUS" "$1"; }
log_bold_highlight() { log_event "BOLD_HIGHLIGHT" "$1"; }
log_bold_neutral() { log_event "BOLD_NEUTRAL" "$1"; }
log_bold_prompt() { log_event "BOLD_PROMPT" "$1"; }
log_bold_status() { log_event "BOLD_STATUS" "$1"; }
log_bold_verbose() { log_event "BOLD_VERBOSE" "$1"; }
log_bold_question() { log_event "BOLD_QUESTION" "$1"; }

# No-Date Log Level Variants
log_nodate_info() { log_event "NODATE_INFO" "$1"; }
log_nodate_success() { log_event "NODATE_SUCCESS" "$1"; }
log_nodate_warning() { log_event "NODATE_WARNING" "$1"; }
log_nodate_error() { log_event "NODATE_ERROR" "$1"; }
log_nodate_info_header() { log_event "NODATE_INFO_HEADER" "$1"; }
log_nodate_important() { log_event "NODATE_IMPORTANT" "$1"; }
log_nodate_note() { log_event "NODATE_NOTE" "$1"; }
log_nodate_tip() { log_event "NODATE_TIP" "$1"; }
log_nodate_debug() { log_event "NODATE_DEBUG" "$1"; }
log_nodate_confirmation() { log_event "NODATE_CONFIRMATION" "$1"; }
log_nodate_alert() { log_event "NODATE_ALERT" "$1"; }
log_nodate_caution() { log_event "NODATE_CAUTION" "$1"; }
log_nodate_focus() { log_event "NODATE_FOCUS" "$1"; }
log_nodate_highlight() { log_event "NODATE_HIGHLIGHT" "$1"; }
log_nodate_neutral() { log_event "NODATE_NEUTRAL" "$1"; }
log_nodate_prompt() { log_event "NODATE_PROMPT" "$1"; }
log_nodate_status() { log_event "NODATE_STATUS" "$1"; }
log_nodate_verbose() { log_event "NODATE_VERBOSE" "$1"; }
log_nodate_question() { log_event "NODATE_QUESTION" "$1"; }

# Bold No-Date Log Level Variants
log_bold_nodate_info() { log_event "BOLD_NODATE_INFO" "$1"; }
log_bold_nodate_success() { log_event "BOLD_NODATE_SUCCESS" "$1"; }
log_bold_nodate_warning() { log_event "BOLD_NODATE_WARNING" "$1"; }
log_bold_nodate_error() { log_event "BOLD_NODATE_ERROR" "$1"; }
log_bold_nodate_info_header() { log_event "BOLD_NODATE_INFO_HEADER" "$1"; }
log_bold_nodate_important() { log_event "BOLD_NODATE_IMPORTANT" "$1"; }
log_bold_nodate_note() { log_event "BOLD_NODATE_NOTE" "$1"; }
log_bold_nodate_tip() { log_event "BOLD_NODATE_TIP" "$1"; }
log_bold_nodate_debug() { log_event "BOLD_NODATE_DEBUG" "$1"; }
log_bold_nodate_confirmation() { log_event "BOLD_NODATE_CONFIRMATION" "$1"; }
log_bold_nodate_alert() { log_event "BOLD_NODATE_ALERT" "$1"; }
log_bold_nodate_caution() { log_event "BOLD_NODATE_CAUTION" "$1"; }
log_bold_nodate_focus() { log_event "BOLD_NODATE_FOCUS" "$1"; }
log_bold_nodate_highlight() { log_event "BOLD_NODATE_HIGHLIGHT" "$1"; }
log_bold_nodate_neutral() { log_event "BOLD_NODATE_NEUTRAL" "$1"; }
log_bold_nodate_prompt() { log_event "BOLD_NODATE_PROMPT" "$1"; }
log_bold_nodate_status() { log_event "BOLD_NODATE_STATUS" "$1"; }
log_bold_nodate_verbose() { log_event "BOLD_NODATE_VERBOSE" "$1"; }
log_bold_nodate_question() { log_event "BOLD_NODATE_QUESTION" "$1"; }

# Custom Mood Type Logging Functions
log_custom_prefix_1() { log_event "BOLD_NODATE_CUSTOM_CUSTOM_PREFIX_1" "$1"; }
log_custom_prefix_2() { log_event "BOLD_NODATE_CUSTOM_CUSTOM_PREFIX_2" "$1"; }
log_custom_prefix_3() { log_event "BOLD_NODATE_CUSTOM_CUSTOM_PREFIX_3" "$1"; }
