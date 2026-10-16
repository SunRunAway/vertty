#!/bin/bash
# Build VerttyKit/CTailnet.xcframework: the Tailscale device Vertty embeds
# (VerttyKit/Tailnet, Go) as a static library for VerttyKit's VerttyTailnet.
# Always for macOS; also for iPhone and the iOS Simulator when Xcode's iOS
# SDKs are installed. Requires Go. Skips the build when the sources haven't
# changed since the last one.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/VerttyKit/Tailnet"
XCF="$ROOT/VerttyKit/CTailnet.xcframework"
OUT="$ROOT/build/tailnet"

if ! command -v go >/dev/null; then
  echo "error: building the Tailscale library needs Go (brew install go)" >&2
  exit 1
fi

ios=0
if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 && xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
  ios=1
fi

stamp="$( (cd "$SRC" && cat go.mod go.sum *.go; go version; echo "ios=$ios") | shasum -a 256 | cut -d' ' -f1)"
if [ -f "$XCF/stamp" ] && [ "$(cat "$XCF/stamp")" = "$stamp" ]; then
  exit 0
fi

# build <xcframework library id> <GOOS> <clang target> [sdk]
build() {
  local id="$1" goos="$2" target="$3" sdk="${4:-}"
  local dir="$OUT/$id" cc
  if [ -n "$sdk" ]; then
    cc="$(xcrun --sdk "$sdk" --find clang) -target $target -isysroot $(xcrun --sdk "$sdk" --show-sdk-path)"
  else
    cc="clang -target $target"
  fi
  echo "Building the Tailscale library for $id"
  mkdir -p "$dir/Headers"
  (cd "$SRC" && CGO_ENABLED=1 GOOS="$goos" GOARCH=arm64 CC="$cc" \
    go build -trimpath -ldflags=-w -buildmode=c-archive -o "$dir/libtailnet.a" .)
  mv "$dir/libtailnet.h" "$dir/Headers/tailnet.h"
  printf 'module CTailnet {\n    header "tailnet.h"\n    export *\n}\n' > "$dir/Headers/module.modulemap"
}

rm -rf "$OUT"
build macos-arm64 darwin arm64-apple-macos14.0
libraries="$(cat <<EOF
    <dict>
      <key>BinaryPath</key><string>libtailnet.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>LibraryIdentifier</key><string>macos-arm64</string>
      <key>LibraryPath</key><string>libtailnet.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>macos</string>
    </dict>
EOF
)"
if [ "$ios" = 1 ]; then
  build ios-arm64 ios arm64-apple-ios17.0 iphoneos
  build ios-arm64-simulator ios arm64-apple-ios17.0-simulator iphonesimulator
  libraries+="$(cat <<EOF

    <dict>
      <key>BinaryPath</key><string>libtailnet.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>LibraryIdentifier</key><string>ios-arm64</string>
      <key>LibraryPath</key><string>libtailnet.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
    </dict>
    <dict>
      <key>BinaryPath</key><string>libtailnet.a</string>
      <key>HeadersPath</key><string>Headers</string>
      <key>LibraryIdentifier</key><string>ios-arm64-simulator</string>
      <key>LibraryPath</key><string>libtailnet.a</string>
      <key>SupportedArchitectures</key><array><string>arm64</string></array>
      <key>SupportedPlatform</key><string>ios</string>
      <key>SupportedPlatformVariant</key><string>simulator</string>
    </dict>
EOF
)"
fi

# Written by hand rather than with xcodebuild -create-xcframework, which
# needs Xcode: the Mac app builds with the Command Line Tools alone.
rm -rf "$XCF"
mkdir -p "$XCF"
for dir in "$OUT"/*/; do cp -R "$dir" "$XCF/$(basename "$dir")"; done
cat > "$XCF/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>
$libraries
  </array>
  <key>CFBundlePackageType</key><string>XFWK</string>
  <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
EOF
echo "$stamp" > "$XCF/stamp"
echo "Tailscale library ready: $XCF"
