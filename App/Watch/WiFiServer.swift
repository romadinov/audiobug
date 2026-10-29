import Foundation
import Network
import os

private let log = Logger(subsystem: "com.romadinov.audiobug", category: "WiFiServer")

/// A minimal HTTP/1.1 file server on the iPhone, so the Watch can pull a book over Wi-Fi instead of the
/// WatchConnectivity (Bluetooth) link. Only files that were explicitly offered are served, under random tokens.
final class WiFiServer: @unchecked Sendable {
    static let shared = WiFiServer()

    private let queue = DispatchQueue(label: "com.romadinov.audiobug.wifiserver")
    private let lock = NSLock()
    private var listener: NWListener?
    private var offers: [String: URL] = [:]

    /// Starts listening (if not already) and returns the port.
    func start() async throws -> UInt16 {
        if let listener, listener.state == .ready, let port = listener.port?.rawValue { return port }
        listener?.cancel()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] in
            Diag.log("HTTP connection from \(String(describing: $0.endpoint))")
            self?.serve($0)
        }
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { state in
                Diag.log("HTTP listener state=\(String(describing: state)) port=\(listener.port?.rawValue ?? 0)")
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
        lock.lock(); offers.removeAll(); lock.unlock()
    }

    /// Makes `url` downloadable at `/<token>`.
    func offer(_ url: URL) -> String {
        let token = UUID().uuidString.lowercased()
        lock.lock(); offers[token] = url; lock.unlock()
        return token
    }

    func revoke(_ token: String) {
        lock.lock(); offers[token] = nil; lock.unlock()
    }

    /// The phone's IPv4 addresses, Wi-Fi (en0) first; cellular and tunnel interfaces are skipped.
    static func ipv4Addresses() -> [String] {
        var found: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard !["pdp_ip", "utun", "ipsec", "llw", "awdl", "bridge"].contains(where: { name.hasPrefix($0) }) else { continue }
            found.append((name, String(cString: host)))
        }
        return found.sorted { ($0.name == "en0" ? 0 : 1) < ($1.name == "en0" ? 0 : 1) }.map(\.address)
    }

    // MARK: - HTTP

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        func readHeader() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    self.respond(connection, request: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
                } else if complete || error != nil || buffer.count > 65536 {
                    connection.cancel()
                } else {
                    readHeader()
                }
            }
        }
        readHeader()
    }

    private func respond(_ connection: NWConnection, request: String) {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        let token = parts.count > 1 ? String(parts[1].dropFirst()) : ""
        lock.lock(); let url = offers[token]; lock.unlock()
        guard method == "GET" || method == "HEAD", let url,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url) else {
            Diag.log("HTTP refused \(method) /\(token)")
            let reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        Diag.log("HTTP serving \(url.lastPathComponent) (\(size) bytes) to \(String(describing: connection.endpoint))")
        let header = "HTTP/1.1 200 OK\r\nContent-Type: audio/mp4\r\nContent-Length: \(size)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil || method == "HEAD" { try? handle.close(); connection.cancel(); return }
            self?.stream(handle, to: connection)
        })
    }

    private func stream(_ handle: FileHandle, to connection: NWConnection) {
        let chunk = handle.readData(ofLength: 1 << 19)
        if chunk.isEmpty {
            try? handle.close()
            Diag.log("HTTP finished sending to \(String(describing: connection.endpoint))")
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if let error { Diag.log("HTTP send failed: \(error.localizedDescription)"); try? handle.close(); connection.cancel(); return }
            self?.stream(handle, to: connection)
        })
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
