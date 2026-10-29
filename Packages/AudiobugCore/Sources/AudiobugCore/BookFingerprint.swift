import CryptoKit
import Foundation

/// A stable identity for a book file: the same file has the same id on every device, whatever it is named
/// or wherever it sits. Hashes the size plus the first and last 256 KB, so even a 500 MB book is quick.
public enum BookFingerprint {
    public static func id(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let window: UInt64 = 256 * 1024
        var hasher = SHA256()
        hasher.update(data: withUnsafeBytes(of: size.littleEndian) { Data($0) })
        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: Int(min(window, size))) { hasher.update(data: head) }
        if size > window {
            try handle.seek(toOffset: size - window)
            if let tail = try handle.read(upToCount: Int(window)) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
