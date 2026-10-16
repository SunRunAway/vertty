#!/bin/bash
# Build a zig-compatible copy of the macOS SDK.
#
# Since macOS 26, the SDK .tbd stubs only list arm64e targets, which zig 0.15
# cannot match against aarch64-macos. We clone the SDK (APFS copy-on-write, so
# nearly free) and add arm64-macos next to every arm64e-macos target.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk}"
# Without that SDK (e.g. CI machines with only Xcode), use the default one.
[ -d "$SRC" ] || SRC="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
DST="$ROOT/build/sdk/MacOSX.sdk"
if [ -f "$DST/.vertty-patched" ]; then exit 0; fi
rm -rf "$DST"; mkdir -p "$(dirname "$DST")"
SRC="$(cd "$SRC" && pwd -P)"
cp -Rc "$SRC" "$DST" 2>/dev/null || cp -R "$SRC" "$DST"
find "$DST" -name '*.tbd' -type f -print0 | xargs -0 perl -0pi -e '
  s{\[([^\]]*)\]}{ my $x=$1; $x =~ s/(?<![\w.-])arm64e-macos/arm64-macos, arm64e-macos/g; "[$x]" }ge'
touch "$DST/.vertty-patched"
echo "SDK ready: $DST"
