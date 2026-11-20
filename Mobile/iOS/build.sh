#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${MYDRIVE_IOS_BUILD:-${OSEAN_STUDIO_DATA:-$HOME/Library/Caches/myDrive}/Build Cache/myDrive iOS}"
mkdir -p "$OUT"
command -v xcodegen >/dev/null || { echo 'Install XcodeGen, then rerun this script.'; exit 1; }
WORK="$(mktemp -d "$OUT/Project.XXXXXX")"
cp -R "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Info.plist" "$ROOT/project.yml" "$WORK/"
cd "$WORK"
xcodegen generate --spec "$WORK/project.yml" --project "$WORK"
if [[ "${1:-}" == "--device" ]]; then
  xcodebuild -project "$WORK/myDrive.xcodeproj" -scheme myDrive -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "$OUT/DerivedData" "${@:2}" build
else
  xcodebuild -project "$WORK/myDrive.xcodeproj" -scheme myDrive -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath "$OUT/DerivedData" CODE_SIGNING_ALLOWED=NO build
fi
echo "Built in: $OUT/DerivedData/Build/Products"
echo "Open in Xcode: $WORK/myDrive.xcodeproj"
