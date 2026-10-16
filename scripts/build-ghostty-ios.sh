#!/bin/bash
# Build GhosttyKit.xcframework (iPhone + iOS Simulator) for the iOS app from
# the same Ghostty source and patch as the Mac app (see build-ghostty.sh),
# into iOS/GhosttyTerminal/GhosttyKit.xcframework. Requires zig 0.15.2 and
# Xcode (for the iOS SDKs and xcodebuild -create-xcframework).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/make-zig-sdk.sh"
export VERTTY_ZIG_SDK="$ROOT/build/sdk/MacOSX.sdk"
export PATH="$ROOT/scripts/zig-shim:$PATH"
cd "$ROOT/vendor/ghostty"
PATCH="$ROOT/patches/ghostty-vertty.patch"
if git apply --reverse --check "$PATCH" 2>/dev/null; then
  :
else
  git apply "$PATCH"
fi

OUT="$ROOT/build/ghostty-ios"
for variant in "iphoneos aarch64-ios" "iphonesimulator aarch64-ios-simulator"; do
  set -- $variant
  # The simulator needs an explicit Apple CPU (see GhosttyXCFramework.zig).
  zig build \
    -Doptimize=ReleaseFast \
    -Dtarget="$2" \
    -Dcpu=apple_a17 \
    -Dapp-runtime=none \
    -Demit-xcframework=false \
    -Demit-macos-app=false \
    -Di18n=false \
    --prefix "$OUT/$1"
  # The Swift package imports the header as module `libghostty`.
  headers="$OUT/$1/headers/libghostty"
  rm -rf "$OUT/$1/headers"
  mkdir -p "$headers"
  cp "$OUT/$1/include/ghostty.h" "$headers/"
  printf 'module libghostty {\n    umbrella header "ghostty.h"\n    export *\n}\n' > "$headers/module.modulemap"
done

XCF="$ROOT/iOS/GhosttyTerminal/GhosttyKit.xcframework"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$OUT/iphoneos/lib/libghostty.a" -headers "$OUT/iphoneos/headers" \
  -library "$OUT/iphonesimulator/lib/libghostty.a" -headers "$OUT/iphonesimulator/headers" \
  -output "$XCF"
echo "GhosttyKit ready: $XCF"
