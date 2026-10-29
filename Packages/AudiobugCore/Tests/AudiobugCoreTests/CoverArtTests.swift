import Foundation
import Testing
@testable import AudiobugCore

@Suite struct CoverArtTests {
    /// A sample book with embedded art, when the ebooker test output is around.
    private var sample: URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Dev/ebooker/out/_tests/omw_ch1.m4b")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @Test func embeddedArtIsExtractedAndThumbnailed() async throws {
        guard let sample else { return }
        let data = try #require(await CoverArt.embedded(in: sample))
        let original = try #require(CoverArt.pixelSize(of: data))
        #expect(original.width > 0 && original.height > 0)
        let thumb = try #require(CoverArt.thumbnail(data, maxPixels: 120))
        let size = try #require(CoverArt.pixelSize(of: thumb))
        #expect(max(size.width, size.height) == 120)
        #expect(abs(size.width / size.height - original.width / original.height) < 0.05)
    }

    @Test func sidecarBesideTheBookIsFound() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "covers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = dir.appending(path: "Emma.m4b")
        try Data().write(to: book)
        #expect(CoverArt.sidecar(for: book) == nil)
        try Data([0xFF]).write(to: dir.appending(path: "Emma.png"))
        #expect(CoverArt.sidecar(for: book)?.lastPathComponent == "Emma.png")
    }

    @Test func garbageIsNotAnImage() {
        #expect(CoverArt.thumbnail(Data("not an image".utf8), maxPixels: 100) == nil)
    }
}
