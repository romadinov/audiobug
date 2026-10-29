# Audiobug — working notes for Claude

Spec: README.md. Sibling projects: `~/Dev/reader` (Scriptorium; the iCloud Inbox scheme was copied from its
`InboxSync` / `InboxAutomation`), `~/Dev/tasker` (Uberdoer; icon style).

## Build, install, test
- Core: `cd Packages/AudiobugCore && swift build && swift test`.
- Apps: `xcodegen generate`, then `scripts/run-simulators.sh [book.m4b]` (paired simulators) or
  `scripts/install-iphone.sh` (signed, bumps the build number; the Watch app is embedded in the iPhone app).
- Compile-only: `xcodebuild -scheme Audiobug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
  and `-scheme AudiobugWatch -destination 'generic/platform=watchOS Simulator'`.
- UI tests: `UITests/` (iPhone) and `WatchUITests/` (Watch) are XCUITests; see README for the commands. Both simulators
  of a pair must be booted with the apps installed and books seeded. Rows in a watchOS List are `cells`, not `buttons`.
- The Simulator does not deliver WCSession file transfers to the Watch (Apple docs); positions / application context do
  sync between paired simulators. Verify "Send to Apple Watch" on real devices only.
- `log show` on a simulator can take 10+ minutes; prefer `--last 2m --info` with a narrow predicate, or `timeout`.
- Sample books: `~/Dev/ebooker/out/_tests/*.m4b` (small, with chapters). Seed a simulator by copying into
  `$(xcrun simctl get_app_container <udid> <bundle> data)/Documents/Books`.

## Conventions
- `Shared/` must compile for iOS and watchOS: no AVKit/UIKit views there; platform differences go behind `#if os(watchOS)`.
- Book identity is `BookFingerprint.id` (content hash), never the path — positions and Watch badges key on it.
- Positions: `Positions.shared` (JSON in Application Support); cross-device merges by `updatedAt`, newest wins.
- The Inbox mirrors library folders; never delete a non-empty Inbox folder (see `InboxSync.mirrorDelete`).
- Text written for the user: address the owner as "you"; never infer pronouns.
- If the Watch app "installs" in the Watch app and then bounces back to Available Apps, the embedded Watch profile lacks
  the Watch UDID (check `security cms -D -i …/Watch/AudiobugWatch.app/embedded.mobileprovision`). Register it with
  `xcodebuild -scheme AudiobugWatch -destination 'id=<watch udid>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration build`,
  then rerun `scripts/install-iphone.sh`. The Watch also needs Developer Mode on (Settings › Privacy & Security).
- WCSession is activated at launch (`AudiobugWatchApp.init`, iOS `AppDelegate`), never only in `onAppear`: WatchConnectivity
  launches the Watch app in the background to deliver a file, and a session activated only when a view appears stalls
  the transfer at 0 % (WWDC21 "There and back again", session 10003).
- Covers: `CoverStore` (Shared) caches a JPEG thumbnail per book id in Application Support/Audiobug/Covers (`<id>.jpg`,
  `<id>.none` = no art); custom covers are listed in UserDefaults `customCovers`. The iPhone sends the cached cover to
  the Watch as a WC file transfer with metadata `type: cover` — ignore those in book-transfer bookkeeping.
- On watchOS a plain VStack is not inset by the inline navigation title (only scroll views are); the Watch controls page
  is a ScrollView for that reason.
- Never seed the same M4B twice under different names: book ids are content hashes, so the rows get duplicate ForEach ids.

## Feedback from the app
- "Suggest an Improvement" (developer builds only: `DeveloperBuild.isDeveloper`) in the library ⋯ menu, the player's
  lightbulb and the Watch's More sheet appends to iCloud Drive › Audiobug › `Improvement notes.md` with
  `@where(<book>, <chapter>, at <time>…) @file(<book file>)`; crash reports go to `Crash reports/` (MetricKit). Same scheme
  as Uberdoer (`~/Dev/tasker/App/Shared/Feedback.swift`); the Watch sends its notes to the iPhone over WatchConnectivity.
- The app is registered in `~/Dev/agent-feedback/apps.json` with `repo: ~/Dev/ebooker`: notes are mostly narration
  corrections, so the router points at the ebooker session. If one is about the player itself, handle it here and record it
  with `swift ~/Dev/agent-feedback/feedback.swift notes audiobug "<text in note>" "<fix>"`; `crashes audiobug` lists crash
  reports. Never edit `Improvement notes.md` yourself.
- `AUDIOBUG_FEEDBACK_SELFTEST=1 AUDIOBUG_FEEDBACK_DIR=<dir>` (DEBUG, via `SIMCTL_CHILD_…` on a simulator) writes a sample note.
