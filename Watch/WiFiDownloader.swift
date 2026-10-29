import AudiobugCore
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.romadinov.audiobug.watch", category: "WiFiDownloader")

/// Pulls a book from the iPhone's Wi-Fi server (see the iPhone's `WiFiServer`) with URLSession,
/// measuring throughput so the two transfer paths can be compared.
@MainActor @Observable
final class WiFiDownloader: NSObject {
    static let shared = WiFiDownloader()

    struct Job {
        let bookID: String
        let title: String
        let name: String
        let relative: String
        let position: [String: Any]?
        let urls: [String]
        var index = 0
        var started = Date()

        init?(_ offer: [String: Any]) {
            guard let id = offer["id"] as? String, let urls = offer["urls"] as? [String], !urls.isEmpty else { return nil }
            bookID = id
            title = offer["title"] as? String ?? "Book"
            name = offer["name"] as? String ?? "book.m4b"
            relative = offer["relative"] as? String ?? name
            position = offer["position"] as? [String: Any]
            self.urls = urls
        }
    }

    private(set) var current: Job?
    private(set) var fraction = 0.0
    private(set) var bytesPerSecond = 0.0
    private(set) var bytes: Int64 = 0

    /// Called about once a second while downloading: (bookID, fraction, bytesPerSecond).
    var onProgress: ((String, Double, Double) -> Void)?
    /// Called at the end with the temporary file (nil on failure), the error text, and elapsed seconds.
    var onDone: ((Job, URL?, String?, TimeInterval, Int64) -> Void)?

    static let sessionIdentifier = "com.romadinov.audiobug.watch.wifi"
    private static let jobKey = "wifiJob"

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var lastReport = Date.distantPast
    /// Completion of a `WKURLSessionRefreshBackgroundTask`, called once the session has delivered its events.
    @ObservationIgnored var backgroundEventsDone: (() -> Void)?

    override init() {
        super.init()
        // A background session keeps downloading while the Watch app is asleep (wrist down) or suspended.
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        // Pick up a job left from a previous launch (the download may still be running or finished).
        if let saved = UserDefaults.standard.dictionary(forKey: Self.jobKey), let job = Job(saved) {
            current = job
            session.getAllTasks { [weak self] tasks in
                Task { @MainActor in
                    guard let self else { return }
                    if let running = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first {
                        self.task = running
                    } else if self.current != nil, self.bytes == 0 {
                        // Nothing in flight and nothing delivered: start over.
                        self.startCurrent()
                    }
                }
            }
        }
    }

    func start(_ offer: [String: Any]) {
        guard let job = Job(offer) else { return }
        task?.cancel()
        current = job
        UserDefaults.standard.set(offer, forKey: Self.jobKey)
        fraction = 0; bytesPerSecond = 0; bytes = 0
        startCurrent()
    }

    func cancel() {
        task?.cancel()
        task = nil
        current = nil
        UserDefaults.standard.removeObject(forKey: Self.jobKey)
    }

    private func startCurrent() {
        guard var job = current, job.index < job.urls.count, let url = URL(string: job.urls[job.index]) else { return }
        job.started = Date()
        current = job
        Diag.log("download attempt \(job.index + 1)/\(job.urls.count): \(url.absoluteString)")
        let task = session.downloadTask(with: url)
        self.task = task
        task.resume()
        Diag.log("download task resumed state=\(task.state.rawValue)")
    }

    private func failedAttempt(_ error: Error) {
        guard var job = current else { return }
        Diag.log("download attempt \(job.index + 1) failed after \(bytes) bytes: \(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))")
        if job.index + 1 < job.urls.count, bytes == 0 {
            job.index += 1
            current = job
            startCurrent()
        } else {
            current = nil
            UserDefaults.standard.removeObject(forKey: Self.jobKey)
            onDone?(job, nil, error.localizedDescription, Date().timeIntervalSince(job.started), bytes)
        }
    }
}

extension WiFiDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            guard let job = current else { return }
            let elapsed = max(Date().timeIntervalSince(job.started), 0.001)
            bytes = totalBytesWritten
            bytesPerSecond = Double(totalBytesWritten) / elapsed
            fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
            if Date().timeIntervalSince(lastReport) >= 1 {
                lastReport = Date()
                Diag.log("download \(Int(fraction * 100))% \(totalBytesWritten)/\(totalBytesExpectedToWrite) \(SyncMessages.rate(bytesPerSecond))")
                onProgress?(job.bookID, fraction, bytesPerSecond)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns: park the file somewhere of ours first.
        let parked = FileManager.default.temporaryDirectory.appending(path: "wifi-\(UUID().uuidString).m4b")
        let moved: URL? = (try? FileManager.default.moveItem(at: location, to: parked)) != nil ? parked : nil
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        Diag.log("download finished status=\(status) parked=\(moved != nil)")
        Task { @MainActor in
            guard let job = current else { return }
            let elapsed = Date().timeIntervalSince(job.started)
            guard let moved, (200..<300).contains(status) else {
                try? moved.map { try FileManager.default.removeItem(at: $0) }
                failedAttempt(NSError(domain: "WiFiDownloader", code: status, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]))
                return
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: moved.path)[.size] as? NSNumber)?.int64Value ?? bytes
            current = nil
            task = nil
            UserDefaults.standard.removeObject(forKey: Self.jobKey)
            bytesPerSecond = Double(size) / max(elapsed, 0.001)
            onDone?(job, moved, nil, elapsed, size)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Diag.log("background session events delivered")
        Task { @MainActor in
            backgroundEventsDone?()
            backgroundEventsDone = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            if (error as NSError).code == NSURLErrorCancelled { return }
            failedAttempt(error)
        }
    }
}
