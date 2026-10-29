import AudiobugCore
import Foundation
import Observation
import os

private let log = Logger(subsystem: "com.romadinov.audiobug", category: "Library")

/// Books live in Documents/Books, organised in folders (also visible in the Files app).
@MainActor @Observable
final class LibraryStore {
    private(set) var books: [Audiobook] = []
    /// Folder name → books, in display order ("" is the root).
    var sections: [(folder: String, books: [Audiobook])] {
        var order: [String] = []
        var grouped: [String: [Audiobook]] = [:]
        for book in books {
            if grouped[book.folder] == nil { order.append(book.folder) }
            grouped[book.folder, default: []].append(book)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
    /// The book to show in the player (set by tapping a book or opening a file).
    var selected: Audiobook? {
        didSet { log.info("selected → \(self.selected?.title ?? "nil", privacy: .public)") }
    }
    var importError: String?

    // MARK: iCloud Inbox

    /// iCloud Drive › Audiobug › Inbox (or On My iPhone › Audiobug › Inbox without iCloud).
    private(set) var inbox: InboxSync?
    private(set) var inboxLocation = ""
    private(set) var isSyncingInbox = false
    private var inboxIsCloud = false
    /// Books imported automatically (watcher or background), shown as a banner in the library.
    var autoImported: [String] = []
    @ObservationIgnored private lazy var watcher = InboxWatcher { [weak self] in
        Task { await self?.autoImport() }
    }

    var root: URL { LibraryPaths.books }

    init() {
        reload()
        Task { await resolveInbox() }
    }

    func reload() {
        books = LibraryScanner.scan(root: root)
        log.info("reload: \(self.books.count) books")
    }

    func open(_ book: Audiobook) {
        selected = book
    }

    private func resolveInbox() async {
        let root = root
        let (url, isCloud) = await Task.detached(priority: .utility) { InboxLocation.resolve() }.value
        let sync = InboxSync(library: root, inbox: url)
        inbox = sync
        inboxIsCloud = isCloud
        inboxLocation = isCloud ? "iCloud Drive › Audiobug › Inbox" : "On My iPhone › Audiobug › Inbox"
        await Task.detached(priority: .utility) { _ = try? sync.mirrorFolders() }.value
        startWatchingInbox()
    }

    /// Foreground: watch the Inbox and import new books as they arrive.
    func startWatchingInbox() {
        let background = InboxBackgroundImport.takeBackgroundImports()
        if !background.isEmpty {
            autoImported += background
            reload()
        }
        guard let inbox else { return }
        watcher.start(inbox: inbox.inbox, isCloud: inboxIsCloud)
        Task { await autoImport() }   // anything that arrived while we were away
    }

    func stopWatchingInbox() {
        watcher.stop()
    }

    private func autoImport() async {
        guard let inbox, InboxSync.hasBooks(in: inbox.inbox) else { return }
        if let report = await syncInbox(), !report.imported.isEmpty {
            autoImported += report.imported
        }
    }

    /// Imports everything waiting in the Inbox into the matching library folders and empties the Inbox.
    func syncInbox() async -> InboxSync.Report? {
        if inbox == nil { await resolveInbox() }
        guard let inbox, !isSyncingInbox else { return nil }
        isSyncingInbox = true
        defer { isSyncingInbox = false }
        let report = await Task.detached(priority: .userInitiated) { await inbox.sync() }.value
        reload()
        return report
    }

    // MARK: Files

    /// Copies files picked in the Files app (or handed over by another app) into the library.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [Audiobook] {
        var imported: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard AudiobookFormat.canOpen(url) else {
                importError = "\(url.lastPathComponent) isn't an audiobook file."
                continue
            }
            do {
                let destination = LibraryFiles.uniqueURL(for: url.lastPathComponent, in: root)
                try ICloudFiles.coordinatedCopy(url, to: destination)
                // "Open with…" from another app lands a copy in Documents/Inbox; don't keep a duplicate.
                if url.deletingLastPathComponent().lastPathComponent == "Inbox",
                   url.path.hasPrefix(LibraryPaths.documents.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                imported.append(destination)
            } catch {
                importError = error.localizedDescription
                log.error("Import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        reload()
        let ids = Set(imported.map(\.standardizedFileURL))
        return books.filter { ids.contains($0.url.standardizedFileURL) }
    }

    func delete(_ book: Audiobook) {
        try? FileManager.default.removeItem(at: book.url)
        Positions.shared.remove(book.id)
        CoverStore.shared.forget(book.id)
        if selected?.id == book.id { selected = nil }
        reload()
    }
}
