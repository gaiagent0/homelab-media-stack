#!/bin/bash
# Creates the full /data directory tree required by the media stack.
# Run inside the docker-host LXC (CT302) before first docker compose up.
set -euo pipefail
source "$(dirname "$0")/../.env" 2>/dev/null || true
DATA_PATH=${DATA_PATH:-/mnt/mediastore/data}
DOCKER_VOLUMES=${DOCKER_VOLUMES:-/mnt/mediastore/config}
PUID=${PUID:-1500}
PGID=${PGID:-1500}

mkdir -p \
    "${DATA_PATH}/torrents/movies" \
    "${DATA_PATH}/torrents/tv" \
    "${DATA_PATH}/torrents/music" \
    "${DATA_PATH}/torrents/incomplete" \
    "${DATA_PATH}/movies" \
    "${DATA_PATH}/tv" \
    "${DATA_PATH}/music" \
    "${DOCKER_VOLUMES}/jellyfin" \
    "${DOCKER_VOLUMES}/radarr" \
    "${DOCKER_VOLUMES}/sonarr" \
    "${DOCKER_VOLUMES}/lidarr" \
    "${DOCKER_VOLUMES}/prowlarr" \
    "${DOCKER_VOLUMES}/bazarr" \
    "${DOCKER_VOLUMES}/qbittorrent" \
    "${DOCKER_VOLUMES}/jellyseerr" \
    "${DOCKER_VOLUMES}/tdarr" \
    "${DOCKER_VOLUMES}/homepage"

chown -R "${PUID}:${PGID}" "${DATA_PATH}" "${DOCKER_VOLUMES}"
echo "[OK] Directory structure created under ${DATA_PATH} and ${DOCKER_VOLUMES}"
