# Audiobug

A simple audiobook player for the **iPhone**, with an **Apple Watch** app that keeps its own copies of books so you can
listen without the phone. Plays Apple-style audiobooks (M4B with chapters) and plain M4A / MP3 / AAC / WAV / AIFF /
FLAC files. It remembers where you are in every book, on both devices.

> DRM-protected audiobooks bought in the Apple Books store cannot be played by third-party apps. Audiobug plays
> DRM-free files: M4B/M4A you made yourself (e.g. with `ebooker`), bought elsewhere, or ripped from CDs.

## iPhone

- **Library.** Books live in *Files › On My iPhone › Audiobug › Books*, in folders if you like (a folder becomes a
  section). Add books with **+** (Files picker), AirDrop / "Open in Audiobug" from any app, or the Inbox below.
  Swipe to delete; pull down to sync the Inbox.
- **Covers.** Each book shows its cover: the art embedded in the file, or a picture beside it with the same name
  (`Emma.jpg` next to `Emma.m4b`). To use a picture of your own, long-press the book (or its cover in the player)
  and choose **Cover › Choose from Photos / Files**; *Use the Book's Own Cover* goes back. Covers are cached as
  thumbnails in Application Support and sent to the Watch along with the book.
- **Player.** Cover, title, author and the current chapter (tap it for the chapter list). Scrub anywhere in the book;
  skip back/forward (15 s / 30 s by default, changeable in Settings); previous/next chapter; **speed** from 0.75× to 3×
  in presets or ±0.1 steps — each book remembers its own speed; **sleep timer** (minutes or end of chapter);
  **audio output** button (the system AirPlay picker: speaker, AirPods, HomePod, car…); **To Watch** sends the book
  to the Watch. Lock screen, Control Centre, AirPods and car controls work (play/pause, skip, chapters, speed).
- **Suggest an Improvement** (your own builds only). Hear a word read or stressed wrong? Tap the lightbulb in the
  player (or the Watch's More sheet) and say what's wrong: the note is saved to *iCloud Drive › Audiobug › Improvement
  notes.md* with the book, chapter and time, and routed to ebooker, which made the book. The library's ⋯ menu has the
  same for the app itself; crash reports land in *Crash reports*.
- **Positions.** Saved every 5 s while playing, on pause and when the app goes to the background. A finished book
  starts over when played again.
- **iCloud Inbox.** *iCloud Drive › Audiobug › Inbox* mirrors the library's folders (the same scheme as Scriptorium's
  Inbox). Drop audiobooks there from a Mac, an iPad or the web, into the folder you want; the iPhone imports them
  into the same folder of its library — while the app is open (it watches the folder), and in the background
  (BGTaskScheduler, typically while idle and charging) — and then removes them from the Inbox. Unsupported files are
  left in place; a file that is already in the library is removed as a duplicate. Files saved without an extension
  are recognised by their contents. **Sync iCloud Inbox** in the ⋯ menu (or pull to refresh) imports immediately and
  shows a report. Without an iCloud account the Inbox is *On My iPhone › Audiobug › Inbox*.

## Apple Watch

- **Books on the Watch.** In the iPhone app, choose **Send to Apple Watch** on a book (context menu, or the *To Watch*
  button in the player). The transfer runs through WatchConnectivity in the background; the row shows its progress
  and then a watch badge. The Watch keeps the book in its own storage (folders preserved) and lists it with the
  remaining time and its cover. Swipe a book on the Watch to delete it, or **Remove from Apple Watch** on the iPhone.
- **Player.** Page 1 (over the dimmed cover): chapter, progress, skip back/forward, play/pause — a tap anywhere on
  the title/progress area also toggles play/pause — the volume on the Digital Crown, **speed** and a *More* sheet
  with **chapters**, **audio output** and **sleep timer**. Page 2 (swipe up): the system **Now Playing** view with the
  volume (Digital Crown) and the **AirPlay / output** button.
- **Sound destination.** watchOS plays long-form audio only through Bluetooth headphones or speakers: when none is
  connected, pressing play (or *Audio output › Choose headphones…*) shows the system headphone picker; the Now
  Playing page's AirPlay button lists every available output at any time.
- **Positions sync** both ways with the iPhone (newest wins), so you can continue on either device.

## Layout

| Path | What |
|---|---|
| `Packages/AudiobugCore` | Platform-neutral core; `swift test` on the Mac: `InboxSync` + `ICloudFiles` (iCloud Inbox), `PositionStore`, `BookFingerprint` (stable book ids), `AudiobookFormat` (supported files, sniffing), `AudiobookInspector` (title/author/cover/chapters via AVFoundation), `CoverArt` (embedded/sidecar cover, thumbnails) |
| `Shared/` | Compiled into both apps: `Player` (AVPlayer engine: speed, chapters, sleep timer, interruptions), `NowPlaying` + `RemoteCommands`, `AudioSession`, `Audiobook` + `LibraryScanner`, `CoverStore` + `CoverView` (cover cache, shown everywhere), `Settings`, `SyncMessages` |
| `App/` | iPhone app: `LibraryStore` (+ Inbox watcher and background import in `InboxAutomation.swift`), `LibraryView`, `PlayerView`, `CoverPicker` (Photos/Files cover menu), `RoutePickerButton`, `WatchLink` (phone side of WatchConnectivity) |
| `Watch/` | Watch app: `WatchLibrary`, `WatchLink` (receives books), `WatchRootView`, `WatchPlayerView` |
| `scripts/` | `make-icon.swift` (the icon), `install-iphone.sh`, `run-simulators.sh`, `bump-build.sh` |
| `project.yml` | XcodeGen spec → `Audiobug.xcodeproj` (schemes `Audiobug`, `AudiobugWatch`) |

## Build & run

```sh
brew install xcodegen
cd Packages/AudiobugCore && swift test              # core tests (Mac)
xcodegen generate                                   # Audiobug.xcodeproj
scripts/run-simulators.sh ~/Dev/ebooker/out/_tests/omw_ch1.m4b   # paired iPhone + Watch simulators
scripts/install-iphone.sh                           # signed build onto the iPhone (Watch app follows via the Watch app)
```

UI tests (XCUITest; the simulators need the sample books seeded as `run-simulators.sh` does):

```sh
xcodebuild test -scheme Audiobug -destination 'id=<iphone-sim>' -only-testing:AudiobugUITests/AudiobugFlowTests/testPlayerFlow
xcodebuild test -scheme Audiobug -destination 'id=<iphone-sim-paired-with-watch>' -only-testing:AudiobugUITests/AudiobugFlowTests/testSendToWatch
xcodebuild test -scheme AudiobugWatch -destination 'id=<watch-sim>'
```

The Simulator never delivers WatchConnectivity *file* transfers to the Watch app (Apple: "always test file transfers on
paired devices"), so `testSendToWatch` only proves the iPhone side; position sync and the Watch's book list do work
between paired simulators. Test the actual book transfer on real devices.

The icon: `swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/icon-1024.png`, then copy it to
`Watch/Assets.xcassets/AppIcon.appiconset/`.

Notes:
- iCloud only re-reads `NSUbiquitousContainers` when the build number changes, so `install-iphone.sh` bumps it.
  The *Audiobug* folder appears in iCloud Drive after the app has been opened once on a device signed into iCloud.
- The Watch app installs with the iPhone app when *Watch › General › Automatic App Install* is on; otherwise install
  it from *My Watch › Available Apps*.
