#!/bin/bash
# Builds the myDrive macOS app: Rust core (release) + Swift shell, assembled
# into the machine's cache folder. Paths derive from this script's location.
#
#   Mac/build.sh              build only
#   Mac/build.sh --run        build and launch
#   Mac/build.sh --diagnose [dir]   build and run the self-test into dir
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_ROOT="${OSEAN_STUDIO_DATA:-$HOME/Library/Caches/myDrive}"
BUILD_DIR="${MYDRIVE_BUILD_DIR:-$CACHE_ROOT/Build Cache/myDrive macOS}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
APP="$BUILD_DIR/myDrive.app"
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) TARGET="arm64-apple-macos14.0"; RUST_TARGET="aarch64-apple-darwin" ;;
  x86_64) TARGET="x86_64-apple-macos14.0"; RUST_TARGET="x86_64-apple-darwin" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

echo "==> Building the Rust core (release)"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$CACHE_ROOT/Build Cache/myDrive Core}"
mkdir -p "$CARGO_TARGET_DIR"
export CARGO_TARGET_DIR="$(cd "$CARGO_TARGET_DIR" && pwd)"
export CARGO_INCREMENTAL=0
cargo build --release --locked --target "$RUST_TARGET" --manifest-path "$ROOT/Core/Cargo.toml"
CORE_BINARY="$CARGO_TARGET_DIR/$RUST_TARGET/release/mydrive-core"

echo "==> Compiling the Swift shell ($TARGET)"
mkdir -p "$BUILD_DIR"
BIN="$BUILD_DIR/myDrive-bin"
SOURCES=()
while IFS= read -r -d '' source; do SOURCES+=("$source"); done < <(find "$SCRIPT_DIR/App/Sources" -name '*.swift' ! -name '._*' -print0)
swiftc -O -swift-version 5 -target "$TARGET" "${SOURCES[@]}" -o "$BIN"

echo "==> Assembling myDrive.app"
[[ "$BUILD_DIR" != / && "$APP" == "$BUILD_DIR/myDrive.app" ]] || exit 1
rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/myDrive"
cp "$CORE_BINARY" "$APP/Contents/Resources/mydrive-core"
echo "==> Building the private SMB host"
(cd "$ROOT/Core/SmbHost" && CGO_ENABLED=0 GOTOOLCHAIN=local go run build.go "$APP/Contents/MacOS")
mv "$APP/Contents/MacOS/SMB-ThirdPartyNotices.txt" "$APP/Contents/Resources/SMB-ThirdPartyNotices.txt"
cp "$SCRIPT_DIR/App/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$SCRIPT_DIR/App/Resources/myDrive.png" "$APP/Contents/Resources/myDrive.png"
cp "$SCRIPT_DIR/App/Resources/StatusMark.png" "$APP/Contents/Resources/StatusMark.png"
node "$ROOT/Core/third-party-notices.mjs" "$ROOT/Core/Cargo.toml" "$APP/Contents/Resources/ThirdPartyNotices.txt"
if [[ "${MYDRIVE_DEVELOPMENT_PROJECT_ROOT:-0}" == 1 ]]; then
    printf '%s\n' "$ROOT" > "$APP/Contents/Resources/project-root.txt"
fi
ICONSET="$BUILD_DIR/myDrive.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SCRIPT_DIR/App/Resources/myDrive.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SCRIPT_DIR/App/Resources/myDrive.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/myDrive.icns"
chmod 755 "$APP/Contents/MacOS/myDrive" "$APP/Contents/Resources/mydrive-core"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP/Contents/Resources/mydrive-core" >/dev/null
codesign --force --sign - "$APP/Contents/MacOS/mydrive-smb-host" >/dev/null
codesign --force --sign - "$APP" >/dev/null

echo "Built: $APP"
case "${1:-}" in
  --run)
    open "$APP"
    ;;
  --diagnose)
    OUTPUT="${2:-/tmp/mydrive-diagnose}"
    mkdir -p "$OUTPUT"
    "$APP/Contents/MacOS/myDrive" --diagnose "$OUTPUT"
    ;;
esac
