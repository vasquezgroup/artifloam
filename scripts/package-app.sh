#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p dist
steward_stage=$(mktemp -d "$PWD/dist/.package-XXXXXX")
steward_app="$steward_stage/Artifloam.app"
trap 'rm -rf "$steward_stage"' EXIT
# SwiftPM never prunes resources removed from the package, so start from fresh bundles and a fresh app.
rm -rf .build/portable-*/*-apple-macosx/release/*.bundle(N)
mkdir -p "$steward_app/Contents/MacOS" "$steward_app/Contents/Helpers" "$steward_app/Contents/Resources"
for steward_arch in arm64 x86_64; do
  swift build -c release --build-system native --triple "$steward_arch-apple-macosx14.0" --scratch-path ".build/portable-$steward_arch"
done
steward_arm="$PWD/.build/portable-arm64/arm64-apple-macosx/release"
steward_intel="$PWD/.build/portable-x86_64/x86_64-apple-macosx/release"
lipo -create "$steward_arm/MacSteward" "$steward_intel/MacSteward" -output "$steward_app/Contents/MacOS/MacSteward"
lipo -create "$steward_arm/stewardctl" "$steward_intel/stewardctl" -output "$steward_app/Contents/Helpers/stewardctl"
# Release builds keep local symbols for debugging; the shipped app doesn't need them (about three quarters of the binary).
strip -x "$steward_app/Contents/MacOS/MacSteward" "$steward_app/Contents/Helpers/stewardctl"
# A download must not reveal who built it or where: fail rather than ship this Mac's paths.
if strings -a "$steward_app/Contents/MacOS/MacSteward" "$steward_app/Contents/Helpers/stewardctl" | grep -F "$HOME"; then
  print -u2 "A shipped binary contains a path from this Mac."; exit 1
fi
for steward_resources in "$steward_arm"/*.bundle(N); do
  ditto "$steward_resources" "$steward_app/Contents/Resources/${steward_resources:t}"
done
# Translations go straight in the app bundle: that is where SwiftUI's default lookups and macOS's language and right-to-left choice look.
for steward_catalog in Localization/*.xcstrings; do
  xcrun xcstringstool compile "$steward_catalog" --output-directory "$steward_app/Contents/Resources" >/dev/null
done
# Icon Composer raster layers use a 1024-point design canvas.
sips -z 1024 1024 design/brand/artifloam-dock-compact-master.png --out design/Artifloam.icon/Assets/artifloam-emblem.png >/dev/null
xcrun ictool design/Artifloam.icon --compile "$steward_app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon Artifloam --output-partial-info-plist "$PWD/dist/icon-info.plist"
cat > "$steward_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleExecutable</key><string>MacSteward</string>
<key>CFBundleIdentifier</key><string>com.vasquezgroup.artifloam</string>
<key>CFBundleName</key><string>Artifloam</string>
<key>CFBundleDisplayName</key><string>Artifloam</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.21.0</string>
<key>CFBundleVersion</key><string>46</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSMultipleInstancesProhibited</key><true/>
<key>CFBundleIconFile</key><string>Artifloam</string>
<key>CFBundleIconName</key><string>Artifloam</string>
<key>NSDesktopFolderUsageDescription</key><string>Measure Desktop storage for Space Map. Files stay unchanged until you review a cleanup.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Measure storage and find disposable leftovers in Documents. You review every cleanup.</string>
<key>NSAppleEventsUsageDescription</key><string>Artifloam asks Finder what the Trash holds and to empty it, and System Events to list, add or remove login items you choose.</string>
<key>NSLocalNetworkUsageDescription</key><string>Artifloam sends the list of this iPhone's apps between your Mac and iPhone over your Wi-Fi. It's encrypted and stays on your devices.</string>
<key>NSBonjourServices</key><array><string>_artifloam-list._tcp</string></array>
<key>NSPhotoLibraryUsageDescription</key><string>Artifloam finds large videos, screenshots and duplicates so you can choose what to delete. Your photos stay on your Mac and in your iCloud.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Find large files and exact duplicates in Downloads. You choose what moves to Trash.</string>
</dict></plist>
PLIST
# Only an official release checks for updates; forks and local builds connect to nothing.
if [[ "${ARTIFLOAM_OFFICIAL_BUILD:-}" == 1 ]]; then
  /usr/libexec/PlistBuddy -c 'Add :ArtifloamOfficialBuild bool true' "$steward_app/Contents/Info.plist"
fi
# Local development remains ad-hoc; release builds can supply a Developer ID
# identity without changing the bundle identifier or weakening runtime checks.
steward_signing_identity="${ARTIFLOAM_SIGNING_IDENTITY:--}"
steward_signing_options=(--force --options runtime --sign "$steward_signing_identity")
if [[ "$steward_signing_identity" != "-" ]]; then
  steward_signing_options+=(--timestamp)
fi
codesign "${steward_signing_options[@]}" --identifier com.vasquezgroup.artifloam.stewardctl "$steward_app/Contents/Helpers/stewardctl"
# The hardened runtime blocks the Photos library unless the app says it needs it.
codesign "${steward_signing_options[@]}" --entitlements scripts/Artifloam.entitlements "$steward_app/Contents/MacOS/MacSteward"
codesign "${steward_signing_options[@]}" --entitlements scripts/Artifloam.entitlements "$steward_app"
codesign --verify --deep --strict "$steward_app"
# Preserve the current bundle until the replacement has been built and verified.
# Keep its backup for a running instance and for local rollback.
if [[ -e "$PWD/dist/Artifloam.app" ]]; then
  mv "$PWD/dist/Artifloam.app" "$PWD/dist/Artifloam-previous-$(date +%Y%m%d-%H%M%S).app"
fi
mv "$steward_app" "$PWD/dist/Artifloam.app"
steward_app="$PWD/dist/Artifloam.app"
print "Built: $steward_app"
if [[ "${1:-}" == "--install" ]]; then
  if [[ -e "/Applications/Artifloam.app" ]]; then
    print -u2 "An installed app already exists. Review it before replacing it."
    exit 1
  fi
  ditto "$steward_app" "/Applications/Artifloam.app"
  print "Installed in /Applications. Automation remains off."
fi
