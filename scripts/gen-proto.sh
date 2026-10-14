#!/bin/bash
# Regenerate RemoteKit/Sources/VhosttyRemote/Generated from the .proto file.
# Downloads protoc and builds protoc-gen-swift (the version the package pins)
# into build/tools the first time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROTOC_VERSION=29.3
SWIFT_PROTOBUF_VERSION=1.28.2
TOOLS="$ROOT/build/tools"
mkdir -p "$TOOLS"

PROTOC="$TOOLS/protoc-$PROTOC_VERSION/bin/protoc"
if [ ! -x "$PROTOC" ]; then
  curl -sSL -o "$TOOLS/protoc.zip" \
    "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/protoc-$PROTOC_VERSION-osx-aarch_64.zip"
  rm -rf "$TOOLS/protoc-$PROTOC_VERSION"
  unzip -q "$TOOLS/protoc.zip" -d "$TOOLS/protoc-$PROTOC_VERSION"
  rm "$TOOLS/protoc.zip"
fi

PLUGIN="$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION/.build/release/protoc-gen-swift"
if [ ! -x "$PLUGIN" ]; then
  rm -rf "$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION"
  git clone -q --depth 1 --branch "$SWIFT_PROTOBUF_VERSION" \
    https://github.com/apple/swift-protobuf "$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION"
  (cd "$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION" && swift build -c release --product protoc-gen-swift)
fi

OUT="$ROOT/RemoteKit/Sources/VhosttyRemote/Generated"
"$PROTOC" --plugin=protoc-gen-swift="$PLUGIN" \
  --swift_out="$OUT" --swift_opt=Visibility=Public \
  -I "$ROOT/RemoteKit/Proto" "$ROOT/RemoteKit/Proto/vhostty_remote.proto"
echo "Generated $OUT/vhostty_remote.pb.swift"
