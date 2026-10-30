import AudiobugCore
import Foundation
import Network
import UIKit
import os

private let log = Logger(subsystem: "com.romadinov.audiobug", category: "UploadServer")

/// An upload in flight, shown in the library while it lasts.
struct UploadProgress: Identifiable, Equatable {
    let id: UUID
    let name: String
    let folder: String
    var received: Int64
    let total: Int64
    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
}

/// What the web page shows about the library.
struct UploadLibrarySnapshot: Encodable {
    struct Book: Encodable { let title: String; let folder: String; let size: Int64 }
    var folders: [String]
    var books: [Book]
}

/// "Wi-Fi Upload": an HTTP server you switch on in the app. Open `http://<iPhone address>:8080` in a browser on the
/// same network and drop audiobooks on the page (or `curl -T Book.m4b http://…/upload/Book.m4b?folder=Fiction`);
/// every file lands in Documents/Books and the library reloads. The screen stays on while the server runs — iOS
/// suspends the app, and with it the server, soon after it leaves the foreground (unless a book is playing).
@MainActor @Observable
final class UploadServer {
    static let shared = UploadServer()
    static let preferredPort: UInt16 = 8080

    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var port: UInt16 = 0
    private(set) var addresses: [String] = []
    private(set) var uploads: [UploadProgress] = []
    /// Files added since the server was switched on, newest first.
    private(set) var imported: [String] = []
    var lastError: String?
    /// Called on the main actor with every file that was uploaded and moved into the library.
    var onImported: ((URL) -> Void)?
    var librarySnapshot: (() -> UploadLibrarySnapshot)?
    /// Title of the book already in the library with this id (uploads of a book you have are refused).
    var existingTitle: ((String) -> String?)?

    @ObservationIgnored private var engine: UploadEngine?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    var urls: [String] { addresses.map { "http://\($0)\(port == 80 ? "" : ":\(port)")" } }

    func start() {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        lastError = nil
        let engine = UploadEngine(library: LibraryPaths.books, events: events)
        self.engine = engine
        Task {
            do {
                port = try await engine.start(preferring: Self.preferredPort)
                refreshAddresses()
                isRunning = true
                imported = []
                UIApplication.shared.isIdleTimerDisabled = true
                Diag.log("Upload server listening on \(port): \(urls.joined(separator: " "))")
            } catch {
                self.engine = nil
                lastError = "Couldn't start the upload server: \(error.localizedDescription)"
                log.error("start failed: \(error.localizedDescription, privacy: .public)")
            }
            isStarting = false
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
        port = 0
        uploads = []
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        Diag.log("Upload server stopped")
    }

    func toggle() { isRunning ? stop() : start() }

    /// Wi-Fi addresses can change while the server runs (e.g. after switching networks).
    func refreshAddresses() {
        addresses = WiFiServer.ipv4Addresses()
    }

    // MARK: Engine events (arrive on the engine's queue)

    private var events: UploadEngine.Events {
        Events(
            started: { progress in Task { @MainActor in self.began(progress) } },
            progressed: { id, received in Task { @MainActor in self.progressed(id, received: received) } },
            finished: { id, url in Task { @MainActor in self.finished(id, url: url) } },
            snapshot: { await MainActor.run { self.librarySnapshot?() ?? UploadLibrarySnapshot(folders: [], books: []) } },
            existingTitle: { id in await MainActor.run { self.existingTitle?(id) } }
        )
    }
    private typealias Events = UploadEngine.Events

    private func began(_ progress: UploadProgress) {
        uploads.append(progress)
        beginBackgroundTask()
    }

    private func progressed(_ id: UUID, received: Int64) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[index].received = received
    }

    private func finished(_ id: UUID, url: URL?) {
        uploads.removeAll { $0.id == id }
        if let url {
            imported.insert(url.lastPathComponent, at: 0)
            onImported?(url)
        }
        if uploads.isEmpty { endBackgroundTask() }
    }

