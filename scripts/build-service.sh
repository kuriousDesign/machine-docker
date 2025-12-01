#!/usr/bin/env bash

set -e

COMPOSE_FILE="../docker-compose.yml"

# Parse flags and service name
NO_CACHE=false
PULL_FLAG=false
SERVICE=""

usage() {
  echo "Usage: $0 <service-name> [--no-cache] [--pull]"
  echo ""
  echo "Available services:"
  echo "  ui              - Next.js UI application"
  echo "  bridge          - OPCUA-MQTT bridge"
  echo "  machine-vision  - Vision processing service"
  echo "  mqtt            - Mosquitto MQTT broker"
  echo "  mongodb         - MongoDB database"
  echo ""
  echo "Options:"
  echo "  --no-cache     Build images without using Docker cache"
  echo "  --pull         Always attempt to pull newer base images"
  echo ""
  echo "Example: $0 ui --no-cache"
  exit 1
}

# Parse CLI arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --no-cache)
      NO_CACHE=true
      ;;
    --pull)
      PULL_FLAG=true
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [ -z "$SERVICE" ]; then
        SERVICE="$1"
      else
        echo "Unknown option: $1"
        usage
      fi
      ;;
  esac
  shift
done

# Validate service name provided
if [ -z "$SERVICE" ]; then
  echo "❌ Error: No service name provided"
  usage
fi

# Check docker daemon
if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker is not running."
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "❌ Cannot find docker-compose.yml at: $COMPOSE_FILE"
  exit 1
fi

echo "🏗  Building service: $SERVICE"

# Build args
BUILD_ARGS=""

if [ "$NO_CACHE" = true ]; then
  BUILD_ARGS="$BUILD_ARGS --no-cache"
fi

if [ "$PULL_FLAG" = true ]; then
  BUILD_ARGS="$BUILD_ARGS --pull"
fi

echo "➡ Running: docker compose -f $COMPOSE_FILE build $BUILD_ARGS $SERVICE"
echo ""

docker compose -f "$COMPOSE_FILE" build $BUILD_ARGS "$SERVICE"

echo ""
echo "✅ Service '$SERVICE' has been built successfully."
