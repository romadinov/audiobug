import AudiobugCore
import Foundation

/// A book file in this device's library (Documents/Books, possibly in a folder).
struct Audiobook: Identifiable, Hashable, Sendable {
    let url: URL
    /// Content fingerprint: the same on every device, whatever the file is called.
    let id: String
    /// Path relative to the library root, e.g. "Fiction/Emma.m4b".
    let relativePath: String
    let fileSize: Int64

    var title: String { url.deletingPathExtension().lastPathComponent }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
}

enum LibraryPaths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// Documents/Books: visible in the Files app on the iPhone; the Watch keeps its own copy.
    static let books: URL = {
        let dir = documents.appending(path: "Books")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.standardizedFileURL
    }()

    static let positions: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "Audiobug/positions.json")
    }()
}

enum Positions {
    static let shared = PositionStore(file: LibraryPaths.positions)
}

enum DeviceName {
    #if os(watchOS)
    static let current = "Apple Watch"
    #else
    static let current = "iPhone"
    #endif
}

/// Lists the books under a root, computing (and caching) their fingerprints.
enum LibraryScanner {
    static func scan(root: URL = LibraryPaths.books) -> [Audiobook] {
        var books: [Audiobook] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let base = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true,
                  AudiobookFormat.canOpen(url) else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count + 1))
            let size = Int64(values.fileSize ?? 0)
            let modified = values.contentModificationDate ?? .distantPast
            guard let id = BookIDCache.id(for: url, relative: relative, size: size, modified: modified) else { continue }
            books.append(Audiobook(url: url, id: id, relativePath: relative, fileSize: size))
        }
        return books.sorted {
            if $0.folder != $1.folder { return $0.folder.localizedStandardCompare($1.folder) == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
}

/// Fingerprints are remembered per (path, size, modification date), so a rescan doesn't reread every book.
enum BookIDCache {
    private static let key = "bookIDs"

    static func id(for url: URL, relative: String, size: Int64, modified: Date) -> String? {
        let cacheKey = "\(relative)|\(size)|\(Int(modified.timeIntervalSince1970))"
        var cache = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let id = cache[cacheKey] { return id }
        guard let id = try? BookFingerprint.id(for: url) else { return nil }
        if cache.count > 500 { cache = [:] }
        cache[cacheKey] = id
        UserDefaults.standard.set(cache, forKey: key)
        return id
    }
}
