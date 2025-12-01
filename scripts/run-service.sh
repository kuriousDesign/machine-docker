#!/usr/bin/env bash

set -e

COMPOSE_FILE="../docker-compose.yml"

# Parse flags and service name
BUILD_FLAG=false
DETACH_FLAG=true
SERVICE=""

usage() {
  echo "Usage: $0 <service-name> [--build] [--fg]"
  echo ""
  echo "Available services:"
  echo "  ui              - Next.js UI application"
  echo "  bridge          - OPCUA-MQTT bridge"
  echo "  machine-vision  - Vision processing service"
  echo "  mqtt            - Mosquitto MQTT broker"
  echo "  mongodb         - MongoDB database"
  echo ""
  echo "Options:"
  echo "  --build        Build the service before running"
  echo "  --fg           Run in foreground (default is background/detached)"
  echo ""
  echo "Example: $0 ui --build"
  exit 1
}

# Parse CLI arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --build)
      BUILD_FLAG=true
      ;;
    --fg|--foreground)
      DETACH_FLAG=false
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

# Build command arguments
RUN_ARGS=""

if [ "$BUILD_FLAG" = true ]; then
  RUN_ARGS="$RUN_ARGS --build"
fi

if [ "$DETACH_FLAG" = true ]; then
  RUN_ARGS="$RUN_ARGS -d"
  echo "🚀 Starting service: $SERVICE (detached)"
else
  echo "🚀 Starting service: $SERVICE (foreground)"
fi

echo "➡ Running: docker compose -f $COMPOSE_FILE up $RUN_ARGS $SERVICE"
echo ""

docker compose -f "$COMPOSE_FILE" up $RUN_ARGS "$SERVICE"

if [ "$DETACH_FLAG" = true ]; then
  echo ""
  echo "✅ Service '$SERVICE' is running in the background."
  echo "💡 Use 'docker compose logs -f $SERVICE' to view logs"
  echo "💡 Use './stop-service.sh $SERVICE' to stop it"
fi
