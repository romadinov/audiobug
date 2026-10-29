import Foundation
import Testing
@testable import AudiobugCore

@Suite struct InboxSyncTests {
    let library: URL
    let inbox: URL
    let sync: InboxSync

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "inbox-\(UUID().uuidString)")
        library = root.appending(path: "Books")
        inbox = root.appending(path: "Inbox")
        try FileManager.default.createDirectory(at: library.appending(path: "Fiction/Classics"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library.appending(path: "History"), withIntermediateDirectories: true)
        sync = InboxSync(library: library, inbox: inbox, ensureDownloaded: { _ in })
    }

    private func write(_ bytes: [UInt8], _ path: String, in root: URL) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        try write(Array(text.utf8), path, in: root)
    }

    private func exists(_ path: String, in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    /// The first bytes of an M4B: a size, "ftyp", brand "M4B ".
    static let m4bHeader: [UInt8] = [0, 0, 0, 0x20] + Array("ftypM4B ".utf8) + [0, 0, 0, 0] + Array("M4B isom".utf8)

    @Test func mirrorsAllLibraryFolders() throws {
        #expect(try sync.mirrorFolders() == 3)
        #expect(exists("Fiction/Classics", in: inbox) && exists("History", in: inbox))
        #expect(try sync.mirrorFolders() == 0)    // idempotent
    }

    @Test func recognisesBooksSavedWithoutAnExtension() async throws {
        try write(Self.m4bHeader, "Fiction/Old Man's War ", in: inbox)   // a share sheet dropped ".m4b"
        try write("just some notes", "Fiction/README", in: inbox)
        let report = await sync.sync()
        #expect(report.imported == ["Fiction/Old Man's War.m4b"])
        #expect(report.skipped == ["Fiction/README"])
        #expect(exists("Fiction/Old Man's War.m4b", in: library))
        #expect(!exists("Fiction/Old Man's War ", in: inbox) && exists("Fiction/README", in: inbox))
    }

    @Test func importsIntoMatchingFoldersAndEmptiesInbox() async throws {
        try sync.mirrorFolders()
        try write("m4b-1", "Fiction/Classics/Emma.m4b", in: inbox)
        try write("mp3-1", "History/Rome/Caesar.mp3", in: inbox)            // folder made in the Inbox
        try write("m4a", "Root book.m4a", in: inbox)
        try write("notes", "History/readme.txt", in: inbox)                 // not a book
        try write("dup", "History/Same.m4b", in: library)
        try write("dup", "History/Same.m4b", in: inbox)                     // identical copy already imported
        try write("other", "History/Clash.m4b", in: library)
        try write("new", "History/Clash.m4b", in: inbox)                    // same name, different book

        let report = await sync.sync()

        #expect(Set(report.imported) == ["Fiction/Classics/Emma.m4b", "History/Rome/Caesar.mp3",
                                         "Root book.m4a", "History/Clash 2.m4b"])
        #expect(report.foldersCreated == ["History/Rome"])
        #expect(report.duplicates == ["History/Same.m4b"])
        #expect(report.skipped == ["History/readme.txt"])
        #expect(report.failed.isEmpty)
        #expect(try String(contentsOf: library.appending(path: "History/Rome/Caesar.mp3"), encoding: .utf8) == "mp3-1")
        // Books are gone from the Inbox; folders (incl. the new one) and the unsupported file remain.
        #expect(InboxSync.files(under: inbox).map(\.relative) == ["History/readme.txt"])
        #expect(exists("History/Rome", in: inbox) && exists("Fiction/Classics", in: inbox))
        #expect(report.summary == "4 books imported, 1 new folder, 1 already in the library, 1 unsupported file left in the Inbox.")
    }

    @Test func folderRenameAndDeleteMirrorOnlyWhenEmpty() throws {
        try sync.mirrorFolders()
        sync.mirrorMove(from: "History", to: "Past")
        #expect(!exists("History", in: inbox) && exists("Past", in: inbox))

        try write("waiting", "Fiction/Classics/Pending.m4b", in: inbox)
        sync.mirrorDelete("Fiction")                                        // holds a pending book → kept
        #expect(exists("Fiction/Classics/Pending.m4b", in: inbox))
        sync.mirrorDelete("Past")
        #expect(!exists("Past", in: inbox))
    }

    @Test func sniffsFormats() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "sniff-\(UUID().uuidString)")
        try write(Self.m4bHeader, "a", in: dir)
        try write(Array("ID3\u{03}\0\0\0\0\0\u{10}xxxxxxxx".utf8), "b", in: dir)
        try write(Array("RIFF\0\0\0\0WAVEfmt ".utf8), "c", in: dir)
        try write("plain text that is long enough", "d", in: dir)
        #expect(AudiobookFormat.sniffExtension(dir.appending(path: "a")) == "m4b")
        #expect(AudiobookFormat.sniffExtension(dir.appending(path: "b")) == "mp3")
        #expect(AudiobookFormat.sniffExtension(dir.appending(path: "c")) == "wav")
        #expect(AudiobookFormat.sniffExtension(dir.appending(path: "d")) == nil)
    }
}
