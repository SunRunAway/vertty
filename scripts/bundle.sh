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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Frameworks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Local builds use the last release version; releases pass their exact tag version.
VERSION="${VERTTY_VERSION:-$(git describe --tags --match 'v[0-9]*' --abbrev=0 | sed 's/^v//')}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: VERTTY_VERSION must be a stable major.minor.patch version" >&2
  exit 1
fi
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/"
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

# Preserve Sparkle's signed helpers. Sign our executables first, then the outer bundle.
for executable in "$APP/Contents/MacOS/"*; do
  codesign --force --sign - "$executable"
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
