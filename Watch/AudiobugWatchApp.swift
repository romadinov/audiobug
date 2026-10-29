import SwiftUI
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask, urlTask.sessionIdentifier == WiFiDownloader.sessionIdentifier {
                // Touching the shared downloader re-creates the background session, which delivers its events.
                WiFiDownloader.shared.backgroundEventsDone = { urlTask.setTaskCompletedWithSnapshot(false) }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

@main
struct AudiobugWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var library: WatchLibrary
    @State private var player = Player()
    @State private var link = WatchLink.shared

    init() {
        // WatchConnectivity launches the app in the background to deliver files from the iPhone; the session
        // must be activated at launch (not when a view appears) or the transfer stalls (WWDC21 session 10003).
        let library = WatchLibrary()
        _library = State(initialValue: library)
        WatchLink.shared.library = library
        WatchLink.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(library)
                .environment(player)
                .environment(link)
                .environment(Settings.shared)
                .onAppear { wire() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { player.savePosition(force: true) }
                    if phase == .active { library.reload() }
                }
        }
    }

    private func wire() {
        link.onRemotePosition = { [player] position in player.apply(remote: position) }
        player.onPositionSaved = { [link] position in link.send(position: position) }
        link.activate()
    }
}
