import AudiobugCore
import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        InboxBackgroundImport.register()   // BGTaskScheduler requires registration during launch
        DiagFile.shared.install()
        Diag.log("iPhone launched")
        WatchLink.shared.activate()        // so background launches (Watch positions, transfer completions) are received
        if DeveloperBuild.isDeveloper { CrashReporter.shared.start() }
        #if DEBUG
        // AUDIOBUG_UPLOAD_AUTOSTART=1: switch the Wi-Fi upload server on at launch (simulator testing with curl).
        if ProcessInfo.processInfo.environment["AUDIOBUG_UPLOAD_AUTOSTART"] != nil { UploadServer.shared.start() }
        // AUDIOBUG_FEEDBACK_SELFTEST=1 AUDIOBUG_FEEDBACK_DIR=<dir>: write a sample note there (checks the format).
        if ProcessInfo.processInfo.environment["AUDIOBUG_FEEDBACK_SELFTEST"] != nil {
            Task.detached {
                do { try ImprovementNotes.add("Self-test note\nsecond line", where: "Self-test, Chapter 1, at 0:12 of 1:00:00, 1×", file: "Book.m4b") }
                catch { Diag.log("self-test note failed: \(error)") }
            }
        }
        #endif
        return true
    }
}

@main
struct AudiobugApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var library = LibraryStore()
    @State private var player = Player()
    @State private var watch = WatchLink.shared

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(player)
                .environment(watch)
                .environment(Settings.shared)
                .environment(UploadServer.shared)
                .onAppear { wire() }
                .onOpenURL { url in
                    // "Open in Audiobug" from Files, Mail, AirDrop…
                    if let book = library.importFiles([url]).first { library.open(book) }
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        library.startWatchingInbox()
                        watch.activate()
                    case .background:
                        library.stopWatchingInbox()
                        player.savePosition(force: true)
                        InboxBackgroundImport.schedule()
                    default: break
                    }
                }
        }
    }

    private func wire() {
        player.onPositionSaved = { [watch] position in watch.send(position: position) }
        watch.onRemotePosition = { [player] position in player.apply(remote: position) }
        watch.activate()
    }
}
