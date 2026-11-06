# Artifloam for iPhone

Native SwiftUI app, iOS 17+. No third-party dependencies. It shares the Mac app's look but none of its code.

**Status: in development, not released.** Work is on the local branch `iphone-app`. Don't push it or merge it to `main` until the owner says so, because `origin` is the public repository.

## Run it

Open `iOS/Artifloam.xcodeproj` in Xcode, choose the `Artifloam` scheme and run. To run on a real iPhone, set your team under Signing for both the `Artifloam` and `ArtifloamWidget` targets.

```bash
cd iOS && xcodebuild test -project Artifloam.xcodeproj -scheme Artifloam -destination 'platform=iOS Simulator,name=iPhone 17'
```

The project uses synchronized folders, so new files in `Artifloam/`, `ArtifloamTests/` or `ArtifloamWidget/` join their target automatically.

## What iOS allows

An iPhone app can't read another app's data or sizes, or clear its cache. Don't add a feature that claims otherwise, and don't use private APIs here: App Review guidelines 2.5.1 and 2.5.2 rule them out.

So other apps' sizes come from two places:

- **Artifloam on the Mac** (`Sources/MacStewardCore`, iPhone section): reads every app's size over the cable, and WhatsApp per chat from a local backup. This uses a private Apple framework, so it stays out of any App Store build.
- **The screenshot reader** (`AppsStorage.swift`): an optional fallback that reads iPhone Storage or WhatsApp's Manage storage screenshots on the device.

Artifloam can never delete inside another app. It points people to the right screen.

## Map

| File | Holds |
| --- | --- |
| `ArtifloamApp.swift` | Tabs, Overview, disk space, Clean recommended |
| `Theme.swift` | Mac colours, atmosphere, sculpture, orb, glass cards, page layouts |
| `Library.swift` | Photo scan, similar and blurred analysis, deleting, protected items |
| `MediaChanges.swift` | Video compression, Live Photo to still |
| `PhotosCleanup.swift` | Photos and Videos sections, review grid, swipe mode, compress and Live Photo screens |
| `AppsStorage.swift` | Apps section, screenshot reading, per-app advice |
| `StorageScreenshot.swift` | Pure parsing of screenshot text |
| `Tools.swift` | History, reminder, albums, categories, large files, contacts, device check |
| `Art/` | Copies from `Sources/MacSteward/Resources`. Replace them when the Mac artwork changes |
| `../ArtifloamWidget/` | Free space widget |

## Rules to keep

- **Same look as the Mac.** Each section has one `StewardTheme`: its gradient, its sculpture, glass cards, the orb for the main action. Colours in `Theme.swift` must match `Sources/MacSteward/VisualLanguage.swift`. Use `StagePage` for sections and `DetailPage` below them.
- **Automatic first.** The scan starts when the app opens. Only ask people to act when iOS requires it.
- **Nothing is removed without a choice.** All photo deletes go through `Library.delete`, which shows iOS's confirmation. Items go to Recently Deleted.
- **Originals are safe until the copy exists.** `MediaChanges` creates the new file first, checks it, and only then asks to delete the original.
- **Favourites and protected items are never suggested.**
- **On-device only.** No network use, no analytics. Chat names and screenshots are kept in memory only.
- **Only honest claims.** No cache cleaners, boosters, virus scans or scare warnings.
- **Commit messages:** short, imperative, one line, no AI co-author lines.
- Mark deliberate shortcuts with a `ponytail:` comment naming the limit.

## Seen working

In the Simulator, on test media: scan on opening, Clean with iOS's confirmation (cancel and delete), compression (148.8 MB to 9 MB, and cancelling keeps both), similar and blurred detection, per-section look. Vision read a generated storage screen. Everything else is only unit-tested or untested, as listed below.

Vision's feature prints returned all zeros in the Simulator, which is why similar photos use `differenceHash` instead. Don't switch back without testing on a real device and rejecting all-zero prints.

## Left to do

Anything not ticked hasn't been seen working.

### Must check on a real iPhone

- [ ] Sharpness and similar thresholds in `LibraryScan` (`blurThreshold`, `similarBits`). They're starting values, checked only on Simulator sample and generated images.
- [ ] Library categories. `VNClassifyImageRequest` puts everything in Other in the Simulator, so sorting has never been seen working.
- [ ] Scan speed on a large library. Analysis covers the newest 5,000 photos.
- [ ] Live Photo conversion. No Live Photo exists in the Simulator, so it has never run.
- [ ] Compression on real iPhone video, including HDR and iCloud-only videos. Slow-motion may lose its effect, because the code doesn't handle it specially.
- [ ] iPhone Storage and WhatsApp screenshots. Parsing has only seen generated images.
- [ ] Menu paths in `StorageAdvice`. Most come from secondary guides.
- [ ] Whether `nflx://`, `whatsapp://` and the other URL schemes open their apps.
- [ ] The low-space reminder. iOS decides when it runs.
- [ ] Duplicate contacts merge on a real address book.

### Before release

- [ ] Translations. Only English exists, and the Mac app has 25 languages. Add a string catalog here.
- [ ] Apple team, signing and App Store record.
- [ ] App Review risk: `LibraryScan.size(of:)` reads an undocumented `fileSize` key. Find a public alternative if it's rejected.
- [ ] Privacy policy, including the Photos and Contacts access.
- [ ] Mention the iPhone app in the root README.
- [ ] Owner checks the branch before anything goes public.
