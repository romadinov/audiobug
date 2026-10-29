import AVFoundation
import Foundation

public struct Chapter: Identifiable, Sendable, Equatable {
    public var id: Int
    public var title: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(id: Int, title: String, start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
    public func contains(_ time: TimeInterval) -> Bool { time >= start && time < end }
}

public struct AudiobookMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var duration: TimeInterval
    public var chapters: [Chapter]
    public var artwork: Data?

    public init(title: String? = nil, author: String? = nil, duration: TimeInterval, chapters: [Chapter] = [], artwork: Data? = nil) {
        self.title = title
        self.author = author
        self.duration = duration
        self.chapters = chapters
        self.artwork = artwork
    }

    public func chapter(at time: TimeInterval) -> Chapter? {
        chapters.last { $0.start <= time } ?? chapters.first
    }
}

/// Reads title, author, cover and the chapter list from an audio file (M4B chapter atoms, MP3 ID3 chapters).
public enum AudiobookInspector {
    public static func load(_ url: URL) async throws -> AudiobookMetadata {
        let asset = AVURLAsset(url: url)
        let (duration, common) = try await asset.load(.duration, .commonMetadata)
        var meta = AudiobookMetadata(duration: duration.seconds.isFinite ? duration.seconds : 0)
        for item in common {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle: meta.title = try? await item.load(.stringValue)
            case .commonKeyArtist, .commonKeyAuthor:
                if meta.author == nil { meta.author = try? await item.load(.stringValue) }
            case .commonKeyArtwork: meta.artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        // Chapter tracks written by ffmpeg are tagged "und", which the preferred-language lookup ignores,
        // so pick the best available chapter locale explicitly.
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        let locale = locales.first { l in preferred.contains(l.language.languageCode?.identifier ?? "") } ?? locales.first
        let groups: [AVTimedMetadataGroup]
        if let locale {
            groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyArtwork])
        } else {
            groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages + ["und"])
        }
        var chapters: [Chapter] = []
        for (index, group) in groups.enumerated() {
            let range = group.timeRange
            let start = range.start.seconds
            let end = range.duration.seconds.isFinite ? start + range.duration.seconds : meta.duration
            var title = "Chapter \(index + 1)"
            if let item = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
               let text = try? await item.load(.stringValue), !text.isEmpty {
                title = text
            }
            chapters.append(Chapter(id: index, title: title, start: start, end: end))
        }
        meta.chapters = chapters
        return meta
    }
}
