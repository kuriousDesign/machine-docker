#!/bin/bash
set -e
echo "Updating git submodules..."
git submodule update --remote --merge
echo "Submodules updated."
