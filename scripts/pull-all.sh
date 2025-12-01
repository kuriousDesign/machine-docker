#!/usr/bin/env bash

set -e

REPOS_DIR="../repos"

echo "📥 Pulling latest code from all repositories in: $REPOS_DIR"

if [ ! -d "$REPOS_DIR" ]; then
  echo "❌ repos directory does not exist: $REPOS_DIR"
  exit 1
fi

for DIR in "$REPOS_DIR"/*; do
  if [ -d "$DIR/.git" ]; then
    NAME=$(basename "$DIR")
    echo "🔄 Updating $NAME..."
    (
      cd "$DIR"
      git checkout main >/dev/null 2>&1 || true
      git pull --rebase
    )
  else
    echo "⚠ Skipping $DIR (not a git repo)"
  fi
done

echo "✅ All repositories updated."
