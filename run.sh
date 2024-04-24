#!/bin/bash

# Define the base directory for Docker Compose files
BASE_DIR="CHANGEME/.docker-compose"

# Log file location
LOG_FILE="CHANGEME/.docker-compose/Docker.log"

# Start all services with specific .env files
docker-compose --env-file $BASE_DIR/core-infrastructure/.env -f $BASE_DIR/core-infrastructure/docker-compose.yml \
               --env-file $BASE_DIR/media-services/.env -f $BASE_DIR/media-services/docker-compose.yml \
               --env-file $BASE_DIR/web-applications/.env -f $BASE_DIR/web-applications/docker-compose.yml \
               --env-file $BASE_DIR/monitoring-management/.env -f $BASE_DIR/monitoring-management/docker-compose.yml \
               --env-file $BASE_DIR/networking-security/.env -f $BASE_DIR/networking-security/docker-compose.yml \
               --env-file $BASE_DIR/development-tools/.env -f $BASE_DIR/development-tools/docker-compose.yml \
               --env-file $BASE_DIR/communication-collaboration/.env -f $BASE_DIR/communication-collaboration/docker-compose.yml \
               --env-file $BASE_DIR/storage-backup/.env -f $BASE_DIR/storage-backup/docker-compose.yml \
               --env-file $BASE_DIR/entertainment-personal/.env -f $BASE_DIR/entertainment-personal/docker-compose.yml \
               --env-file $BASE_DIR/miscellaneous-services/.env -f $BASE_DIR/miscellaneous-services/docker-compose.yml \
               up -d

# Check if Docker Compose succeeded
if [ $? -eq 0 ]; then
    echo "Docker Compose started successfully." >> $LOG_FILE
else
    echo "Error starting Docker Compose. Check $LOG_FILE for details." >&2
    exit 1
fi
