#!/bin/bash

# Set TERM if it's not set (for systemd execution)
export TERM=xterm-256color

# Base Directory of the Script
export COMPOSE_DIR="/home/howson/.Docker-Services"

# Change to the base directory
cd $COMPOSE_DIR

# Run the original script
bash ./stop.sh
bash ./start.sh
