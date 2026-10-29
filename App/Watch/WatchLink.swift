import AudiobugCore
import Foundation
import Observation
import UIKit
import os
import WatchConnectivity

private let log = Logger(subsystem: "com.romadinov.audiobug", category: "WatchLink")

/// The iPhone side of the Watch connection: sends books (file transfers), keeps positions in step, and
/// knows which books the Watch holds.
@MainActor @Observable
final class WatchLink: NSObject {
    static let shared = WatchLink()

    private(set) var isPaired = false
    private(set) var isAppInstalled = false
    /// id → title of the books currently on the Watch (as reported by the Watch).
    private(set) var booksOnWatch: [String: String] = [:]
    /// bookID → 0…1 for transfers in flight.
    private(set) var transfers: [String: Double] = [:]
    /// bookID → progress of Wi-Fi pulls in flight (test path, see `WiFiServer`).
    private(set) var wifiTransfers: [String: WiFiProgress] = [:]
    var lastError: String?

    struct WiFiProgress { var fraction: Double; var bytesPerSecond: Double; let token: String }
    var onRemotePosition: ((PlaybackPosition) -> Void)?

    @ObservationIgnored private var observations: [String: NSKeyValueObservation] = [:]
    @ObservationIgnored private var activated = false

    var isAvailable: Bool { WCSession.isSupported() && isPaired && isAppInstalled }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if !activated {
            activated = true
            session.delegate = self
            session.activate()
        } else {
            refreshState()
        }
    }

    private func refreshState() {
        let session = WCSession.default
        isPaired = session.isPaired
        isAppInstalled = session.isWatchAppInstalled
        if isAppInstalled, let context = session.receivedApplicationContext["books"] as? [String: String] {
            booksOnWatch = context
        }
        for transfer in session.outstandingFileTransfers { track(transfer) }
        if isAvailable { session.transferUserInfo(SyncMessages.askBooks) }
    }

    func isOnWatch(_ book: Audiobook) -> Bool { booksOnWatch[book.id] != nil }

    /// Copies a book to the Watch (continues in the background; Bluetooth takes a while for big books).
    func send(_ book: Audiobook) {
        guard isAvailable else { lastError = "The Watch app isn't installed."; return }
        let session = WCSession.default
        guard !session.outstandingFileTransfers.contains(where: { ($0.file.metadata?["id"] as? String) == book.id }) else { return }
        let position = Positions.shared.position(for: book.id)
        let transfer = session.transferFile(book.url, metadata: SyncMessages.fileMetadata(book: book, position: position))
        transfers[book.id] = 0
        track(transfer)
        sendCover(book)
        log.info("Sending \(book.title, privacy: .public) to the Watch")
    }

    /// Sends the book's cover (as cached here, so a picture you chose goes too) if the Watch has or is receiving
    /// the book. Without a cached cover the Watch finds the book's own art itself.
    func sendCover(_ book: Audiobook) {
        guard isAvailable, isOnWatch(book) || transfers[book.id] != nil || wifiTransfers[book.id] != nil,
              let file = CoverStore.shared.fileIfPresent(for: book.id) else { return }
        let session = WCSession.default
        for pending in session.outstandingFileTransfers
        where SyncMessages.isCover(pending.file.metadata) && (pending.file.metadata?["id"] as? String) == book.id {
            pending.cancel()
        }
        session.transferFile(file, metadata: SyncMessages.coverMetadata(bookID: book.id))
    }

    /// Test path: serve the file over HTTP on the phone's Wi-Fi address and ask the Watch to download it.
    /// Needs the Watch app in the foreground (WCSession reachability) and the phone app kept open.
    func sendOverWiFi(_ book: Audiobook) {
        guard isAvailable else { lastError = "The Watch app isn't installed."; return }
        Task {
            do {
                let port = try await WiFiServer.shared.start()
                let addresses = WiFiServer.ipv4Addresses()
                guard !addresses.isEmpty else { lastError = "The iPhone has no Wi-Fi address."; return }
                let token = WiFiServer.shared.offer(book.url)
                let urls = addresses.map { "http://\($0):\(port)/\(token)" }
                wifiTransfers[book.id] = WiFiProgress(fraction: 0, bytesPerSecond: 0, token: token)
                let position = Positions.shared.position(for: book.id)
                let offer = SyncMessages.wifiOffer(book: book, position: position, urls: urls)
                let session = WCSession.default
                if session.isReachable {
                    // Live message when the Watch app is on screen; otherwise the queued channel wakes it.
                    session.sendMessage(offer, replyHandler: nil) { _ in session.transferUserInfo(offer) }
                } else {
                    session.transferUserInfo(offer)
                }
                keepServing()
                sendCover(book)
                Diag.log("Wi-Fi offer for \(book.title): \(urls.joined(separator: " ")) reachable=\(session.isReachable) size=\(book.fileSize)")
                log.info("Offered \(book.title, privacy: .public) over Wi-Fi at \(urls.joined(separator: " "), privacy: .public)")
            } catch {
                lastError = "Couldn't start the Wi-Fi server: \(error.localizedDescription)"
            }
        }
    }

    @ObservationIgnored private var servingTask: UIBackgroundTaskIdentifier = .invalid

    /// Asks iOS for extra background time so the server keeps answering if the phone is locked mid-transfer.
    private func keepServing() {
        guard servingTask == .invalid else { return }
        servingTask = UIApplication.shared.beginBackgroundTask(withName: "WiFiServer") { [weak self] in
            guard let self, self.servingTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(self.servingTask)
            self.servingTask = .invalid
        }
    }

    private func stopServingIfIdle() {
        guard wifiTransfers.isEmpty, servingTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(servingTask)
        servingTask = .invalid
    }

    func cancelWiFiSend(_ book: Audiobook) {
        if let token = wifiTransfers[book.id]?.token { WiFiServer.shared.revoke(token) }
        wifiTransfers[book.id] = nil
        stopServingIfIdle()
    }

    func cancelSend(_ book: Audiobook) {
        for transfer in WCSession.default.outstandingFileTransfers where (transfer.file.metadata?["id"] as? String) == book.id {
            transfer.cancel()
        }
        transfers[book.id] = nil
        observations[book.id] = nil
    }

    func remove(_ book: Audiobook) {
        guard isAvailable else { return }
        WCSession.default.transferUserInfo(SyncMessages.remove(bookID: book.id))
        booksOnWatch[book.id] = nil
    }

    func send(position: PlaybackPosition) {
        guard isAvailable, booksOnWatch[position.bookID] != nil else { return }
        let session = WCSession.default
        if session.isReachable {
            session.sendMessage(SyncMessages.position(position), replyHandler: nil) { _ in
                session.transferUserInfo(SyncMessages.position(position))
            }
        } else {
            // Keep only the latest position per book in the queue.
            for pending in session.outstandingUserInfoTransfers
            where (pending.userInfo["type"] as? String) == "position"
                && ((pending.userInfo["position"] as? [String: Any])?["bookID"] as? String) == position.bookID {
                pending.cancel()
            }
            session.transferUserInfo(SyncMessages.position(position))
        }
    }

    private func track(_ transfer: WCSessionFileTransfer) {
        guard !SyncMessages.isCover(transfer.file.metadata), let id = transfer.file.metadata?["id"] as? String else { return }
        transfers[id] = transfer.progress.fractionCompleted
        observations[id] = transfer.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in self?.transfers[id] = value }
        }
    }

    private func handle(_ payload: [String: Any]) {
        switch payload["type"] as? String {
        case "position":
            if let dict = payload["position"] as? [String: Any], let position = PlaybackPosition(dictionary: dict),
               Positions.shared.merge(position) {
                onRemotePosition?(position)
            }
        case "log":
            for line in payload["lines"] as? [String] ?? [] { DiagFile.shared.append(line) }
        case "note":
            guard let text = payload["text"] as? String else { return }
            let context = payload["where"] as? String ?? "Apple Watch"
            let file = payload["file"] as? String
            let device = payload["device"] as? String ?? "Apple Watch"
            let date = (payload["date"] as? TimeInterval).map(Date.init(timeIntervalSince1970:)) ?? Date()
            Task.detached(priority: .utility) {
                do { try ImprovementNotes.add(text, where: context, file: file, device: device, date: date) }
                catch { log.error("Couldn't file the Watch note: \(error.localizedDescription, privacy: .public)") }
            }
        case "wifiProgress":
            if let id = payload["id"] as? String, var p = wifiTransfers[id] {
                Diag.log("wifiProgress \(Int((payload["fraction"] as? Double ?? 0) * 100))% \(SyncMessages.rate(payload["rate"] as? Double ?? 0))")
                p.fraction = payload["fraction"] as? Double ?? p.fraction
                p.bytesPerSecond = payload["rate"] as? Double ?? p.bytesPerSecond
                wifiTransfers[id] = p
            }
        case "wifiDone":
            guard let id = payload["id"] as? String else { return }
            if let token = wifiTransfers[id]?.token { WiFiServer.shared.revoke(token) }
            wifiTransfers[id] = nil
            Diag.log("wifiDone received: \(payload)")
            let title = payload["title"] as? String ?? "book"
            let seconds = payload["seconds"] as? Double ?? 0
            let bytes = payload["bytes"] as? Int64 ?? Int64(payload["bytes"] as? Double ?? 0)
            if let error = payload["error"] as? String {
                lastError = "Wi-Fi transfer of \(title) failed after \(Int(seconds)) s: \(error)"
                log.error("Wi-Fi transfer failed: \(error, privacy: .public)")
            } else {
                booksOnWatch[id] = title
                let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                lastError = "Sent \(title) over Wi-Fi: \(size) in \(Int(seconds)) s (\(SyncMessages.rate(Double(bytes) / max(seconds, 0.001))))."
                log.info("Wi-Fi transfer done: \(bytes) bytes in \(seconds) s")
            }
            stopServingIfIdle()
        default: break
        }
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Diag.log("WCSession activated state=\(activationState.rawValue) paired=\(session.isPaired) installed=\(session.isWatchAppInstalled) reachable=\(session.isReachable) error=\(error?.localizedDescription ?? "none")")
        Task { @MainActor in
            if let error { lastError = error.localizedDescription }
            refreshState()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // the user switched to another Watch
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in refreshState() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            if let books = applicationContext["books"] as? [String: String] { booksOnWatch = books }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Diag.log("Watch reachable=\(session.isReachable)")
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if (userInfo["type"] as? String) != "log" { Diag.log("userInfo from Watch: \(userInfo["type"] as? String ?? "?")") }
        Task { @MainActor in handle(userInfo) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if (message["type"] as? String) != "log" { Diag.log("message from Watch: \(message["type"] as? String ?? "?")") }
        Task { @MainActor in handle(message) }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if SyncMessages.isCover(fileTransfer.file.metadata) {
            if let error { log.error("Cover transfer failed: \(error.localizedDescription, privacy: .public)") }
            return
        }
        let id = fileTransfer.file.metadata?["id"] as? String
        let title = fileTransfer.file.metadata?["title"] as? String ?? "book"
        Task { @MainActor in
            guard let id else { return }
            transfers[id] = nil
            observations[id] = nil
            if let error {
                lastError = "Couldn't send \(title) to the Watch: \(error.localizedDescription)"
                log.error("Transfer failed: \(error.localizedDescription, privacy: .public)")
            } else {
                booksOnWatch[id] = title
                log.info("Sent \(title, privacy: .public) to the Watch")
            }
        }
    }
}
