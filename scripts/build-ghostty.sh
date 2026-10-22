#!/bin/bash
# Build libghostty (static) + its resources into build/ghostty.
# Requires zig 0.15.2 (brew install zig). No Xcode needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/make-zig-sdk.sh"
export VERTTY_ZIG_SDK="$ROOT/build/sdk/MacOSX.sdk"
export PATH="$ROOT/scripts/zig-shim:$PATH"
cd "$ROOT/vendor/ghostty"
# Apply Vertty's patch (runtime shader compilation, static lib + resources on
# macOS, libtool fix) unless it is already applied.
PATCH="$ROOT/patches/ghostty-vertty.patch"
if git apply --reverse --check "$PATCH" 2>/dev/null; then
  :
else
  git apply "$PATCH"
fi
zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=false \
  -Demit-macos-app=false \
  -Di18n=false \
  --prefix "$ROOT/build/ghostty"
cp "$ROOT/build/ghostty/include/ghostty.h" "$ROOT/Sources/GhosttyC/include/ghostty.h"
# Zig never prunes its cache, so every past build stays in it. Clear it once
# it passes 5GB (the current builds alone take about 1.6GB).
if [ "$(du -sk .zig-cache | cut -f1)" -gt $((5 * 1024 * 1024)) ]; then
  rm -rf .zig-cache
fi
echo "libghostty ready: $ROOT/build/ghostty/lib/libghostty.a"
