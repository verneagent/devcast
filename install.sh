#!/usr/bin/env bash
set -euo pipefail

# Install devcast to /usr/local/bin
# Usage: curl -fsSL https://raw.githubusercontent.com/verneagent/devcast/main/install.sh | bash

DEST="${1:-/usr/local/bin/devcast}"
URL="https://raw.githubusercontent.com/verneagent/devcast/main/devcast.sh"

echo "Downloading devcast..."
curl -fsSL "$URL" -o "$DEST"
chmod +x "$DEST"

echo "devcast installed to $DEST"
echo "Run: devcast ios list"
