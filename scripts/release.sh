#!/bin/zsh
# Releases a new Artifloam version for Mac:
#   ./scripts/release.sh 0.23.0
# Sets the version and the next build number, commits "Release <version>", tags mac-v<version>
# and pushes both. Then builds, notarizes and staples the app and disk image, and creates the
# GitHub Release with them. The website and its signed update feed are published separately.
# Safe to run again after a failure: the version commit and tag are reused, never duplicated.
set -euo pipefail
cd "${0:A:h:h}"
version=${1:?usage: scripts/release.sh <version>, for example 0.23.0}
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Use a version like 0.23.0"; exit 1; }
tag="mac-v$version"
# Public downloads must be Developer ID signed and notarized, so macOS can verify who published them.
# One-time setup: xcrun notarytool store-credentials <profile-name> --apple-id ... --team-id ...
[[ "${ARTIFLOAM_SIGNING_IDENTITY:-}" == "Developer ID Application:"* ]] || { print -u2 "Set ARTIFLOAM_SIGNING_IDENTITY to your \"Developer ID Application: ...\" certificate"; exit 1; }
[[ -n "${ARTIFLOAM_NOTARY_PROFILE:-}" ]] || { print -u2 "Set ARTIFLOAM_NOTARY_PROFILE to a notarytool keychain profile"; exit 1; }
# One-time setup: brew install gh && gh auth login
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { print -u2 'Install and sign in to the GitHub CLI: brew install gh && gh auth login'; exit 1; }

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
# Plain names for the download: Artifloam-0.23.0.zip and Artifloam-0.23.0.dmg.
assets=dist/distribution/release; rm -rf "$assets"; mkdir -p "$assets"
cp -p "dist/distribution/Artifloam-$version-$build.zip" "$assets/Artifloam-$version.zip"
cp -p "dist/distribution/Artifloam-$version-$build.dmg" "$assets/Artifloam-$version.dmg"
# Notes come from the commits since the last Mac release.
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" "$assets"/* --clobber
else
  gh release create "$tag" "$assets"/* --verify-tag --title "Artifloam $version for Mac" --generate-notes ${previous:+--notes-start-tag "$previous"}
fi
print "\nReleased $version (build $build) from $(git rev-parse HEAD): https://github.com/vasquezgroup/artifloam/releases/tag/$tag"
