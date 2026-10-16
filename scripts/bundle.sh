#!/bin/bash
# Build Vertty.app into build/Vertty.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -f build/ghostty/lib/libghostty.a ] || scripts/build-ghostty.sh
# The embedded Tailscale device (Go); skipped when its sources are unchanged.
scripts/build-tailnet.sh

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
build Vertty
build vertty-sleep
build vertty-hook
build vertty-schedule
BIN="$(swift build -c release --show-bin-path)"

APP="$ROOT/build/Vertty.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Release builds stamp the version from the git tag (v1.2.3 -> 1.2.3).
if [ -n "${VERTTY_VERSION:-}" ]; then
  plutil -replace CFBundleShortVersionString -string "$VERTTY_VERSION" "$APP/Contents/Info.plist"
fi
cp "$BIN/Vertty" "$APP/Contents/MacOS/Vertty"
cp "$BIN/vertty-sleep" "$APP/Contents/MacOS/vertty-sleep"
cp "$BIN/vertty-hook" "$APP/Contents/MacOS/vertty-hook"
cp "$BIN/vertty-schedule" "$APP/Contents/MacOS/vertty-schedule"
# SwiftPM resource bundles of VerttyKit (the shared code's translations).
cp -R "$BIN"/VerttyKit_*.bundle "$APP/Contents/Resources/"
cp Resources/ghostty-defaults.conf "$APP/Contents/Resources/"
cp Resources/vertty-sleep.sudoers "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/bin/* "$APP/Contents/Resources/bin/"
chmod +x "$APP/Contents/Resources/bin/"*
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Ghostty resources: shell integration, themes, terminfo.
cp -R build/ghostty/share/ghostty "$APP/Contents/Resources/ghostty"
cp -R build/ghostty/share/terminfo "$APP/Contents/Resources/terminfo"

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc codesign failed"
echo "Built $APP"
