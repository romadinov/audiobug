import Foundation

/// Where a listener is in a book. Synced between the iPhone and the Watch by `updatedAt` (newest wins).
public struct PlaybackPosition: Codable, Sendable, Equatable {
    public var bookID: String
    public var time: TimeInterval
    public var duration: TimeInterval?
    public var rate: Float?
    public var finished: Bool
    public var updatedAt: Date
    public var device: String

    public init(bookID: String, time: TimeInterval, duration: TimeInterval? = nil, rate: Float? = nil,
                finished: Bool = false, updatedAt: Date = Date(), device: String) {
        self.bookID = bookID
        self.time = time
        self.duration = duration
        self.rate = rate
        self.finished = finished
        self.updatedAt = updatedAt
        self.device = device
    }

    /// 0…1, when the duration is known.
    public var fraction: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, max(0, time / duration))
    }

    public var dictionary: [String: Any] {
        var d: [String: Any] = ["bookID": bookID, "time": time, "finished": finished,
                                "updatedAt": updatedAt.timeIntervalSince1970, "device": device]
        if let duration { d["duration"] = duration }
        if let rate { d["rate"] = rate }
        return d
    }

    public init?(dictionary d: [String: Any]) {
        guard let bookID = d["bookID"] as? String, let time = d["time"] as? TimeInterval,
              let updated = d["updatedAt"] as? TimeInterval, let device = d["device"] as? String else { return nil }
        self.init(bookID: bookID, time: time, duration: d["duration"] as? TimeInterval,
                  rate: (d["rate"] as? NSNumber)?.floatValue, finished: d["finished"] as? Bool ?? false,
                  updatedAt: Date(timeIntervalSince1970: updated), device: device)
    }
}

/// Positions for every book, in one JSON file. Thread-safe; writes are immediate (the file is tiny).
public final class PositionStore: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var positions: [String: PlaybackPosition]

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let decoded = try? Self.decoder.decode([String: PlaybackPosition].self, from: data) {
            positions = decoded
        } else {
            positions = [:]
        }
    }

    public func position(for bookID: String) -> PlaybackPosition? {
        lock.lock(); defer { lock.unlock() }
        return positions[bookID]
    }

    public var all: [PlaybackPosition] {
        lock.lock(); defer { lock.unlock() }
        return Array(positions.values)
    }

    /// Saves unconditionally (this device just listened).
    public func save(_ position: PlaybackPosition) {
        lock.lock(); defer { lock.unlock() }
        positions[position.bookID] = position
        persist()
    }

    /// Applies a position from another device if it is newer than ours. Returns true when applied.
    @discardableResult
    public func merge(_ remote: PlaybackPosition) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let local = positions[remote.bookID], local.updatedAt >= remote.updatedAt { return false }
        positions[remote.bookID] = remote
        persist()
        return true
    }

    public func remove(_ bookID: String) {
        lock.lock(); defer { lock.unlock() }
        positions[bookID] = nil
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(positions) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}

extension PositionStore {
    /// Decoding tolerates the ISO-8601 dates written by `persist` and the numeric ones from older files.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let date = ISO8601DateFormatter().date(from: s) { return date }
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self))
        }
        return d
    }()
}
