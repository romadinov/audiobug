import AudiobugCore
import Foundation
import Observation
import os
import WatchConnectivity
import WatchKit

private let log = Logger(subsystem: "com.romadinov.audiobug.watch", category: "WatchLink")

/// The Watch side of the connection: receives books from the iPhone, reports which ones it holds,
/// and keeps listening positions in step.
@MainActor @Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    private(set) var isReachable = false
    var lastError: String?
    var onRemotePosition: ((PlaybackPosition) -> Void)?
    @ObservationIgnored weak var library: WatchLibrary?
    @ObservationIgnored private var activated = false

    @ObservationIgnored private var pendingLog: [String] = []
    @ObservationIgnored private var logFlush: Task<Void, Never>?

    /// Batches diagnostics lines and sends them to the iPhone (which files them in iCloud Drive).
    private func forward(_ line: String) {
        pendingLog.append(line)
        guard logFlush == nil else { return }
        logFlush = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let lines = pendingLog
            pendingLog = []
            logFlush = nil
            let session = WCSession.default
            guard session.activationState == .activated, !lines.isEmpty else { return }
            let payload: [String: Any] = ["type": "log", "lines": lines]
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { _ in session.transferUserInfo(payload) }
            } else {
                session.transferUserInfo(payload)
            }
        }
    }

    func activate() {
        guard WCSession.isSupported(), !activated else { return }
        activated = true
        Diag.sink = { line in Task { @MainActor in WatchLink.shared.forward(line) } }
        Diag.log("Watch app launched")
        WCSession.default.delegate = self
        WCSession.default.activate()
        let downloader = WiFiDownloader.shared
        downloader.onProgress = { id, fraction, rate in
            let session = WCSession.default
            guard session.isReachable else { return }
            session.sendMessage(SyncMessages.wifiProgress(bookID: id, fraction: fraction, bytesPerSecond: rate), replyHandler: nil)
        }
        downloader.onDone = { [weak self] job, file, error, seconds, bytes in
            Diag.log("download ended: file=\(file?.lastPathComponent ?? "none") error=\(error ?? "none") seconds=\(Int(seconds)) bytes=\(bytes)")
            var failure = error
            if let file {
                do { try Self.store(file, name: job.name, relative: job.relative) } catch { failure = error.localizedDescription }
            }
            if failure == nil, let dict = job.position, let position = PlaybackPosition(dictionary: dict) {
                Positions.shared.merge(position)
            }
            if let failure { self?.lastError = "Wi-Fi download failed: \(failure)" }
            self?.library?.reload()
            self?.reportBooks()
            let done = SyncMessages.wifiDone(bookID: job.bookID, title: job.title, error: failure, seconds: seconds, bytes: bytes)
            let session = WCSession.default
            if session.isReachable {
                session.sendMessage(done, replyHandler: nil) { _ in session.transferUserInfo(done) }
            } else {
                session.transferUserInfo(done)
            }
        }
    }

    /// Moves a received file into the library, mirroring the iPhone's folder.
    nonisolated static func store(_ file: URL, name: String, relative: String) throws {
        let folder = LibraryPaths.books.appending(path: (relative as NSString).deletingLastPathComponent)
        let destination = folder.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: file, to: destination)
    }

    /// Tells the iPhone which books are here (it shows the Watch badge in its library).
    func reportBooks() {
        guard let library, WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(SyncMessages.booksContext(library.books))
    }

    /// Queues an improvement note for the iPhone (delivered even when it isn't reachable right now).
    func sendNote(_ text: String, where context: String, file: String?) {
        let device = WKInterfaceDevice.current()
        let payload = SyncMessages.note(text, where: context, file: file, device: "\(device.model), watchOS \(device.systemVersion)")
        WCSession.default.transferUserInfo(payload)
        Diag.log("note queued: \(text)")
    }

    func send(position: PlaybackPosition) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(SyncMessages.position(position), replyHandler: nil) { _ in
                session.transferUserInfo(SyncMessages.position(position))
            }
        } else {
            for pending in session.outstandingUserInfoTransfers
            where (pending.userInfo["type"] as? String) == "position"
                && ((pending.userInfo["position"] as? [String: Any])?["bookID"] as? String) == position.bookID {
                pending.cancel()
            }
            session.transferUserInfo(SyncMessages.position(position))
        }
    }

    private func handle(_ payload: [String: Any]) {
        Diag.log("received \(payload["type"] as? String ?? "?")")
        switch payload["type"] as? String {
        case "position":
            if let dict = payload["position"] as? [String: Any], let position = PlaybackPosition(dictionary: dict),
               Positions.shared.merge(position) {
                onRemotePosition?(position)
            }
        case "remove":
            if let id = payload["id"] as? String, let book = library?.books.first(where: { $0.id == id }) {
                library?.delete(book)
                reportBooks()
            }
        case "askBooks":
            reportBooks()
        case "wifiOffer":
            WiFiDownloader.shared.start(payload)
        default: break
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Diag.log("WCSession activated state=\(activationState.rawValue) reachable=\(session.isReachable) error=\(error?.localizedDescription ?? "none")")
        Task { @MainActor in
            isReachable = session.isReachable
            if let error { lastError = error.localizedDescription }
            reportBooks()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Diag.log("iPhone reachable=\(session.isReachable)")
        Task { @MainActor in isReachable = session.isReachable }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this returns, so move it synchronously on this thread.
        let metadata = file.metadata ?? [:]
        if SyncMessages.isCover(metadata) {
            guard let id = metadata["id"] as? String, let data = try? Data(contentsOf: file.fileURL) else { return }
            Diag.log("cover received for \(id): \(data.count) bytes")
            Task { @MainActor in CoverStore.shared.store(received: data, for: id) }
            return
        }
        let name = metadata["name"] as? String ?? file.fileURL.lastPathComponent
        let relative = metadata["relative"] as? String ?? name
        var failure: String?
        do {
            try Self.store(file.fileURL, name: name, relative: relative)
        } catch {
            failure = error.localizedDescription
        }
        Task { @MainActor in
            if let failure {
                lastError = "Couldn't store \(name): \(failure)"
            } else if let dict = metadata["position"] as? [String: Any], let position = PlaybackPosition(dictionary: dict) {
                Positions.shared.merge(position)
            }
            library?.reload()
            reportBooks()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in handle(userInfo) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in handle(message) }
    }
}
