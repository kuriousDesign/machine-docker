#!/usr/bin/env bash

set -e

COMPOSE_FILE="../docker-compose.yml"

# Parse service name
SERVICE=""
REMOVE_VOLUMES=false

usage() {
  echo "Usage: $0 <service-name> [--volumes]"
  echo ""
  echo "Available services:"
  echo "  ui              - Next.js UI application"
  echo "  bridge          - OPCUA-MQTT bridge"
  echo "  machine-vision  - Vision processing service"
  echo "  mqtt            - Mosquitto MQTT broker"
  echo "  mongodb         - MongoDB database"
  echo ""
  echo "Options:"
  echo "  --volumes      Remove named volumes declared in the volumes section"
  echo ""
  echo "Example: $0 ui"
  exit 1
}

# Parse CLI arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --volumes|-v)
      REMOVE_VOLUMES=true
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

echo "🛑 Stopping service: $SERVICE"

STOP_ARGS=""
if [ "$REMOVE_VOLUMES" = true ]; then
  STOP_ARGS="$STOP_ARGS -v"
  echo "⚠️  This will also remove volumes"
fi

echo "➡ Running: docker compose -f $COMPOSE_FILE stop $SERVICE"
docker compose -f "$COMPOSE_FILE" stop "$SERVICE"

echo "➡ Running: docker compose -f $COMPOSE_FILE rm -f $STOP_ARGS $SERVICE"
docker compose -f "$COMPOSE_FILE" rm -f $STOP_ARGS "$SERVICE"

echo ""
echo "✅ Service '$SERVICE' has been stopped and removed."
