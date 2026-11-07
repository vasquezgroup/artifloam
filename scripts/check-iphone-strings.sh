#!/bin/zsh
# Fails if the iPhone app has text missing from its catalogs, or a language without it. Changes nothing in the repo.
set -euo pipefail
cd "${0:A:h:h}"
steward_work=$(mktemp -d)
trap 'rm -rf "$steward_work"' EXIT
# A fresh build folder: an incremental build reports strings only for the files it recompiled.
xcodebuild -project iOS/Artifloam.xcodeproj -scheme Artifloam -destination 'generic/platform=iOS Simulator' -derivedDataPath "$steward_work" CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES build >/dev/null 2>&1
python3 - "$steward_work" <<'PY'
import glob, json, re, sys
languages = set().union(*(entry.get('localizations', {}).keys() for entry in json.load(open('Localization/Localizable.xcstrings'))['strings'].values())) - {'en'}
problems = []
for target, catalog in (('Artifloam', 'iOS/Artifloam/Localizable.xcstrings'), ('ArtifloamWidget', 'iOS/ArtifloamWidget/Localizable.xcstrings')):
    strings = json.load(open(catalog))['strings']
    keys = set()
    for path in glob.glob(f'{sys.argv[1]}/Build/Intermediates.noindex/Artifloam.build/*/{target}.build/**/*.stringsdata', recursive=True):
        for table in json.load(open(path))['tables'].values():
            keys |= {item['key'] for item in table}
    if not keys:
        problems.append(f'{target}: no strings found, so nothing was checked')
    for key in sorted(keys):
        if not key or not re.sub(r'%(\d+\$)?(lld|@|lf|d|%)', '', key).strip(' ·,\n'):
            continue
        found = strings.get(key, {}).get('localizations', {})
        missing = languages - set(found)
        if missing:
            problems.append(f'{target}: {key!r} is missing {len(missing)} languages')
if problems:
    print('\n'.join(problems), file=sys.stderr)
    sys.exit(1)
print('Every iPhone string is in every language.')
PY
