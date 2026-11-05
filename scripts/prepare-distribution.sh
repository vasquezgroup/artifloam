#!/bin/zsh
# Build and notarize a reviewable artifact. This script never updates the website or update feed.
set -euo pipefail
cd "${0:A:h:h}"
[[ "$(git branch --show-current)" == main ]] || { print -u2 'Prepare distribution from main.'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Commit all changes before preparing distribution.'; exit 1; }
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { print -u2 'Push main before preparing distribution.'; exit 1; }
for candidate in ${(f)"$(git for-each-ref --format='%(refname:short)' refs/heads)"}; do
  [[ "$(git rev-list --count main.."$candidate")" == 0 ]] || { print -u2 "Unmerged branch: $candidate"; exit 1; }
done
[[ "${ARTIFLOAM_SIGNING_IDENTITY:-}" == 'Developer ID Application:'* ]] || { print -u2 'Set ARTIFLOAM_SIGNING_IDENTITY to a Developer ID Application identity.'; exit 1; }
[[ -n "${ARTIFLOAM_NOTARY_PROFILE:-}" ]] || { print -u2 'Set ARTIFLOAM_NOTARY_PROFILE to a notarytool keychain profile.'; exit 1; }
source_commit=$(git rev-parse HEAD)
swift test
ARTIFLOAM_OFFICIAL_BUILD=1 ./scripts/package-app.sh
[[ -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$source_commit" ]] || { print -u2 'Source changed while building. Commit and prepare again.'; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Artifloam.app/Contents/Info.plist)
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/Artifloam.app/Contents/Info.plist)
mkdir -p dist/distribution
archive="$PWD/dist/distribution/Artifloam-$version-$build.zip"
ditto -c -k --keepParent dist/Artifloam.app "$archive"
# Keep the submission ID so a slow request can be resumed with notarytool info/wait.
xcrun notarytool submit "$archive" --keychain-profile "$ARTIFLOAM_NOTARY_PROFILE" --output-format json > dist/distribution/notary-submission.json
submission_id=$(/usr/bin/plutil -extract id raw -o - dist/distribution/notary-submission.json)
print "Apple submission: $submission_id"
xcrun notarytool wait "$submission_id" --keychain-profile "$ARTIFLOAM_NOTARY_PROFILE" --output-format json > dist/distribution/notary-result.json
[[ "$(/usr/bin/plutil -extract status raw -o - dist/distribution/notary-result.json)" == Accepted ]] || { print -u2 'Apple did not accept this build. Inspect the notarization log.'; exit 1; }
[[ -z "$(git status --porcelain)" && "$(git rev-parse HEAD)" == "$source_commit" ]] || { print -u2 'Source changed during notarization. Prepare again.'; exit 1; }
xcrun stapler staple dist/Artifloam.app
xcrun stapler validate dist/Artifloam.app
codesign --verify --deep --strict dist/Artifloam.app
spctl --assess --type execute --verbose=2 dist/Artifloam.app
# The final download must include the stapled ticket, unlike the archive submitted to Apple.
ditto -c -k --keepParent dist/Artifloam.app "$archive"
# The first-install disk image is signed, notarized and stapled too.
image="$PWD/dist/distribution/Artifloam-$version-$build.dmg"
./scripts/make-dmg.sh dist/Artifloam.app "$image" "$ARTIFLOAM_SIGNING_IDENTITY"
xcrun notarytool submit "$image" --keychain-profile "$ARTIFLOAM_NOTARY_PROFILE" --wait --output-format json > dist/distribution/notary-image-result.json
[[ "$(/usr/bin/plutil -extract status raw -o - dist/distribution/notary-image-result.json)" == Accepted ]] || { print -u2 'Apple did not accept the disk image.'; exit 1; }
xcrun stapler staple "$image"
xcrun stapler validate "$image"
spctl --assess --type open --context context:primary-signature --verbose=2 "$image"
python3 - "$source_commit" "$archive" "$submission_id" "$version" "$build" <<'PY'
import hashlib, json, pathlib, sys
commit, archive, submission, version, build = sys.argv[1:]
path = pathlib.Path(archive)
digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
manifest = dict(commit=commit, version=version, build=build, archive=path.name, sha256=digest,
                notarization=submission, status='Accepted', published=False)
path.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
print "Prepared, not published: $archive"
