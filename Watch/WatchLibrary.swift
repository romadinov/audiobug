import AudiobugCore
import Foundation
import Observation

/// The books on the Watch (Documents/Books), sent over from the iPhone.
@MainActor @Observable
final class WatchLibrary {
    private(set) var books: [Audiobook] = []
    var selected: Audiobook?

    init() { reload() }

    func reload() {
        books = LibraryScanner.scan(root: LibraryPaths.books)
    }

    func delete(_ book: Audiobook) {
        try? FileManager.default.removeItem(at: book.url)
        Positions.shared.remove(book.id)
        CoverStore.shared.forget(book.id)
        if selected?.id == book.id { selected = nil }
        reload()
    }

    var totalBytes: Int64 { books.reduce(0) { $0 + $1.fileSize } }

    var freeBytes: Int64 {
        (try? LibraryPaths.documents.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity).map(Int64.init) ?? 0
    }
}
