import AudiobugCore
import Foundation
import Observation
import UIKit
import os

private let log = Logger(subsystem: "com.romadinov.audiobug", category: "Covers")

/// Cover pictures for the library: the art embedded in the book (or a picture beside it), or one you chose
/// yourself. Thumbnails are cached in Application Support/Audiobug/Covers/<book id>.jpg; a `.none` marker
/// remembers books that have no art, so they aren't inspected again.
@MainActor @Observable
final class CoverStore {
    static let shared = CoverStore()

    #if os(watchOS)
    nonisolated static let maxPixels = 400
    #else
    nonisolated static let maxPixels = 1000
    #endif

    nonisolated static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appending(path: "Audiobug/Covers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static func file(for id: String) -> URL { directory.appending(path: id + ".jpg") }
    private nonisolated static func marker(for id: String) -> URL { directory.appending(path: id + ".none") }

    /// Decoded covers, by book id; filled by `load`.
    private(set) var images: [String: UIImage] = [:]
    /// Books whose cover you chose yourself (kept when the book's own art would otherwise be used).
    private(set) var customIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "customCovers") ?? [])
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var missing: Set<String> = []

    func image(for id: String) -> UIImage? { images[id] }
    func isCustom(_ id: String) -> Bool { customIDs.contains(id) }
    /// The cached JPEG, if the cover has been found (to send to the Watch).
    func fileIfPresent(for id: String) -> URL? {
        let url = Self.file(for: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Finds the cover for a book: the cache, a picture beside the file, or the file's own art. Call from `.task`.
    func load(_ book: Audiobook) async {
        let id = book.id
        guard images[id] == nil, !missing.contains(id), !loading.contains(id) else { return }
        loading.insert(id)
        defer { loading.remove(id) }
        let url = book.url
        let data = await Task.detached(priority: .utility) { () -> Data? in
            let file = Self.file(for: id)
            if let data = try? Data(contentsOf: file) { return data }
            if FileManager.default.fileExists(atPath: Self.marker(for: id).path) { return nil }
            var raw: Data?
            if let sidecar = CoverArt.sidecar(for: url) { raw = try? Data(contentsOf: sidecar) }
            if raw == nil { raw = await CoverArt.embedded(in: url) }
            guard let raw, let thumb = CoverArt.thumbnail(raw, maxPixels: Self.maxPixels) else {
                try? Data().write(to: Self.marker(for: id))
                return nil
            }
            try? thumb.write(to: file, options: .atomic)
            return thumb
        }.value
        guard loading.contains(id) else { return }   // replaced or forgotten meanwhile
        if let data, let image = UIImage(data: data) {
            images[id] = image
        } else {
            missing.insert(id)
        }
    }

    /// Art the player found while opening the book: cache it if the library hasn't looked yet.
    func offer(_ artwork: Data?, for id: String) {
        guard let artwork, images[id] == nil, fileIfPresent(for: id) == nil else { return }
        Task.detached(priority: .utility) {
            guard let thumb = CoverArt.thumbnail(artwork, maxPixels: Self.maxPixels) else { return }
            try? thumb.write(to: Self.file(for: id), options: .atomic)
            await MainActor.run { CoverStore.shared.replace(id, with: thumb) }
        }
    }

    /// Uses a picture of your own for a book. Returns false when the data isn't an image.
    @discardableResult
    func setCustom(_ data: Data, for id: String) -> Bool {
        guard let thumb = CoverArt.thumbnail(data, maxPixels: Self.maxPixels) else { return false }
        try? thumb.write(to: Self.file(for: id), options: .atomic)
        customIDs.insert(id)
        UserDefaults.standard.set(Array(customIDs), forKey: "customCovers")
        replace(id, with: thumb)
        log.info("Custom cover set for \(id, privacy: .public)")
        return true
    }

    /// Drops a custom cover and goes back to the book's own art.
    func removeCustom(_ book: Audiobook) async {
        customIDs.remove(book.id)
        UserDefaults.standard.set(Array(customIDs), forKey: "customCovers")
        forget(book.id)
        await load(book)
    }

    /// A cover sent over from the other device (already a thumbnail, re-sized for this screen).
    func store(received data: Data, for id: String) {
        guard let thumb = CoverArt.thumbnail(data, maxPixels: Self.maxPixels) else { return }
        try? thumb.write(to: Self.file(for: id), options: .atomic)
        replace(id, with: thumb)
    }

    /// Forgets everything cached for a book (the book was deleted, or its cover should be found again).
    func forget(_ id: String) {
        try? FileManager.default.removeItem(at: Self.file(for: id))
        try? FileManager.default.removeItem(at: Self.marker(for: id))
        images[id] = nil
        missing.remove(id)
        loading.remove(id)
    }

    private func replace(_ id: String, with data: Data) {
        try? FileManager.default.removeItem(at: Self.marker(for: id))
        missing.remove(id)
        loading.remove(id)
        if let image = UIImage(data: data) { images[id] = image }
    }
}
