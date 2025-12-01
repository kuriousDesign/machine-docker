#!/bin/bash
set -e
echo "Tearing down environment..."
docker compose down -v
echo "Pruning images and cache..."
docker system prune -af
echo "Environment reset complete."
