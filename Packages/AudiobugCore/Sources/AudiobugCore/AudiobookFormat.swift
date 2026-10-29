import Foundation

/// Which files count as audiobooks. "Apple audiobooks" are M4B files (MP4 audio with chapter atoms); plain
/// M4A/MP3/AAC and the lossless formats play too. DRM-protected books from the Apple Books store cannot be
/// played by third-party apps, so they are not supported.
public enum AudiobookFormat {
    public static let extensions: Set<String> = ["m4b", "m4a", "mp3", "aac", "mp4", "wav", "aiff", "aif", "caf", "flac"]

    public static func canOpen(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// Recognises a file saved without an extension (e.g. from a share sheet) by its first bytes.
    public static func sniffExtension(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 12 else { return nil }
        let bytes = [UInt8](data)
        func ascii(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        if ascii(4..<8) == "ftyp" {
            let brand = ascii(8..<12)
            return brand.hasPrefix("M4B") ? "m4b" : "m4a"
        }
        if ascii(0..<3) == "ID3" { return "mp3" }
        if bytes[0] == 0xFF, [0xFB, 0xF3, 0xF2, 0xFA].contains(bytes[1]) { return "mp3" }
        if ascii(0..<4) == "RIFF", ascii(8..<12) == "WAVE" { return "wav" }
        if ascii(0..<4) == "FORM", ["AIFF", "AIFC"].contains(ascii(8..<12)) { return "aiff" }
        if ascii(0..<4) == "fLaC" { return "flac" }
        if ascii(0..<4) == "caff" { return "caf" }
        return nil
    }
}
