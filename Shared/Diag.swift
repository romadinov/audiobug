import Foundation
import os

private let osLog = Logger(subsystem: "com.romadinov.audiobug", category: "Diag")

/// Lightweight diagnostics for things that only reproduce on real devices. Every line goes to os_log and to
/// `sink`: the Watch forwards its lines to the iPhone, and the iPhone appends everything to
/// iCloud Drive › Audiobug › Diagnostics › log.txt, which a Mac can read.
enum Diag {
    nonisolated(unsafe) static var sink: ((String) -> Void)?
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    #if os(watchOS)
    static let device = "watch"
    #else
    static let device = "phone"
    #endif

    static func log(_ message: String) {
        let line = "\(stamp.string(from: Date())) [\(device)] \(message)"
        osLog.info("\(message, privacy: .public)")
        sink?(line)
    }
}
