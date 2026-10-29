import AudiobugCore
import SwiftUI

struct WatchRootView: View {
    @Environment(WatchLibrary.self) private var library
    @Environment(Player.self) private var player
    @Environment(WatchLink.self) private var link
    @State private var downloader = WiFiDownloader.shared

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            Group {
                if let job = downloader.current {
                    List {
                        Section("Receiving over Wi-Fi") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.title).lineLimit(2)
                                ProgressView(value: downloader.fraction)
                                Text("\(Int(downloader.fraction * 100))% · \(SyncMessages.rate(downloader.bytesPerSecond))")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("Cancel", role: .destructive) { downloader.cancel() }
                        }
                        if let error = link.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                } else if library.books.isEmpty {
                    ContentUnavailableView {
                        Label("No books yet", systemImage: "headphones")
                    } description: {
                        Text("On the iPhone, choose a book's “Send to Apple Watch”.")
                    }
                } else {
                    List {
                        ForEach(library.books) { book in
                            Button { library.selected = book } label: { WatchBookRow(book: book, position: Positions.shared.position(for: book.id)) }
                                .accessibilityIdentifier("book.\(book.title)")
                                .swipeActions {
                                    Button(role: .destructive) { library.delete(book); link.reportBooks() } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        Section {
                            Text("\(ByteCountFormatter.string(fromByteCount: library.totalBytes, countStyle: .file)) of books · \(ByteCountFormatter.string(fromByteCount: library.freeBytes, countStyle: .file)) free")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Audiobug")
            .navigationDestination(item: $library.selected) { book in
                WatchPlayerView(book: book)
            }
            .toolbar {
                if let book = player.book, library.selected == nil {
                    ToolbarItem(placement: .bottomBar) {
                        Button { library.selected = book } label: {
                            Label(player.isPlaying ? "Playing" : "Paused", systemImage: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        }
                    }
                }
            }
        }
    }
}

struct WatchBookRow: View {
    let book: Audiobook
    let position: PlaybackPosition?
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 8) {
            CoverView(book: book, contentMode: .fit, cornerRadius: 6).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(book.title).lineLimit(2)
                    if player.book?.id == book.id {
                        Spacer()
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                    }
                }
                if let position, let duration = position.duration {
                    Text(position.finished ? "Finished" : "\(TimeFormat.compact(duration - position.time)) left")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !position.finished { ProgressView(value: position.fraction ?? 0) }
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
