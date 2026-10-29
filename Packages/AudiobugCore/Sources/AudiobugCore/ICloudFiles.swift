import Foundation

/// Coordinated file operations and download handling for iCloud Drive (also correct for local folders).
public enum ICloudFiles {
    public struct DownloadTimeout: LocalizedError {
        public var errorDescription: String? { "Timed out downloading from iCloud" }
    }

    /// The container's public Documents folder, or nil if iCloud Drive is unavailable. Blocks; call off the main thread.
    public static func documentsDirectory(containerIdentifier: String?) -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)?.appending(path: "Documents")
    }

    /// Audiobooks are big: allow up to 30 minutes for a download, but stop as soon as the file is gone.
    public static func ensureDownloaded(_ url: URL) async throws {
        guard FileManager.default.isUbiquitousItem(at: url) else { return }
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(30 * 60)
        let placeholder = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).icloud")
        while Date() < deadline {
            // Gone (another device imported it meanwhile): stop waiting instead of spinning until the deadline.
            if !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: placeholder.path) {
                throw CocoaError(.fileNoSuchFile)
            }
            var copy = url
            copy.removeAllCachedResourceValues()
            let status = try? copy.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            if status == .current || status == .downloaded { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw DownloadTimeout()
    }

    static func coordinate(_ body: (NSFileCoordinator, inout NSError?) -> Void) throws {
        var error: NSError?
        body(NSFileCoordinator(), &error)
        if let error { throw error }
    }

    public static func coordinatedCopy(_ source: URL, to destination: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: .forReplacing, error: &e) { r, w in
                do { try FileManager.default.copyItem(at: r, to: w) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    public static func coordinatedDelete(_ url: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(writingItemAt: url, options: .forDeleting, error: &e) { u in
                do { try FileManager.default.removeItem(at: u) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    public static func coordinatedMove(_ source: URL, to destination: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: .forReplacing, error: &e) { s, d in
                do { try FileManager.default.moveItem(at: s, to: d) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }

    public static func coordinatedCreateDirectory(_ url: URL) throws {
        var inner: Error?
        try coordinate { c, e in
            c.coordinate(writingItemAt: url, options: [], error: &e) { u in
                do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) } catch { inner = error }
            }
        }
        if let inner { throw inner }
    }
}
