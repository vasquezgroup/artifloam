#!/bin/zsh
# Publishes a new Artifloam version for Mac:
#   ./scripts/release.sh 0.23.0
# Sets the version and the next build number, commits "Release <version>", tags mac-v<version>
# and pushes both. Then builds, notarizes and publishes the zip, disk image and signed update feed
# on vasquezgroup.ch, and creates the GitHub Release with the same files.
# Safe to run again after a failure: the version commit and tag are reused, never duplicated.
set -euo pipefail
cd "${0:A:h:h}"
version=${1:?usage: scripts/release.sh <version>, for example 0.23.0}
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Use a version like 0.23.0"; exit 1; }
tag="mac-v$version"
site=${VASQUEZGROUP_DIR:?Set VASQUEZGROUP_DIR to the website checkout}
[[ -x "$site/scripts/deploy.sh" || -f "$site/scripts/deploy.sh" ]] || { print -u2 "vasquezgroup.ch checkout not found at $site"; exit 1; }
[[ -z "$(git -C "$site" status --porcelain)" ]] || { print -u2 "Uncommitted changes in $site"; exit 1; }
# Public downloads must be Developer ID signed and notarized, so macOS can verify who published them.
# One-time setup: xcrun notarytool store-credentials <profile-name> --apple-id ... --team-id ...
[[ "${ARTIFLOAM_SIGNING_IDENTITY:-}" == "Developer ID Application:"* ]] || { print -u2 "Set ARTIFLOAM_SIGNING_IDENTITY to your \"Developer ID Application: ...\" certificate"; exit 1; }
[[ -n "${ARTIFLOAM_NOTARY_PROFILE:-}" ]] || { print -u2 "Set ARTIFLOAM_NOTARY_PROFILE to a notarytool keychain profile"; exit 1; }
# One-time setup: brew install gh && gh auth login
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { print -u2 'Install and sign in to the GitHub CLI: brew install gh && gh auth login'; exit 1; }
# The feed is signed here, so taking over the website can't publish an update. One-time setup: scripts/create-feed-key.sh
feed_key=$(security find-generic-password -a artifloam -s artifloam-feed-signing -w) || { print -u2 'Feed signing key not found in the Keychain.'; exit 1; }
trusted_key=$(sed -n 's/.*signingPublicKey = "\(.*\)".*/\1/p' Sources/MacStewardCore/UpdateFeed.swift)
[[ "$(print -r -- "$feed_key" | swift scripts/feed-signing.swift public)" == "$trusted_key" ]] || { print -u2 "The Keychain key doesn't match UpdateFeed.signingPublicKey, so installed apps would reject this feed."; exit 1; }

[[ "$(git branch --show-current)" == main ]] || { print -u2 'Release from main.'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Commit all changes before releasing.'; exit 1; }
git fetch --quiet --tags origin main
[[ -z "$(git rev-list HEAD..origin/main)" ]] || { print -u2 'origin/main has commits this checkout lacks. Pull first.'; exit 1; }
previous=$(git describe --tags --match 'mac-v*' --exclude "$tag" --abbrev=0 HEAD 2>/dev/null || true)
committed_version=$(sed -n 's:.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*:\1:p' scripts/package-app.sh)
committed_build=$(sed -n 's:.*<key>CFBundleVersion</key><string>\([0-9]*\)</string>.*:\1:p' scripts/package-app.sh)
if [[ "$version" != "$committed_version" ]]; then
  [[ "$(printf '%s\n' "$committed_version" "$version" | sort -V | tail -1)" == "$version" ]] || { print -u2 "$version is lower than the current $committed_version"; exit 1; }
  # Every release gets the next build number, so macOS and the update feed always see a newer app.
  sed -i '' -e "s:<key>CFBundleShortVersionString</key><string>$committed_version</string>:<key>CFBundleShortVersionString</key><string>$version</string>:" \
    -e "s:<key>CFBundleVersion</key><string>$committed_build</string>:<key>CFBundleVersion</key><string>$((committed_build + 1))</string>:" scripts/package-app.sh
  git commit --quiet -m "Release $version" scripts/package-app.sh
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  [[ "$(git rev-parse "$tag^{commit}")" == "$(git rev-parse HEAD)" ]] || { print -u2 "$tag already exists on another commit."; exit 1; }
else
  git tag -a "$tag" -m "Artifloam $version for Mac"
fi
git push --quiet origin main "refs/tags/$tag"
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
git -C "$site" diff --cached --quiet || git -C "$site" commit -m "Artifloam $version update feed"
git -C "$site" push
(cd "$site" && bash scripts/deploy.sh)
[[ "$(curl --fail --silent --show-error "$url" | shasum -a 256 | cut -d' ' -f1)" == "$sha256" ]] || { print -u2 "The published zip doesn't match its signed hash."; exit 1; }
[[ "$(curl --fail --silent --show-error https://vasquezgroup.ch/downloads/Artifloam.dmg | shasum -a 256 | cut -d' ' -f1)" == "$(shasum -a 256 "$site/public/downloads/Artifloam.dmg" | cut -d' ' -f1)" ]] || { print -u2 "The published disk image doesn't match this release."; exit 1; }
curl --fail --silent --show-error https://vasquezgroup.ch/updates/artifloam.json
# The GitHub Release carries the same notarized files as the website, and notes from the commits since the last Mac release.
dmg="dist/distribution/Artifloam-$version-$build.dmg"
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$site/public/downloads/$zip" "$dmg" --clobber
else
  gh release create "$tag" "$site/public/downloads/$zip" "$dmg" --verify-tag --title "Artifloam $version for Mac" --generate-notes ${previous:+--notes-start-tag "$previous"}
fi
print "\nReleased $version (build $build) from $(git rev-parse HEAD): https://github.com/vasquezgroup/artifloam/releases/tag/$tag"
