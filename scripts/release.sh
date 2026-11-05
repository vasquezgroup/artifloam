#!/bin/zsh
# Publishes a new Artifloam version on vasquezgroup.ch:
#   ./scripts/release.sh 0.17.0
# Prepares the committed version, puts the zip and update feed into the vasquezgroup.ch
# checkout, commits and pushes the feed there, then runs that site's deploy.
set -euo pipefail
cd "${0:A:h:h}"
version=${1:?usage: scripts/release.sh <version>, for example 0.17.0}
site=${VASQUEZGROUP_DIR:?Set VASQUEZGROUP_DIR to the website checkout}
[[ -x "$site/scripts/deploy.sh" || -f "$site/scripts/deploy.sh" ]] || { print -u2 "vasquezgroup.ch checkout not found at $site"; exit 1; }
[[ -z "$(git -C "$site" status --porcelain)" ]] || { print -u2 "Uncommitted changes in $site"; exit 1; }
# Public downloads must be Developer ID signed and notarized, so macOS can verify who published them.
# One-time setup: xcrun notarytool store-credentials <profile-name> --apple-id ... --team-id ...
[[ "${ARTIFLOAM_SIGNING_IDENTITY:-}" == "Developer ID Application:"* ]] || { print -u2 "Set ARTIFLOAM_SIGNING_IDENTITY to your \"Developer ID Application: ...\" certificate"; exit 1; }
[[ -n "${ARTIFLOAM_NOTARY_PROFILE:-}" ]] || { print -u2 "Set ARTIFLOAM_NOTARY_PROFILE to a notarytool keychain profile"; exit 1; }

committed_version=$(sed -n 's:.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*:\1:p' scripts/package-app.sh)
[[ "$version" == "$committed_version" && "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Bump version/build in package-app.sh, commit and push main first.'; exit 1; }
# The feed is signed here, so taking over the website can't publish an update. One-time setup: scripts/create-feed-key.sh
feed_key=$(security find-generic-password -a artifloam -s artifloam-feed-signing -w) || { print -u2 'Feed signing key not found in the Keychain.'; exit 1; }
trusted_key=$(sed -n 's/.*signingPublicKey = "\(.*\)".*/\1/p' Sources/MacStewardCore/UpdateFeed.swift)
[[ "$(print -r -- "$feed_key" | swift scripts/feed-signing.swift public)" == "$trusted_key" ]] || { print -u2 "The Keychain key doesn't match UpdateFeed.signingPublicKey, so installed apps would reject this feed."; exit 1; }
./scripts/prepare-distribution.sh
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/Artifloam.app/Contents/Info.plist)

zip="Artifloam-$version.zip"
mkdir -p "$site/public/downloads"
ditto -c -k --keepParent dist/Artifloam.app "$site/public/downloads/$zip"
url="https://vasquezgroup.ch/downloads/$zip"
sha256=$(shasum -a 256 "$site/public/downloads/$zip" | cut -d' ' -f1)
# The download page's link never changes. Apps update from the versioned zip, because the feed signs it.
cp -p "dist/distribution/Artifloam-$version-$build.dmg" "$site/public/downloads/Artifloam.dmg"
signature=$(print -r -- "$feed_key" | swift scripts/feed-signing.swift sign "$version" "$url" "$sha256")
cat > "$site/public/updates/artifloam.json" <<JSON
{
  "version": "$version",
  "url": "$url",
  "sha256": "$sha256",
  "signature": "$signature"
}
JSON
# The zip is uploaded by deploy.sh (it rsyncs public/) but stays out of Git.
git -C "$site" add public/updates/artifloam.json
git -C "$site" commit -m "Artifloam $version update feed"
git -C "$site" push
(cd "$site" && bash scripts/deploy.sh)
[[ "$(curl --fail --silent --show-error "$url" | shasum -a 256 | cut -d' ' -f1)" == "$sha256" ]] || { print -u2 "The published zip doesn't match its signed hash."; exit 1; }
[[ "$(curl --fail --silent --show-error https://vasquezgroup.ch/downloads/Artifloam.dmg | shasum -a 256 | cut -d' ' -f1)" == "$(shasum -a 256 "$site/public/downloads/Artifloam.dmg" | cut -d' ' -f1)" ]] || { print -u2 "The published disk image doesn't match this release."; exit 1; }
curl --fail --silent --show-error https://vasquezgroup.ch/updates/artifloam.json
print "\nReleased $version (build $build) from $(git rev-parse HEAD)."
