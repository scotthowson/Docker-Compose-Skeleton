#!/bin/bash

# Initial Setup Script
echo "Configuring the Docker-Compose environment..."

# Base Directory of the Setup Script
COMPOSE_DIR="/home/howson/.Docker-Services/Stacks"

# Setting executable permissions for the script components
chmod +x "$COMPOSE_DIR/start.sh"
chmod +x "$COMPOSE_DIR/restart-system.sh"
chmod +x "$COMPOSE_DIR/stop.sh"
chmod +x "$COMPOSE_DIR/.lib/"*
chmod +x "$COMPOSE_DIR/.scripts/"*
chmod +x "$COMPOSE_DIR/.config/palette.sh"

chown howson:howson "$COMPOSE_DIR/start.sh"
chown howson:howson "$COMPOSE_DIR/stop.sh"
chown howson:howson "$COMPOSE_DIR/.lib/"*
chown howson:howson "$COMPOSE_DIR/.scripts/"*
chown howson:howson "$COMPOSE_DIR/.config/palette.sh"

echo "Setup completed successfully."
