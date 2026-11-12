# Artifloam for iPhone

Native SwiftUI app for iPhone and iPad, iOS 17+. On iOS 17 the iPad keeps the tab bar instead of the sidebar. No third-party dependencies. It shares the Mac app's look but none of its code.

## Run it

Open `iOS/Artifloam.xcodeproj` in Xcode, choose the `Artifloam` scheme and run. To run on a real iPhone, set your team under Signing for both the `Artifloam` and `ArtifloamWidget` targets, or pass `DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates` to `xcodebuild`, then `xcrun devicectl device install app`.

```bash
cd iOS && xcodebuild test -project Artifloam.xcodeproj -scheme Artifloam -destination 'platform=iOS Simulator,name=iPhone 17'
```

The project uses synchronized folders, so new files in `Artifloam/`, `ArtifloamTests/` or `ArtifloamWidget/` join their target automatically.

## What iOS allows

An iPhone app can't read another app's data or sizes, or clear its cache. Don't add a feature that claims otherwise, and don't use private APIs here: App Review guidelines 2.5.1 and 2.5.2 rule them out.

So other apps' sizes come from one place:

- **Artifloam on the Mac** (`Sources/MacStewardCore`, iPhone section): reads every app's size over the cable, and WhatsApp per chat from a local backup. This uses a private Apple framework, so it stays out of any App Store build.

Artifloam can never delete inside another app. It points people to the right screen.

## Map

| File | Holds |
| --- | --- |
| `ArtifloamApp.swift` | Tabs, Overview, disk space, Clean recommended |
| `Theme.swift` | Mac colours, atmosphere, sculpture, orb, glass cards, page layouts |
| `Library.swift` | Photo scan, similar and blurred analysis, deleting, protected items |
| `MediaChanges.swift` | Video compression, Live Photo to still |
| `PhotosCleanup.swift` | Photos and Videos sections, review grid, swipe mode, compress and Live Photo screens |
| `AppsStorage.swift` | Apps section, per-app advice |
| `Tools.swift` | History, reminder, albums, categories, large files, contacts, device check |
| `Art/` | Copies from `Sources/MacSteward/Resources`. Replace them when the Mac artwork changes |
| `../ArtifloamWidget/` | Free space widget |

## Lessons from a real iPhone

- Library sizes are full originals, often in iCloud: a real phone showed 321 GB of videos on 256 GB of storage. Never add them to the storage bar.
- Nothing is deleted from one tap. Recommended opens a review with everything ticked, and the copy that stays is shown.
- A real library had over 24,000 items, so scans can be stopped, and deleting takes items off the lists instead of rescanning.

## What the main scan covers

The Scan button runs photos and videos, the health check, and duplicate contacts only if Contacts access was already given. It never asks for access by itself. Library categories and albums stay in Tools because they don't free space by themselves, and large files stay there because iOS needs a folder chosen. Compressing starts from a choice.

## iPad and unfolded iPhones

The tabs become a sidebar on iPad, like the Mac. At 760 points wide or more a section page splits: artwork, title and Scan button fixed on the left, cards scrolling beside them. Narrower wide screens (iPad mini upright, an unfolded iPhone) get one centred column. Detail pages stay 640 points wide at most. The photo grid scales its column levels with the width and keeps the level when the screen turns, folds or unfolds. The unfolded Duo couldn't be shown in the Simulator here, so it was checked at the iPad mini's width.

## Photo pages and the zoom

`PhotoPage` and `PhotoGrid` are shared by every photo list. The pictures follow the pinch exactly: `zoomStep` swaps the column count at the same visual size with no animation, and the scale settles when fingers lift. At two columns or fewer the title, text and bars fade out. The main action is always `orbFooter`, fixed above the tab bar.

## Scan speed

Measured on an iPhone 12 with 24,254 items, Release build. A first scan reads every item's size and analyses every photo. Later scans only touch new or edited items, using `ScanCache` in Caches.

- Before the rework: 134 s, covering only the newest 5,000 photos.
- First scan of 20,020 photos: about 88 s, added up from two runs. Sizes take 64 s, and more threads don't help them. Videos come first, at 12 s.
- Repeat scan: about 1 s.

Measure with a Release build. Debug is far slower.

## Shared with the Mac

`Artifloam/Shared` holds the photo scan, cache and media changes. It's also the `PhotoEngine` target in the root `Package.swift`, which the Mac's Photos section uses, so a change there affects both apps. Everything used by the Mac must be `public`.

The Apps tab shows every app if `Documents/mac-app-list.json` exists, in the format of `IPhoneAppList` on the Mac. Nothing writes that file yet. Writing it over the cable through MobileDevice's house arrest service failed on a real iPhone 12, locked and unlocked: the new service gave AFC error 11, and the older one hung at opening the file. A different route is needed.

## Translations

The app has the Mac app's 25 languages, in `Localizable.xcstrings`, `InfoPlist.xcstrings` and the widget's `Localizable.xcstrings`. New text needs adding to the catalogs, and `scripts/check-iphone-strings.sh` fails until it is. Text with `^[…](inflect: true)` needs plain plural forms in every language except English. They're machine translated, so have a native speaker check them before release.

## Rules to keep

- **Same look as the Mac.** Each section has one `StewardTheme`: its gradient, its sculpture, glass cards, the orb for the main action. Colours in `Theme.swift` must match `Sources/MacSteward/VisualLanguage.swift`. Use `StagePage` for sections and `DetailPage` below them.
- **Automatic or not at all.** Don't add features that make people do the work, such as taking screenshots for the app to read.
- **Scanning starts from the Scan button**, never on opening. Photos access is asked for at that moment.
- **Nothing is removed without a choice.** All photo deletes go through `Library.delete`, which shows iOS's confirmation. Items go to Recently Deleted.
- **Originals are safe until the copy exists.** `MediaChanges` creates the new file first, checks it, and only then asks to delete the original.
- **Favourites and protected items are never suggested.**
- **On-device only.** No network use, no analytics. Chat names and screenshots are kept in memory only.
- **Only honest claims.** No cache cleaners, boosters, virus scans or scare warnings.
- **Commit messages:** short, imperative, one line.
- Mark deliberate shortcuts with a comment naming the limit.

## The Mac side

The Mac app's iPhone section is in `Sources/MacSteward/IPhoneView.swift`, `Sources/MacStewardCore/IPhoneDevices.swift` and `Sources/MacStewardCore/WhatsAppBackup.swift`, tested by `Tests/MacStewardCoreTests/IPhoneTests.swift`.

- Exactly one iPhone on a USB cable is read by itself, once per plug-in. Anything else, including a paired phone on Wi-Fi that may be someone else's, needs picking first.
- Reading never changes the phone. Deleting an app is the one action that does: it needs a tick, a review sheet that says what goes, and an extra acknowledgement for chat or login-code apps, old backups, or an app that isn't on the App Store.
- Reported app sizes can add up to more than the phone says it uses, so the UI says "up to" and reports the measured change afterwards.
- Backups are optional, and only `--backup` may ever be passed to Apple's tool, which can also restore and erase.
- WhatsApp queries read names, IDs, sizes and file paths, never message text. A test enforces this.
- Artifloam can't delete inside WhatsApp, and must not edit or restore backups. Never advise deleting WhatsApp itself as a cleanup: it can lose chats.
