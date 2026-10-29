import AudiobugCore
import Foundation
import MetricKit
import SwiftUI
import UIKit
import os

private let log = Logger(subsystem: "com.romadinov.audiobug", category: "Feedback")

/// The shared agent feedback loop (~/Dev/agent-feedback): the app writes improvement notes and crash reports
/// into iCloud Drive › Audiobug; a Mac-side router tells the session that owns the app. Audiobug's notes are
/// mostly narration corrections (a word stressed or read wrong at a place in a book), so the registry routes
/// them to ebooker, the tool that made the book. The app is the only writer of these files.
enum Feedback {
    /// Documents/ in the iCloud container, or the local Documents folder without iCloud Drive. Blocks; call off the main thread.
    static func documents() -> URL {
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["AUDIOBUG_FEEDBACK_DIR"] { return URL(fileURLWithPath: dir) }
        #endif
        return ICloudFiles.documentsDirectory(containerIdentifier: InboxLocation.containerIdentifier) ?? LibraryPaths.documents
    }

    static var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") build \(info?["CFBundleVersion"] as? String ?? "?")"
    }

    static var device: String { "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)" }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f.string(from: date)
    }
}

/// "Improvement notes.md" (TaskPaper), append-only: one item per note with where it was written (book, chapter,
/// time), the file, the build, the device and an optional screenshot in "Improvement notes/".
enum ImprovementNotes {
    static func add(_ text: String, where context: String, file: String? = nil, device: String = Feedback.device,
                    screenshot: Data? = nil, date: Date = Date()) throws {
        let docs = Feedback.documents()
        let notes = docs.appending(path: "Improvement notes.md")
        var tags: [(String, String)] = [("date", date.formatted(.iso8601.year().month().day())), ("where", context)]
        if let file { tags.append(("file", file)) }
        tags += [("build", Feedback.build), ("device", device)]
        if let screenshot {
            let folder = docs.appending(path: "Improvement notes")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let name = "Screenshot \(Feedback.stamp(date)).png"
            try screenshot.write(to: folder.appending(path: name))
            tags.append(("screenshot", "Improvement notes/\(name)"))
        }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
        var entry = "\t- " + oneLine(lines.first ?? "") + " " + tags.map { "@\($0.0)(\(tagValue($0.1)))" }.joined(separator: " ")
        let rest = lines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !rest.isEmpty { entry += "\n" + rest.map { "\t\t" + $0 }.joined(separator: "\n") }

        // Another device may have appended meanwhile: start from the latest copy, never a stale local one.
        waitUntilCurrent(notes)
        var inner: Error?
        var coordination: NSError?
        NSFileCoordinator().coordinate(writingItemAt: notes, options: .forMerging, error: &coordination) { url in
            do {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                if content.isEmpty { content = "Improvement notes:\n" }
                if !content.hasSuffix("\n") { content += "\n" }
                content += entry + "\n"
                try Data(content.utf8).write(to: url, options: .atomic)
            } catch { inner = error }
        }
        if let error = coordination ?? inner { throw error }
        log.info("Improvement note saved: \(oneLine(lines.first ?? ""), privacy: .public)")
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func tagValue(_ s: String) -> String {
        oneLine(s).replacingOccurrences(of: "(", with: "[").replacingOccurrences(of: ")", with: "]")
    }

    static func waitUntilCurrent(_ url: URL, timeout: TimeInterval = 8) {
        guard (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var copy = url
            copy.removeAllCachedResourceValues()
            if (try? copy.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus == .current { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}

/// Crash, hang and resource reports from MetricKit, saved to "Crash reports/" one file per report. MetricKit
/// delivers a report on the launch after the problem; nothing is sent anywhere else.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()
    private var device = "iPhone"

    /// Call at launch, on the main thread.
    @MainActor func start() {
        device = UIDevice.current.model
        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { save(past) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let device = device
        Task.detached(priority: .utility) {
            let folder = Feedback.documents().appending(path: "Crash reports")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            for payload in payloads {
                let crashes = payload.crashDiagnostics?.count ?? 0
                let hangs = payload.hangDiagnostics?.count ?? 0
                let other = (payload.cpuExceptionDiagnostics?.count ?? 0) + (payload.diskWriteExceptionDiagnostics?.count ?? 0)
                guard crashes + hangs + other > 0 else { continue }
                let kind = crashes > 0 ? "Crash" : (hangs > 0 ? "Hang" : "Resource")
                let name = "\(kind) \(Feedback.stamp(payload.timeStampEnd)) \(device) build \(build).json".replacingOccurrences(of: "/", with: "-")
                let url = folder.appending(path: name)
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
                    try? payload.jsonRepresentation().write(to: target, options: .atomic)
                }
                log.info("Saved diagnostic report \(name, privacy: .public)")
            }
        }
    }
}

/// A note in progress: where it was written, the book file, and a screenshot taken before the form covers the screen.
struct ImprovementNoteRequest: Identifiable {
    let id = UUID()
    let context: String
    let file: String?
    let screenshot: UIImage?

    /// Waits for the menu that triggered this to close, then captures the screen.
    @MainActor static func capture(context: String, file: String?) async -> ImprovementNoteRequest {
        try? await Task.sleep(for: .milliseconds(400))
        return ImprovementNoteRequest(context: context, file: file, screenshot: captureWindow())
    }

    @MainActor private static func captureWindow() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

/// The note form: text, where it was written, and the screenshot (on by default).
struct ImprovementNoteView: View {
    let request: ImprovementNoteRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var attach = true
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What's wrong, or what could be better? A word read or stressed wrong, a bug, a wish…", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                        .accessibilityIdentifier("note.text")
                } footer: {
                    Text("Noted at: \(request.context)" + (request.file.map { "\nFile: \($0)" } ?? ""))
                }
                if let shot = request.screenshot {
                    Section {
                        Toggle("Attach screenshot", isOn: $attach)
                        if attach {
                            Image(uiImage: shot).resizable().scaledToFit().frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Suggest an Improvement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let note = text, context = request.context, file = request.file
        let png = attach ? request.screenshot?.pngData() : nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try ImprovementNotes.add(note, where: context, file: file, screenshot: png)
            }.value
            dismiss()
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
