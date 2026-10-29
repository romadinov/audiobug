import AudiobugCore
import Foundation

/// Appends diagnostics lines to iCloud Drive › Audiobug › Diagnostics › log.txt (local Documents without iCloud).
final class DiagFile: @unchecked Sendable {
    static let shared = DiagFile()
    private let queue = DispatchQueue(label: "com.romadinov.audiobug.diag")
    private var url: URL?

    func install() {
        Diag.sink = { [weak self] line in self?.append(line) }
    }

    func append(_ line: String) {
        queue.async {
            guard let url = self.resolve() else { return }
            let data = Data((line + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    private func resolve() -> URL? {
        if let url { return url }
        let documents = ICloudFiles.documentsDirectory(containerIdentifier: InboxLocation.containerIdentifier) ?? LibraryPaths.documents
        let folder = documents.appending(path: "Diagnostics")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: "log.txt")
        return url
    }
}
