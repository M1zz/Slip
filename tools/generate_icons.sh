#!/usr/bin/env bash
#
# Regenerate the Slip app icon set from the Swift source.
#
# Run from the project root:
#
#     bash tools/generate_icons.sh
#
# It draws a 1024×1024 master via tools/generate_icon.swift, then
# uses sips to derive the @1x sizes the AppIcon.appiconset Contents.json
# references, and copies them into App/Resources/Assets.xcassets/
# AppIcon.appiconset/. Re-run any time the icon design changes.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

WORK=$(mktemp -d)
trap "rm -rf '$WORK'" EXIT

swift "$ROOT/tools/generate_icon.swift" "$WORK"

for size in 16 32 64 128 256 512; do
    sips -z $size $size "$WORK/AppIcon-1024.png" --out "$WORK/AppIcon-${size}.png" >/dev/null
done

DEST="$ROOT/App/Resources/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$DEST"
cp "$WORK"/AppIcon-{16,32,64,128,256,512,1024}.png "$DEST/"
echo "wrote ${DEST}/AppIcon-*.png"
