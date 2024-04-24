
# Docker Compose Environment Setup

This repository contains a Docker Compose setup organized into various categories for easy management and scalability. Each category has its own `docker-compose.yml` and `.env` files for specific configurations.

## Directory Structure

The project is organized into several directories under `./docker-compose`, each representing a specific category:

- **core-infrastructure**: For core services like databases.
- **media-services**: For media-related services like Plex.
- **web-applications**: For web-facing services like NextCloud.
- **monitoring-management**: For monitoring and management tools like Grafana.
- **networking-security**: For networking and security services like Traefik.
- **development-tools**: For development tools like ElasticSearch.
- **communication-collaboration**: For communication services like MailServer.
- **storage-backup**: For storage and backup services.
- **entertainment-personal**: For personal services like Spotify.
- **miscellaneous-services**: For miscellaneous tools and services.

Each directory contains a `docker-compose.yml` and an `.env` file.

## Configuration

### Environment Variables

Each service category has its own `.env` file which contains environment variables relevant to the services within that category. Update these `.env` files with your specific settings:

1. Navigate to each directory:
   ```bash
   cd docker-compose/<category-name>
   ```
2. Edit the `.env` file:
   ```bash
   nano .env
   ```

### Editing Docker Compose Files

If you need to customize the services, you can edit the `docker-compose.yml` files in each category directory:

```bash
nano docker-compose/<category-name>/docker-compose.yml
```

## Running the Services

A shell script `run.sh` is provided at the root of the project to start up all the services across categories. Here’s how to use it:

### Making the Script Executable

First, ensure that the script is executable:

```bash
chmod +x run.sh
```

### Running the Script

Execute the script to start all the services:

```bash
./run.sh
```

The script will automatically pull the necessary Docker images, start the containers, and log all output to `Docker.log`.

## Logging

All output from the Docker containers managed by the `run.sh` script is logged to `Docker.log`, located at:

```plaintext
/home/howson/.docker-compose/Docker.log
```

Check this file for any errors or messages from the Docker containers.

## Help and Support

For additional help or to report issues, please file an issue in this GitHub repository.

---

This setup is designed to be flexible and scalable, accommodating a wide range of applications and services within a Dockerized environment. Whether you're managing a complex multi-service application or just experimenting with Docker, this structure aims to provide a clear and manageable approach to Docker Compose configurations.
