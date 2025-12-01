#!/usr/bin/env bash

set -e

# Location of the sibling "repos" directory
REPOS_DIR="../repos"

# List of git repositories to clone
# Format: "repo-name git-url"
REPO_LIST=(
  "camera-device git@github.com:your-org/camera-device.git"
  "orchestrator git@github.com:your-org/orchestrator.git"
  "machine-ui git@github.com:your-org/machine-ui.git"
)

mkdir -p "$REOS_DIR"

echo "📦 Cloning missing repositories..."

for entry in "${REPO_LIST[@]}"; do
  NAME=$(echo "$entry" | awk '{print $1}')
  URL=$(echo "$entry" | awk '{print $2}')
  TARGET="$REPOS_DIR/$NAME"

  if [ -d "$TARGET/.git" ]; then
    echo "✔ $NAME already exists — skipping"
    continue
  fi

  echo "➡ Cloning $NAME..."
  git clone "$URL" "$TARGET"
done

echo "✅ Done cloning repositories."