    /// Extra background time so an upload survives a short trip to the lock screen.
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "UploadServer") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

// MARK: - Engine

/// The networking: HTTP/1.1 over NWListener, one request per connection (`Connection: close`).
final class UploadEngine: @unchecked Sendable {
    struct Events: Sendable {
        let started: @Sendable (UploadProgress) -> Void
        let progressed: @Sendable (UUID, Int64) -> Void
        /// `url` is the file's final place in the library, nil when the upload failed.
        let finished: @Sendable (UUID, URL?) -> Void
        let snapshot: @Sendable () async -> UploadLibrarySnapshot
        /// The title of the library book with this `BookFingerprint.id`, if there is one.
        let existingTitle: @Sendable (String) async -> String?
    }

    private let queue = DispatchQueue(label: "com.romadinov.audiobug.upload")
    private let library: URL
    private let events: Events
    private var listener: NWListener?
    private let staging = FileManager.default.temporaryDirectory.appending(path: "Uploads")

    init(library: URL, events: Events) {
        self.library = library
        self.events = events
    }

    /// Listens on `preferred` if free, else on any port; returns the port.
    func start(preferring preferred: UInt16) async throws -> UInt16 {
        do { return try await listen(on: NWEndpoint.Port(rawValue: preferred)!) }
        catch { log.notice("port \(preferred) unavailable (\(error.localizedDescription, privacy: .public)), using any"); return try await listen(on: .any) }
    }

