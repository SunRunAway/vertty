#!/bin/bash
# Installs the latest Vertty release into /Applications:
#   curl -fsSL https://raw.githubusercontent.com/SunRunAway/vertty/master/scripts/install.sh | bash
#
# The app isn't notarized. A download made with curl doesn't get the quarantine
# flag that makes Gatekeeper block it (browser downloads do).
set -euo pipefail

URL="https://github.com/SunRunAway/vertty/releases/latest/download/Vertty.zip"
DEST="/Applications/Vertty.app"

if [ "$(uname -m)" != "arm64" ]; then
  echo "Vertty releases are built for Apple Silicon only." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading $URL"
curl -fL --progress-bar "$URL" -o "$TMP/Vertty.zip"
ditto -x -k "$TMP/Vertty.zip" "$TMP"
APP="$TMP/Vertty.app"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if pgrep -xq Vertty; then
  echo "Note: Vertty is running. Quit and reopen it to use the new version."
fi
rm -rf "$DEST"
mv "$APP" "$DEST"
echo "Installed $DEST"
