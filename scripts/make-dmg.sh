#!/bin/zsh
# Makes the drag-to-Applications disk image: make-dmg.sh <app> <output.dmg> [signing identity]
set -euo pipefail
root=${0:A:h:h}
app=${1:?usage: make-dmg.sh <app> <output.dmg> [signing identity]}
out=${2:?usage: make-dmg.sh <app> <output.dmg> [signing identity]}
identity=${3:-}
tools=$root/.build/dmg-tools
if [[ ! -x $tools/bin/dmgbuild ]]; then
  /usr/bin/python3 -m venv "$tools"
  "$tools/bin/pip" install --quiet --require-hashes --only-binary :all: --no-deps -r "$root/scripts/dmg-requirements.txt"
fi
rm -f "$out"
"$tools/bin/dmgbuild" -s "$root/scripts/dmg-settings.py" -D "app=${app:A}" -D "background=$root/design/installer/background.tiff" Artifloam "$out"
[[ -z "$identity" ]] || codesign --force --timestamp --sign "$identity" "$out"
print "Built: $out"
