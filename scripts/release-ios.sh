#!/bin/zsh
# Marks a new Artifloam iPhone version:
#   ./scripts/release-ios.sh 1.0.1
# Sets MARKETING_VERSION and the next build number for the app and widget, commits
# "Release iPhone <version>", tags ios-v<version>, pushes both and creates the GitHub Release.
# Archive and upload that commit from Xcode afterwards; App Store Connect needs a new build number each time.
# Safe to run again: the version commit and tag are reused, never duplicated.
set -euo pipefail
cd "${0:A:h:h}"
version=${1:?usage: scripts/release-ios.sh <version>, for example 1.0.1}
[[ "$version" =~ '^[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print -u2 "Use a version like 1.0.1"; exit 1; }
tag="ios-v$version"
project=iOS/Artifloam.xcodeproj/project.pbxproj
# One-time setup: brew install gh && gh auth login
command -v gh >/dev/null && gh auth status >/dev/null 2>&1 || { print -u2 'Install and sign in to the GitHub CLI: brew install gh && gh auth login'; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { print -u2 'Release from main.'; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 'Commit all changes before releasing.'; exit 1; }
git fetch --quiet --tags origin main
[[ -z "$(git rev-list HEAD..origin/main)" ]] || { print -u2 'origin/main has commits this checkout lacks. Pull first.'; exit 1; }
previous=$(git describe --tags --match 'ios-v*' --exclude "$tag" --abbrev=0 HEAD 2>/dev/null || true)
# The app and its widget must carry the same version and build, or App Store Connect rejects the upload.
versions=(${(u)${(f)"$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$project")"}})
builds=(${(u)${(f)"$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);/\1/p' "$project")"}})
(( ${#versions} == 1 && ${#builds} == 1 )) || { print -u2 "App and widget versions differ in $project. Align them first."; exit 1; }
if [[ "$version" != "${versions[1]}" ]]; then
  [[ "$(printf '%s\n' "${versions[1]}" "$version" | sort -V | tail -1)" == "$version" ]] || { print -u2 "$version is lower than the current ${versions[1]}"; exit 1; }
  sed -i '' -e "s/MARKETING_VERSION = ${versions[1]};/MARKETING_VERSION = $version;/" \
    -e "s/CURRENT_PROJECT_VERSION = ${builds[1]};/CURRENT_PROJECT_VERSION = $((builds[1] + 1));/" "$project"
  git commit --quiet -m "Release iPhone $version" "$project"
fi
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  [[ "$(git rev-parse "$tag^{commit}")" == "$(git rev-parse HEAD)" ]] || { print -u2 "$tag already exists on another commit."; exit 1; }
else
  git tag -a "$tag" -m "Artifloam $version for iPhone"
fi
git push --quiet origin main "refs/tags/$tag"
build=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);/\1/p' "$project" | head -1)
# No download: the iPhone app ships only through the App Store.
gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" --verify-tag --title "Artifloam $version for iPhone" --generate-notes ${previous:+--notes-start-tag "$previous"}
print "\nTagged iPhone $version (build $build) at $(git rev-parse --short HEAD). Archive this commit in Xcode and upload it to App Store Connect."
