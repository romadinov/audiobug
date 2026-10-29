import SwiftUI
import WatchKit

/// "Suggest an Improvement" on the Watch: a short note (dictate it) about this place in the book, sent to the
/// iPhone, which files it with its own notes in iCloud Drive › Audiobug.
struct WatchNoteView: View {
    let context: String
    let file: String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        Form {
            TextField("What's wrong here?", text: $text)
                .accessibilityIdentifier("note.text")
            Text("Noted at: \(context)").font(.footnote).foregroundStyle(.secondary)
            Button("Send to iPhone") {
                WatchLink.shared.sendNote(text, where: context, file: file)
                WKInterfaceDevice.current().play(.success)
                dismiss()
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle("Improvement")
    }
}
