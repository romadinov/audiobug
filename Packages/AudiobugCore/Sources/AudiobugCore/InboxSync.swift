import Foundation

/// The iCloud Drive "Inbox": a folder tree mirroring the library where books can be dropped from any
/// device. `sync()` moves every book from the Inbox into the same folder of the library.
/// (The same scheme as Scriptorium's Inbox, for audiobooks.)
public struct InboxSync: Sendable {
    public struct Report: Sendable, Equatable {
        public var imported: [String] = []          // library-relative paths
        public var duplicates: [String] = []        // already in the library; removed from the Inbox
        public var foldersCreated: [String] = []    // new library folders from the Inbox
        public var skipped: [String] = []           // not a supported book; left in the Inbox
        public var failed: [String: String] = [:]   // inbox-relative path → error

        public init() {}

        public var summary: String {
            var parts: [String] = []
            if !imported.isEmpty { parts.append("\(imported.count) book\(imported.count == 1 ? "" : "s") imported") }
            if !foldersCreated.isEmpty { parts.append("\(foldersCreated.count) new folder\(foldersCreated.count == 1 ? "" : "s")") }
            if !duplicates.isEmpty { parts.append("\(duplicates.count) already in the library") }
            if !skipped.isEmpty { parts.append("\(skipped.count) unsupported file\(skipped.count == 1 ? "" : "s") left in the Inbox") }
            if !failed.isEmpty { parts.append("\(failed.count) failed") }
            return parts.isEmpty ? "The Inbox is empty." : parts.joined(separator: ", ") + "."
        }
    }

    public let library: URL
    public let inbox: URL
    /// Makes sure an iCloud item is downloaded before it is read (no-op for local folders).
    public var ensureDownloaded: @Sendable (URL) async throws -> Void

    public init(library: URL, inbox: URL, ensureDownloaded: @escaping @Sendable (URL) async throws -> Void = { try await ICloudFiles.ensureDownloaded($0) }) {
        self.library = library.standardizedFileURL
        self.inbox = inbox.standardizedFileURL
        self.ensureDownloaded = ensureDownloaded
    }

    // MARK: Folder mirroring

    /// Creates every library folder inside the Inbox. Returns how many were added.
    @discardableResult
    public func mirrorFolders() throws -> Int {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        var created = 0
        for relative in Self.folders(under: library) {
            let target = inbox.appending(path: relative)
            if !FileManager.default.fileExists(atPath: target.path) {
                try ICloudFiles.coordinatedCreateDirectory(target)
                created += 1
            }
        }
        return created
    }

    /// Mirrors a library folder rename/move — only if the Inbox copy holds no files, so nothing waiting
    /// for import is ever moved or lost.
    public func mirrorMove(from oldRelative: String, to newRelative: String) {
        let old = inbox.appending(path: oldRelative), new = inbox.appending(path: newRelative)
        guard Self.isEmptyTree(old), !FileManager.default.fileExists(atPath: new.path) else { return }
        try? FileManager.default.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ICloudFiles.coordinatedMove(old, to: new)
    }

    /// Mirrors a library folder deletion — only if the Inbox copy holds no files.
    public func mirrorDelete(_ relative: String) {
        let url = inbox.appending(path: relative)
        guard !relative.isEmpty, Self.isEmptyTree(url) else { return }
        try? ICloudFiles.coordinatedDelete(url)
    }

    // MARK: Import

    public func sync() async -> Report {
        var report = Report()
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        // Folders first (shallow before deep), so files always have somewhere to go.
        for relative in Self.folders(under: inbox) {
            let target = library.appending(path: relative)
            if !FileManager.default.fileExists(atPath: target.path) {
                do {
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    report.foldersCreated.append(relative)
                } catch {
                    report.failed[relative] = error.localizedDescription
                }
            }
        }

        for (relative, url) in Self.files(under: inbox) {
            // Background runs can be cut short; whatever was already moved stays moved.
            if Task.isCancelled { break }
            var name = url.lastPathComponent
            let folder = library.appending(path: (relative as NSString).deletingLastPathComponent)
            do {
                if !AudiobookFormat.canOpen(url) {
                    // Saved without an extension (e.g. "Book title " from a share sheet): recognise it by its contents.
                    guard url.pathExtension.isEmpty else {
                        report.skipped.append(relative)
                        continue
                    }
                    try await ensureDownloaded(url)
                    guard let ext = AudiobookFormat.sniffExtension(url) else {
                        report.skipped.append(relative)
                        continue
                    }
                    name = name.trimmingCharacters(in: .whitespaces) + "." + ext
                }
                try await ensureDownloaded(url)
                let existing = folder.appending(path: name)
                if FileManager.default.fileExists(atPath: existing.path),
                   (try? BookFingerprint.id(for: existing)) == (try? BookFingerprint.id(for: url)) {
                    try ICloudFiles.coordinatedDelete(url)
                    report.duplicates.append(relative)
                    continue
                }
                let destination = LibraryFiles.uniqueURL(for: name, in: folder)
                try ICloudFiles.coordinatedCopy(url, to: destination)
                try ICloudFiles.coordinatedDelete(url)
                report.imported.append(String(destination.path.dropFirst(library.path.count + 1)))
            } catch {
                report.failed[relative] = error.localizedDescription
            }
        }

        _ = try? mirrorFolders()
        return report
    }

    // MARK: Tree walking

    /// Relative paths of all folders, parents before children.
    public static func folders(under root: URL) -> [String] {
        walk(root).filter(\.isDirectory).map(\.relative).sorted { $0.split(separator: "/").count < $1.split(separator: "/").count }
    }

    /// Files (including not-yet-downloaded iCloud placeholders, reported under their real name).
    public static func files(under root: URL) -> [(relative: String, url: URL)] {
        walk(root).filter { !$0.isDirectory }.map { ($0.relative, $0.url) }
    }

    private static func walk(_ root: URL) -> [(relative: String, url: URL, isDirectory: Bool)] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsPackageDescendants]) else { return [] }
        var items: [(String, URL, Bool)] = []
        for case let url as URL in enumerator {
            var name = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            var itemURL = url
            if name.hasPrefix(".") {
                // Older iCloud placeholders: ".Book.m4b.icloud" stands for "Book.m4b".
                guard !isDirectory, name.hasSuffix(".icloud") else {
                    if isDirectory { enumerator.skipDescendants() }
                    continue
                }
                name = String(name.dropFirst().dropLast(".icloud".count))
                itemURL = url.deletingLastPathComponent().appending(path: name)
            }
            // Resolve via the parent, which exists even when the item is an iCloud placeholder.
            let parent = itemURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
            let full = parent + "/" + name
            guard full.hasPrefix(base + "/") else { continue }
            items.append((String(full.dropFirst(base.count + 1)), itemURL, isDirectory))
        }
        return items
    }

    /// True if any supported book is waiting in the Inbox.
    public static func hasBooks(in inbox: URL) -> Bool {
        files(under: inbox).contains { AudiobookFormat.canOpen($0.url) }
    }

    static func isEmptyTree(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        return files(under: url).isEmpty
    }
}
