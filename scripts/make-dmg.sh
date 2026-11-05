#!/bin/zsh
# Makes the drag-to-Applications disk image: make-dmg.sh <app> <output.dmg> [signing identity]
set -euo pipefail
app=${1:?usage: make-dmg.sh <app> <output.dmg> [signing identity]}
out=${2:?usage: make-dmg.sh <app> <output.dmg> [signing identity]}
identity=${3:-}
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/${app:t}"
ln -s /Applications "$stage/Applications"
rm -f "$out"
hdiutil create -quiet -volname Artifloam -srcfolder "$stage" -format UDZO -ov "$out"
[[ -z "$identity" ]] || codesign --force --timestamp --sign "$identity" "$out"
print "Built: $out"
