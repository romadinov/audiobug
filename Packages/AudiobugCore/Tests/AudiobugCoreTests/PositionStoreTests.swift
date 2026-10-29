import Foundation
import Testing
@testable import AudiobugCore

@Suite struct PositionStoreTests {
    let file = FileManager.default.temporaryDirectory.appending(path: "positions-\(UUID().uuidString)/positions.json")

    @Test func savesAndReloads() throws {
        let store = PositionStore(file: file)
        store.save(PlaybackPosition(bookID: "a", time: 120, duration: 3600, rate: 1.5, device: "iPhone"))
        let reloaded = PositionStore(file: file)
        let p = try #require(reloaded.position(for: "a"))
        #expect(p.time == 120 && p.rate == 1.5 && p.fraction == 120 / 3600)
    }

    @Test func mergeKeepsTheNewest() {
        let store = PositionStore(file: file)
        let now = Date()
        store.save(PlaybackPosition(bookID: "a", time: 100, updatedAt: now, device: "iPhone"))
        #expect(!store.merge(PlaybackPosition(bookID: "a", time: 50, updatedAt: now.addingTimeInterval(-10), device: "Watch")))
        #expect(store.merge(PlaybackPosition(bookID: "a", time: 200, updatedAt: now.addingTimeInterval(10), device: "Watch")))
        #expect(store.position(for: "a")?.time == 200)
    }

    @Test func dictionaryRoundTrip() throws {
        let p = PlaybackPosition(bookID: "b", time: 42, duration: 100, rate: 2, finished: true, device: "Watch")
        let back = try #require(PlaybackPosition(dictionary: p.dictionary))
        #expect(back.bookID == "b" && back.time == 42 && back.rate == 2 && back.finished && back.duration == 100)
        #expect(abs(back.updatedAt.timeIntervalSince(p.updatedAt)) < 0.001)
    }

    @Test func uniqueNames() throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: "Book.m4b"))
        #expect(LibraryFiles.uniqueURL(for: "Book.m4b", in: dir).lastPathComponent == "Book 2.m4b")
        #expect(LibraryFiles.uniqueURL(for: "Other.m4b", in: dir).lastPathComponent == "Other.m4b")
    }

    @Test func fingerprintIsStableAndSizeSensitive() throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appending(path: "a.m4b"), b = dir.appending(path: "b.m4b"), c = dir.appending(path: "c.m4b")
        try Data(repeating: 7, count: 1_000_000).write(to: a)
        try Data(repeating: 7, count: 1_000_000).write(to: b)
        try Data(repeating: 7, count: 1_000_001).write(to: c)
        #expect(try BookFingerprint.id(for: a) == BookFingerprint.id(for: b))
        #expect(try BookFingerprint.id(for: a) != BookFingerprint.id(for: c))
    }
}
