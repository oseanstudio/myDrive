#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

: "${MYDRIVE_BUILD_DIR:?Set an absolute directory for Linux build output}"
: "${CARGO_TARGET_DIR:?Set an absolute Cargo build output directory}"
[[ $MYDRIVE_BUILD_DIR = /* && $CARGO_TARGET_DIR = /* ]]
mkdir -p "$MYDRIVE_BUILD_DIR"
build=$(mktemp -d "$MYDRIVE_BUILD_DIR/build.XXXXXX")
appdir="$build/myDrive.AppDir"

download() {
    local url=$1 file=$2 hash=$3
    curl --fail --silent --show-error --location --retry 2 --max-time 120 "$url" --output "$file"
    printf '%s  %s\n' "$hash" "$file" | sha256sum --check
}

download https://static.blip.net/linux/blip-1.2.8-linux-amd64.tar.gz "$build/blip.tar.gz" \
    59fd1020f7f193aae4373f45f39bf39e9e3337bf0af6ede91bdb1c8e4c1ac463
tar -xOf "$build/blip.tar.gz" blip-1.2.8/lib/runtime/lib/libblip-jni.so > "$build/libblip-jni.so"

cargo test --locked --manifest-path Core/Cargo.toml
MYDRIVE_BLIP_LIBRARY="$build/libblip-jni.so" \
    cargo test --locked --manifest-path Core/Cargo.toml private_host_starts_without_java -- --ignored
cargo build --release --locked --manifest-path Core/Cargo.toml
install -Dm755 "$CARGO_TARGET_DIR/release/mydrive-core" "$appdir/usr/bin/mydrive-core"
(cd Core/SmbHost && CGO_ENABLED=0 GOTOOLCHAIN=local go run build.go "$appdir/usr/bin")
install -d "$appdir/usr/share/doc/mydrive" "$appdir/usr/lib/mydrive"
mv "$appdir/usr/bin/SMB-ThirdPartyNotices.txt" "$appdir/usr/share/doc/mydrive/"
node Core/third-party-notices.mjs Core/Cargo.toml "$appdir/usr/share/doc/mydrive/ThirdPartyNotices.txt"
install -m644 Linux/packaging/AppImage-Runtime.txt "$appdir/usr/share/doc/mydrive/AppImage-Runtime.txt"
install -Dm755 Linux/packaging/AppRun.sh "$appdir/AppRun"
install -m644 Linux/{mydrive,services,airdrop,blip_cli,cloud_view,file_manager,storage_view,smb_sharing,transfer_view,tray,ui_widgets}.py "$appdir/usr/lib/mydrive/"
if [[ -n "${MYDRIVE_VERSION:-}" ]]; then
    printf '%s\n' "$MYDRIVE_VERSION" > "$appdir/usr/lib/mydrive/version.txt"
fi
install -Dm644 Linux/packaging/net.oseanstudio.myDrive.desktop "$appdir/net.oseanstudio.myDrive.desktop"
install -Dm644 Mac/App/Resources/myDrive.png "$appdir/net.oseanstudio.myDrive.png"
install -m644 Mac/App/Resources/myDrive.png "$appdir/usr/lib/mydrive/net.oseanstudio.myDrive.png"
desktop-file-validate "$appdir/net.oseanstudio.myDrive.desktop"

download https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage "$build/appimagetool.AppImage" \
    ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
download https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64 "$build/runtime-x86_64" \
    617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46
chmod +x "$build/appimagetool.AppImage"
output="$MYDRIVE_BUILD_DIR/myDrive-Linux-x86_64.AppImage"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$build/appimagetool.AppImage" --no-appstream \
    --runtime-file "$build/runtime-x86_64" "$appdir" "$output"

export XDG_DATA_HOME="$build/fixture-data"
export APPIMAGE_EXTRACT_AND_RUN=1
if [[ -n "${MYDRIVE_VERSION:-}" ]]; then
    test "$("$output" --version)" = "$MYDRIVE_VERSION"
fi
printf '%s\n' '{"action":"version"}' | "$output" --core | python3 -c 'import json,sys; assert json.load(sys.stdin)["ok"]'
node tests/automation-smoke.mjs "$output" --cli
node tests/syncthing-owner.mjs "$output" --core
node tests/cloud-drives.mjs "$output" --core
fixture=$(mktemp -d /tmp/md-blip.XXXXXX)
if ! MYDRIVE_BLIP_LIBRARY="$build/libblip-jni.so" XDG_RUNTIME_DIR="$fixture" \
        XDG_DATA_HOME="$fixture/data" timeout 25s "$output" --cli blip serve </dev/null; then
    exit 1
fi
timeout 30s dbus-run-session -- xvfb-run -a "$output" --smoke-test
/usr/bin/python3 -B - "$appdir/usr/lib/mydrive" "$build" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, sys.argv[1])
from file_manager import install_actions

build = Path(sys.argv[2])
launcher = build / "myDrive with spaces & 100%.AppImage"
launcher.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
launcher.chmod(0o700)
profile = build / "file-manager-check"
install_actions(launcher, profile)
files = profile / "nautilus/scripts/Send with myDrive"
dolphin = profile / "kio/servicemenus/net.oseanstudio.myDrive.Send.desktop"
assert os.access(files, os.X_OK) and os.access(dolphin, os.X_OK)
assert '--send-files %F' in dolphin.read_text()
assert '100%%.AppImage' in dolphin.read_text()
selection = [str(build / "File & name.txt"), str(build / "Sub folder")]
invoked = subprocess.check_output([files, *selection], text=True, env={
    **os.environ, "NAUTILUS_SCRIPT_CURRENT_URI": build.as_uri(),
})
assert invoked.splitlines() == ["--send-files", *selection]
PY
mkdir "$build/notice-check"
(cd "$build/notice-check" && "$output" --appimage-extract 'usr/share/doc/mydrive/*' >/dev/null)
test -s "$build/notice-check/squashfs-root/usr/share/doc/mydrive/ThirdPartyNotices.txt"
test -s "$build/notice-check/squashfs-root/usr/share/doc/mydrive/AppImage-Runtime.txt"
MYDRIVE_UPDATE_FIXTURE_PACKAGE="$output" MYDRIVE_UPDATE_FIXTURE_VERSION="$("$output" --version)" \
    cargo test --locked --manifest-path Core/Cargo.toml stages_and_restores_the_packaged_update -- --ignored
(cd "$MYDRIVE_BUILD_DIR" && sha256sum myDrive-Linux-x86_64.AppImage > myDrive-Linux-x86_64.AppImage.sha256)
