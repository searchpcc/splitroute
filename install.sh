#!/bin/bash
# Remote installer for splitroute
# Usage: curl -fsSL https://raw.githubusercontent.com/searchpcc/splitroute/main/install.sh | bash
set -euo pipefail

REPO="searchpcc/splitroute"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Downloading splitroute..."

if command -v curl &>/dev/null; then
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
        | tar xz -C "$TMP_DIR" --strip-components=1
elif command -v wget &>/dev/null; then
    wget -qO- "https://github.com/$REPO/archive/refs/heads/main.tar.gz" \
        | tar xz -C "$TMP_DIR" --strip-components=1
else
    echo "Error: curl or wget is required"
    exit 1
fi

cd "$TMP_DIR"
bash splitroute-setup.sh
