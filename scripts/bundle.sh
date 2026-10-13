#!/bin/bash
# Build Vhostty.app into build/Vhostty.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -f build/ghostty/lib/libghostty.a ] || scripts/build-ghostty.sh

# The macOS 27 SDK turns SwiftUI's @State into a macro whose plugin only ships
# with Xcode, so prefer the macOS 26 SDK from the Command Line Tools.
for sdk in /Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk; do
  if [ -d "$sdk" ]; then export SDKROOT="$sdk"; break; fi
done

# Without Xcode, SwiftPM still adds the XCTest search paths under
# CommandLineTools/Developer, which don't exist; drop ld's warnings about them.
build() {
  swift build -c release --product "$1" 2>&1 \
    | sed "\\#ld: warning: search path '/Library/Developer/CommandLineTools/Developer/#d"
}
build Vhostty
build vhostty-sleep
build vhostty-hook
build vhostty-schedule
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Vhostty.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Release builds stamp the version from the git tag (v1.2.3 -> 1.2.3).
if [ -n "${VHOSTTY_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$VHOSTTY_VERSION" "$APP/Contents/Info.plist"
fi
cp "$BIN/Vhostty" "$APP/Contents/MacOS/Vhostty"
cp "$BIN/vhostty-sleep" "$APP/Contents/MacOS/vhostty-sleep"
cp "$BIN/vhostty-hook" "$APP/Contents/MacOS/vhostty-hook"
cp "$BIN/vhostty-schedule" "$APP/Contents/MacOS/vhostty-schedule"
cp -R Resources/plugin "$APP/Contents/Resources/plugin"
cp Resources/ghostty-defaults.conf "$APP/Contents/Resources/"
cp Resources/vhostty-sleep.sudoers "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/bin/* "$APP/Contents/Resources/bin/"
chmod +x "$APP/Contents/Resources/bin/"*
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ghostty resources: shell integration, themes, terminfo.
cp -R build/ghostty/share/ghostty "$APP/Contents/Resources/ghostty"
cp -R build/ghostty/share/terminfo "$APP/Contents/Resources/terminfo"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "Built $APP"
