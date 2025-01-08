#!/bin/bash
# Color Palette Script
# This script defines a color palette using `tput` commands for enhanced logging and styling in Bash scripts.

# Load Custom Colors from Settings
# Ensure that settings.cfg is available in the specified path.
if [ -f "./.config/settings.cfg" ]; then
    source ./.config/settings.cfg
else
    echo "Error: settings.cfg not found. Please check the path."
    exit 1
fi

# Define Color Palette using `tput`
# Basic colors
declare -A COLOR_PALETTE=(
    [BLACK]=$(tput setaf 0)
    [RED]=$(tput setaf 1)
    [GREEN]=$(tput setaf 2)
    [YELLOW]=$(tput setaf 3)
    [BLUE]=$(tput setaf 4)
    [PURPLE]=$(tput setaf 5)
    [CYAN]=$(tput setaf 6)
    [WHITE]=$(tput setaf 7)
)

# Extended Colors from settings.cfg
# Custom color assignments for specific log types
COLOR_PALETTE[INFO]="$COLOR_INFO"
COLOR_PALETTE[INFO_HEADER]="$COLOR_INFO_HEADER"
COLOR_PALETTE[IMPORTANT]="$COLOR_IMPORTANT"
COLOR_PALETTE[NOTE]="$COLOR_NOTE"
COLOR_PALETTE[TIP]="$COLOR_TIP"
COLOR_PALETTE[CONFIRMATION]="$COLOR_CONFIRMATION"
COLOR_PALETTE[SUCCESS]="$COLOR_SUCCESS"
COLOR_PALETTE[WARNING]="$COLOR_WARNING"
COLOR_PALETTE[ERROR]="$COLOR_ERROR"
COLOR_PALETTE[DEBUG]="$COLOR_DEBUG"
COLOR_PALETTE[VERBOSE]="$COLOR_VERBOSE"
COLOR_PALETTE[QUESTION]="$COLOR_QUESTION"
COLOR_PALETTE[CAUTION]="$COLOR_CAUTION"
COLOR_PALETTE[FOCUS]="$COLOR_FOCUS"
COLOR_PALETTE[STATUS]="$COLOR_STATUS"
COLOR_PALETTE[HIGHLIGHT]="$COLOR_HIGHLIGHT"
COLOR_PALETTE[NEUTRAL]="$COLOR_NEUTRAL"
COLOR_PALETTE[ALERT]="$COLOR_ALERT"

# Reset color
COLOR_PALETTE[RESET]=$(tput sgr0)

# Add Bold Variants to the Palette
# Applying bold formatting to basic colors
for color in BLACK RED GREEN YELLOW BLUE PURPLE CYAN WHITE; do
    COLOR_PALETTE["BOLD_$color"]="$(tput bold)${COLOR_PALETTE[$color]}"
done

# Script can be sourced in other scripts to utilize the defined color palette.
