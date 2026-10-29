import AudiobugCore
import Foundation

/// What the iPhone and the Watch say to each other over WatchConnectivity.
enum SyncMessages {
    /// User info / message: a listening position changed.
    static func position(_ p: PlaybackPosition) -> [String: Any] {
        ["type": "position", "position": p.dictionary]
    }

    /// User info: the iPhone asks the Watch to delete a book.
    static func remove(bookID: String) -> [String: Any] {
        ["type": "remove", "id": bookID]
    }

    /// User info: the iPhone asks the Watch which books it has (the Watch answers with its application context).
    static let askBooks: [String: Any] = ["type": "askBooks"]

    /// File transfer metadata: the book's identity and where the listener is.
    static func fileMetadata(book: Audiobook, position: PlaybackPosition?) -> [String: Any] {
        var m: [String: Any] = ["id": book.id, "name": book.url.lastPathComponent, "title": book.title, "relative": book.relativePath]
        if let position { m["position"] = position.dictionary }
        return m
    }

    /// File transfer metadata: a cover picture (JPEG) for a book the Watch holds or is receiving.
    static func coverMetadata(bookID: String) -> [String: Any] {
        ["type": "cover", "id": bookID]
    }

    static func isCover(_ metadata: [String: Any]?) -> Bool { (metadata?["type"] as? String) == "cover" }

    /// User info from the Watch: an improvement note written there (the iPhone files it in iCloud Drive).
    static func note(_ text: String, where context: String, file: String?, device: String) -> [String: Any] {
        var m: [String: Any] = ["type": "note", "text": text, "where": context, "device": device, "date": Date().timeIntervalSince1970]
        if let file { m["file"] = file }
        return m
    }

    /// Application context from the Watch: the books it holds, id → title.
    static func booksContext(_ books: [Audiobook]) -> [String: Any] {
        ["books": Dictionary(books.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }), "at": Date().timeIntervalSince1970]
    }

    // MARK: Wi-Fi pull (test path): the iPhone serves the file over HTTP, the Watch downloads it with URLSession.

    /// Message to the Watch: fetch this book from one of `urls` (the iPhone's Wi-Fi addresses, in order of preference).
    static func wifiOffer(book: Audiobook, position: PlaybackPosition?, urls: [String]) -> [String: Any] {
        var m = fileMetadata(book: book, position: position)
        m["type"] = "wifiOffer"
        m["urls"] = urls
        m["size"] = book.fileSize
        return m
    }

    /// Message from the Watch while downloading.
    static func wifiProgress(bookID: String, fraction: Double, bytesPerSecond: Double) -> [String: Any] {
        ["type": "wifiProgress", "id": bookID, "fraction": fraction, "rate": bytesPerSecond]
    }

    /// Message from the Watch when the download ended (`error` nil on success).
    static func wifiDone(bookID: String, title: String, error: String?, seconds: TimeInterval, bytes: Int64) -> [String: Any] {
        var m: [String: Any] = ["type": "wifiDone", "id": bookID, "title": title, "seconds": seconds, "bytes": bytes]
        if let error { m["error"] = error }
        return m
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }
}
