#!/usr/bin/env bash
set -euo pipefail

# Install devcast
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/verneagent/devcast/main/install.sh | bash
#   curl -fsSL ... | bash -s ~/.local/bin/devcast

DEST="${1:-/usr/local/bin/devcast}"
URL="https://raw.githubusercontent.com/verneagent/devcast/main/devcast.sh"

echo "Installing devcast to $DEST..."

TMPFILE="$(mktemp -t devcast.XXXXXX)"
trap 'rm -f "$TMPFILE"' EXIT

curl -fsSL "$URL" -o "$TMPFILE"
chmod +x "$TMPFILE"

DEST_DIR="$(dirname "$DEST")"
if [[ -w "$DEST_DIR" ]]; then
  mv "$TMPFILE" "$DEST"
else
  echo "(sudo needed for $DEST_DIR)"
  sudo mv "$TMPFILE" "$DEST"
fi

echo "Done. Run: devcast ios list"
