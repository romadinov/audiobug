import SwiftUI

/// A book's cover, or a headphones placeholder until one is found. `.fill` crops to the frame you give it
/// (list rows); `.fit` keeps the picture's shape (the player).
struct CoverView: View {
    let book: Audiobook
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let image = CoverStore.shared.image(for: book.id) {
                if contentMode == .fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
        .task(id: book.id) { await CoverStore.shared.load(book) }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius).fill(.quaternary)
            GeometryReader { geo in
                Image(systemName: "headphones")
                    .font(.system(size: max(12, min(geo.size.width, geo.size.height) * 0.4)))
                    .foregroundStyle(.secondary)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
