#!/bin/bash

# Define the base directory for Docker Compose files
BASE_DIR="CHANGEME/.docker-compose"

# Log file location
LOG_FILE="CHANGEME/.docker-compose/Docker.log"

# Start all services with specific .env files
docker-compose --env-file $BASE_DIR/core/.env -f $BASE_DIR/core/docker-compose.yml \
               --env-file $BASE_DIR/development/.env -f $BASE_DIR/development/docker-compose.yml \
               --env-file $BASE_DIR/misc/.env -f $BASE_DIR/misc/docker-compose.yml \
               --env-file $BASE_DIR/media/.env -f $BASE_DIR/media/docker-compose.yml \
               --env-file $BASE_DIR/utilities/.env -f $BASE_DIR/utilities/docker-compose.yml \
               --env-file $BASE_DIR/web/.env -f $BASE_DIR/web/docker-compose.yml \
               up -d

# Check if Docker Compose succeeded
if [ $? -eq 0 ]; then
    echo "Docker Compose started successfully." >> $LOG_FILE
else
    echo "Error starting Docker Compose. Check $LOG_FILE for details." >&2
    exit 1
fi