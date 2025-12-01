#!/usr/bin/env bash

set -e

COMPOSE_FILE="../docker-compose.yml"

# Parse flags
NO_CACHE=false
PULL_FLAG=false

usage() {
  echo "Usage: $0 [--no-cache] [--pull]"
  echo "  --no-cache     Build images without using Docker cache"
  echo "  --pull         Always attempt to pull newer base images"
  exit 1
}

# Parse CLI flags
while [[ "$#" -gt 0 ]]; do
  case $1 in
    --no-cache)
      NO_CACHE=true
      ;;
    --pull)
      PULL_FLAG=true
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
  shift
done

# Check docker daemon
if ! docker info >/dev/null 2>&1; then
  echo "❌ Docker is not running."
  exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "❌ Cannot find docker-compose.yml at: $COMPOSE_FILE"
  exit 1
fi

echo "🏗  Building all services..."

# Build args
BUILD_ARGS=""

if [ "$NO_CACHE" = true ]; then
  BUILD_ARGS="$BUILD_ARGS --no-cache"
fi

if [ "$PULL_FLAG" = true ]; then
  BUILD_ARGS="$BUILD_ARGS --pull"
fi

echo "➡ Running: docker compose -f $COMPOSE_FILE build $BUILD_ARGS"
echo ""

docker compose -f "$COMPOSE_FILE" build $BUILD_ARGS

echo ""
echo "✅ All Docker images have been built successfully."