    private func listen(on port: NWEndpoint.Port) async throws -> UInt16 {
        listener?.cancel()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error): once.run { continuation.resume(throwing: error) }
                case .cancelled: once.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: Requests

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func readHead() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    let body = buffer[end.upperBound...]
                    guard let head = HTTPRequestHead(text) else { self.reply(connection, 400, text: "Bad request"); return }
                    self.route(head, firstBody: Data(body), on: connection)
                } else if complete || error != nil || buffer.count > 65536 {
                    connection.cancel()
                } else {
                    readHead()
                }
            }
        }
        readHead()
    }

    private func route(_ head: HTTPRequestHead, firstBody: Data, on connection: NWConnection) {
        switch (head.method, head.path) {
        case ("GET", "/"), ("HEAD", "/"):
            reply(connection, 200, type: "text/html; charset=utf-8", body: Data(UploadPage.html.utf8), headOnly: head.method == "HEAD")
        case ("GET", "/api/library"):
            Task {
                let snapshot = await events.snapshot()
                let json = (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
                queue.async { self.reply(connection, 200, type: "application/json", body: json) }
            }
        case ("PUT", _), ("POST", _):
            guard head.path.hasPrefix("/upload/") else { reply(connection, 404, text: "Not found"); return }
            receiveUpload(head, firstBody: firstBody, on: connection)
        default:
            reply(connection, head.path.hasPrefix("/upload/") ? 405 : 404, text: head.path.hasPrefix("/upload/") ? "Use PUT" : "Not found")
        }
    }

    private func receiveUpload(_ head: HTTPRequestHead, firstBody: Data, on connection: NWConnection) {
        guard let name = HTTPRequestHead.safeFileName(String(head.path.dropFirst("/upload/".count))) else {
            reply(connection, 400, text: "Missing file name"); return
        }
        guard let folder = HTTPRequestHead.safeFolder(head.query["folder"] ?? "") else {
            reply(connection, 400, text: "Bad folder name"); return
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guard ext.isEmpty || AudiobookFormat.extensions.contains(ext) else {
            reply(connection, 415, text: "\(name) isn't an audiobook file (expected M4B, M4A, MP3…)"); return
        }
        guard let total = head.contentLength else { reply(connection, 411, text: "Content-Length required"); return }
        guard total > 0 else { reply(connection, 400, text: "Empty file"); return }
        let id = UUID()
        let temp = staging.appending(path: id.uuidString)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            reply(connection, 500, text: "Couldn't create a temporary file: \(error.localizedDescription)"); return
        }
        guard let handle = try? FileHandle(forWritingTo: temp) else { reply(connection, 500, text: "Couldn't open a temporary file"); return }
        Diag.log("Upload started: \(name) (\(total) bytes) folder=\(folder.isEmpty ? "/" : folder) from \(String(describing: connection.endpoint))")
        events.started(UploadProgress(id: id, name: name, folder: folder, received: 0, total: total))

        var received: Int64 = 0
        var lastReported: Int64 = 0
        func fail(_ status: Int, _ message: String) {
            try? handle.close()
            try? FileManager.default.removeItem(at: temp)
            Diag.log("Upload failed: \(name): \(message)")
            events.finished(id, nil)
            reply(connection, status, text: message)
        }
        func finish() {
            try? handle.close()
            Task {
                if let bookID = try? BookFingerprint.id(for: temp), let title = await events.existingTitle(bookID) {
                    queue.async { fail(409, "Already in the library as “\(title)”") }
                    return
                }
                queue.async {
                    do {
                        let url = try self.place(temp, name: name, folder: folder)
                        Diag.log("Upload done: \(url.lastPathComponent) → \(folder.isEmpty ? "/" : folder)")
                        self.events.finished(id, url)
                        let info = ["name": url.lastPathComponent, "folder": folder, "size": "\(total)"]
                        self.reply(connection, 201, type: "application/json", body: (try? JSONEncoder().encode(info)) ?? Data())
                    } catch {
                        fail(415, error.localizedDescription)
                    }
                }
            }
        }
        func write(_ chunk: Data) -> Bool {
            do { try handle.write(contentsOf: chunk) } catch { fail(500, "Couldn't write: \(error.localizedDescription)"); return false }
            received += Int64(chunk.count)
            if received - lastReported >= 1 << 18 || received == total { lastReported = received; events.progressed(id, received) }
            return true
        }
        func readMore() {
            let remaining = total - received
            if remaining <= 0 { finish(); return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: Int(min(remaining, 1 << 20))) { data, _, complete, error in
                if let data, !data.isEmpty, !write(data) { return }
                if let error { fail(400, "Connection lost: \(error.localizedDescription)"); return }
                if total - received <= 0 { finish(); return }
                if complete { fail(400, "Connection closed after \(received) of \(total) bytes"); return }
                readMore()
            }
        }
        if !firstBody.isEmpty {
            guard write(firstBody.prefix(Int(min(Int64(firstBody.count), total)))) else { return }
        }
        if head.expectsContinue, received < total {
            connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in readMore() })
        } else {
            readMore()
        }
    }

    /// Moves a finished upload into the library; files without an extension are recognised by their contents.
    private func place(_ temp: URL, name: String, folder: String) throws -> URL {
        var name = name
        if (name as NSString).pathExtension.isEmpty {
            guard let ext = AudiobookFormat.sniffExtension(temp) else {
                throw NSError(domain: "Audiobug", code: 415, userInfo: [NSLocalizedDescriptionKey: "\(name) isn't an audiobook file"])
            }
            name += ".\(ext)"
        }
        let directory = folder.isEmpty ? library : library.appending(path: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = LibraryFiles.uniqueURL(for: name, in: directory)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }

    // MARK: Replies

    private func reply(_ connection: NWConnection, _ status: Int, text: String) {
        reply(connection, status, type: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    private func reply(_ connection: NWConnection, _ status: Int, type: String, body: Data, headOnly: Bool = false) {
        let reasons = [200: "OK", 201: "Created", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed",
                       409: "Conflict", 411: "Length Required", 415: "Unsupported Media Type", 500: "Internal Server Error"]
        var data = Data("HTTP/1.1 \(status) \(reasons[status] ?? "")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        if !headOnly { data.append(body) }
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
