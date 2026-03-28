#!/bin/bash
# update-stack.sh — pull latest changes and restart changed containers
# Run on CT302 (docker-host) after pushing changes from dev machine.
# Usage: bash scripts/update-stack.sh
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$STACK_DIR"

echo "[1/3] Pulling latest changes..."
git pull

echo "[2/3] Restarting updated containers..."
docker compose --env-file .env up -d --remove-orphans

echo "[3/3] Stack status:"
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
