#!/bin/zsh
# Adds new source strings to Localization/Localizable.xcstrings. Translate what it adds; `swift test` fails until every language has them.
set -euo pipefail
cd "${0:A:h:h}"
steward_strings=$(mktemp -d)
trap 'rm -rf "$steward_strings"' EXIT
swift build --scratch-path .build/strings -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$steward_strings"
xcrun xcstringstool sync Localization/Localizable.xcstrings --stringsdata "$steward_strings"/*.stringsdata
# The tool renames sr-Cyrl to sr, but the app's folder and tests use sr-Cyrl.
sed -i '' 's/^        "sr" : {/        "sr-Cyrl" : {/' Localization/Localizable.xcstrings
