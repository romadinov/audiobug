import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A request to pick a new cover for a book, from Photos or from Files.
struct CoverRequest: Equatable {
    enum Source { case photos, files }
    let book: Audiobook
    let source: Source
}

/// The "Cover" menu for a book: choose a picture, or go back to the book's own art.
struct CoverMenu: View {
    let book: Audiobook
    @Binding var request: CoverRequest?
    @Environment(WatchLink.self) private var watch

    var body: some View {
        Menu("Cover", systemImage: "photo") {
            Button("Choose from Photos", systemImage: "photo.on.rectangle") { request = CoverRequest(book: book, source: .photos) }
            Button("Choose from Files", systemImage: "folder") { request = CoverRequest(book: book, source: .files) }
            if CoverStore.shared.isCustom(book.id) {
                Button("Use the Book's Own Cover", systemImage: "arrow.uturn.backward") {
                    Task {
                        await CoverStore.shared.removeCustom(book)
                        watch.sendCover(book)
                    }
                }
            }
        }
    }
}

extension View {
    /// Presents the Photos / Files picker for a `CoverRequest` and stores the chosen picture as the book's cover.
    func coverPicker(_ request: Binding<CoverRequest?>) -> some View {
        modifier(CoverPickerModifier(request: request))
    }
}

private struct CoverPickerModifier: ViewModifier {
    @Binding var request: CoverRequest?
    @State private var target: Audiobook?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var photoItem: PhotosPickerItem?
    @Environment(WatchLink.self) private var watch

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, new in
                guard let new else { return }
                target = new.book
                switch new.source {
                case .photos: showPhotos = true
                case .files: showFiles = true
                }
                request = nil   // ready for the next request, even for the same book
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { apply(data) }
                }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { apply(data) }
            }
    }

    private func apply(_ data: Data) {
        guard let target else { return }
        if CoverStore.shared.setCustom(data, for: target.id) { watch.sendCover(target) }
    }
}
