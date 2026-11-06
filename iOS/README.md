# Artifloam for iPhone

Native SwiftUI app, iOS 17+. No third-party dependencies. It shares the Mac app's look but none of its code.

**Status: in development, not released.** Work is on the local branch `iphone-app`. Don't push it or merge it to `main` until the owner says so, because `origin` is the public repository.

## Run it

Open `iOS/Artifloam.xcodeproj` in Xcode, choose the `Artifloam` scheme and run. To run on a real iPhone, set your team under Signing for both the `Artifloam` and `ArtifloamWidget` targets, or pass `DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates` to `xcodebuild`, then `xcrun devicectl device install app`.

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

## Continue here

1. `git switch iphone-app` in `~/Documents/projects/artifloam`. Work is local only, with no remote branch.
2. Run the tests above, and `swift test` for the Mac app.
3. Work through the checklists below. The real-iPhone checks come first, because they can change the code.

Private research, competitor notes and the feature list are in the private documents repository: `docs/IPHONE-RESEARCH.md` and `docs/IPHONE-FEATURES.md`. Don't copy them here.

## The Mac side

The Mac app's iPhone section is in `Sources/MacSteward/IPhoneView.swift`, `Sources/MacStewardCore/IPhoneDevices.swift` and `Sources/MacStewardCore/WhatsAppBackup.swift`, tested by `Tests/MacStewardCoreTests/IPhoneTests.swift`.

- Nothing connects to an iPhone until the person picks it and presses Read. Never pick one automatically: a Mac can have other people's phones paired.
- Reading never changes the phone. Deleting an app is the one action that does: it needs a tick, a review sheet that says what goes, and an extra acknowledgement for chat or login-code apps, old backups, or clearing an app that isn't on the App Store. The result comes from reading the phone again.
- iOS can't clear an app's data on its own. "Clear data" deletes the app, and the person installs it again.
- `AMDeviceSecureUninstallApplication` works: it removed a real app from a real iPhone, confirmed by reading the phone again.
- **Reported sizes can overstate.** Removing an app reported at 7.87 GB didn't lower the phone's total used space within about 20 minutes, and all apps' sizes add up to more than the phone says it uses. So the UI says "up to" and reports the measured change afterwards. Check whether the space appears later.
- `PasswordProtected` from lockdown drives the unlock overlay. It read 1 and later 0 on a real phone, which fits the lock state, but hasn't been compared against a deliberate lock and unlock. The overlay itself hasn't been seen on screen. "It's unlocked" is the way out if this value is ever wrong.
- The WhatsApp backup flow keeps stopping at Full Disk Access in testing, even with the banner gone. Reading a real backup is still unverified.
- Backups are optional, and only `--backup` may ever be passed to Apple's tool, which can also restore and erase.
- `lastChanged` and app use only mean something with a backup. Without one, the UI must not call data size "use": Gmail, X and UBS Banking all hold little data.
- WhatsApp queries read names, IDs, sizes and file paths, never message text. A test enforces this. A temporary database copy, which does hold messages, exists only during a read if a `-wal` file is present.
- Encrypted backups aren't supported yet. It says so rather than asking for a password.
- Artifloam can't delete inside WhatsApp, and must not edit or restore backups. Never advise deleting WhatsApp itself as a cleanup: it can lose chats.
- The section has its own indigo theme (`StewardTheme.iphone`) and artwork, rendered by `design/render-iphone-art.py` in the private repository. Encode with `design/encode-artwork-motion.swift` as for other sections.

### Mac: must check

- [x] The live app lookup, device name and sizes, through `IPhoneDeviceWatcher` on a real iPhone already paired with this Mac: 308 apps, all measured.
- [ ] The Trust flow on an iPhone that isn't paired yet.
- [ ] The WhatsApp schema on a real, current backup, for both WhatsApp and WhatsApp Business. Reading needs Full Disk Access. Table names come from older sources, the Business domain is matched by pattern and unconfirmed, and special chats such as `status@broadcast` would show as a person.
- [x] The start, reading and results screens, with a real iPhone. Only one copy of Artifloam can run at a time, so quit others first, including debug builds.
- [ ] The "Connect your iPhone" line with no iPhone connected. The code path is simple but hasn't been seen.
- [ ] A Developer ID signed build. Loading the framework works with an ad-hoc hardened runtime signature.
- [ ] Decide whether the backup list should show every device's backups by name when the chosen phone has none.

### Mac: known failing test

`LocalizationTests.testEveryLanguageHasEveryStringWithMatchingPlaceholders` fails on purpose until 58 new strings are translated into 24 languages. All other Mac tests pass.

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
