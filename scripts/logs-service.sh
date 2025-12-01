#!/usr/bin/env bash

set -e

COMPOSE_FILE="../docker-compose.yml"

# Parse flags and service name
FOLLOW_FLAG=false
TAIL_LINES="all"
SERVICE=""

usage() {
  echo "Usage: $0 <service-name> [-f|--follow] [-n|--tail <lines>]"
  echo ""
  echo "Available services:"
  echo "  ui              - Next.js UI application"
  echo "  bridge          - OPCUA-MQTT bridge"
  echo "  machine-vision  - Vision processing service"
  echo "  mqtt            - Mosquitto MQTT broker"
  echo "  mongodb         - MongoDB database"
  echo ""
  echo "Options:"
  echo "  -f, --follow       Follow log output (live)"
  echo "  -n, --tail <num>   Number of lines to show from end (default: all)"
  echo ""
  echo "Example: $0 ui --follow"
  echo "Example: $0 bridge -f -n 100"
  exit 1
}

# Parse CLI arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -f|--follow)
      FOLLOW_FLAG=true
      ;;
    -n|--tail)
      shift
      TAIL_LINES="$1"
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
LOG_ARGS=""

if [ "$FOLLOW_FLAG" = true ]; then
  LOG_ARGS="$LOG_ARGS -f"
fi

if [ "$TAIL_LINES" != "all" ]; then
  LOG_ARGS="$LOG_ARGS --tail=$TAIL_LINES"
fi

echo "📋 Viewing logs for service: $SERVICE"
echo ""

docker compose -f "$COMPOSE_FILE" logs $LOG_ARGS "$SERVICE"
