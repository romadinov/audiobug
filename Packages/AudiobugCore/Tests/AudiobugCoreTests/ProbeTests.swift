import AVFoundation
import Foundation
import Testing
@testable import AudiobugCore

/// AUDIOBOOK_PROBE=/path/to/book.m4b swift test --filter probeRealBook
@Suite struct ProbeTests {
    @Test func probeRealBook() async throws {
        guard let path = ProcessInfo.processInfo.environment["AUDIOBOOK_PROBE"] else { return }
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let locales = try await asset.load(.availableChapterLocales)
        print("availableChapterLocales=\(locales.map(\.identifier))")
        let tracks = try await asset.load(.tracks)
        for t in tracks { print("track \(t.trackID) \(t.mediaType.rawValue) lang=\(t.languageCode ?? "-")") }
        let g1 = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
        print("bestMatching(preferred)=\(g1.count)")
        let g2 = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: ["und", "en"])
        print("bestMatching(und,en)=\(g2.count)")
        for locale in locales {
            let g = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyArtwork])
            print("withTitleLocale(\(locale.identifier))=\(g.count)")
        }
        let meta = try await AudiobookInspector.load(url)
        print("title=\(meta.title ?? "-") author=\(meta.author ?? "-") duration=\(meta.duration) artwork=\(meta.artwork?.count ?? 0) bytes")
        for c in meta.chapters { print("  \(c.id): \(c.title) \(c.start)–\(c.end)") }
        #expect(meta.duration > 0)
    }
}
