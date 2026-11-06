#!/bin/zsh
# Fails if the source has text missing from Localization/Localizable.xcstrings. Changes nothing in the repo.
# `swift test` can't see this: missing text shows in English everywhere, and a missing plural reads "1 files".
set -euo pipefail
cd "${0:A:h:h}"
steward_work=$(mktemp -d)
trap 'rm -rf "$steward_work"' EXIT
# A fresh build folder: an incremental build reports strings only for the files it recompiled.
swift build --scratch-path "$steward_work/build" -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$steward_work" >/dev/null 2>&1
# The tool matches a catalog to its strings by file name, so the copy keeps it.
mkdir "$steward_work/copy"
cp Localization/Localizable.xcstrings "$steward_work/copy/"
xcrun xcstringstool sync "$steward_work/copy/Localizable.xcstrings" --stringsdata "$steward_work"/*.stringsdata >/dev/null 2>&1
steward_missing=$(comm -13 <(xcrun xcstringstool print Localization/Localizable.xcstrings | sort) <(xcrun xcstringstool print "$steward_work/copy/Localizable.xcstrings" | sort))
if [[ -n "$steward_missing" ]]; then
  print -u2 "Text missing from the catalog. Run scripts/sync-strings.sh and translate it:"
  print -u2 -- "$steward_missing"
  exit 1
fi
print "Every source string is in the catalog."
