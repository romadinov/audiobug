import AudiobugCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(Player.self) private var player
    @Environment(WatchLink.self) private var watch
    @Environment(UploadServer.self) private var uploadServer
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showUpload = false
    @State private var inboxReport: InboxSync.Report?
    @State private var pendingDelete: Audiobook?
    @State private var coverRequest: CoverRequest?
    @State private var improvementNote: ImprovementNoteRequest?

    private static let audioTypes: [UTType] = [.audio, .mpeg4Audio, .mp3, .wav, .aiff] + [UTType(filenameExtension: "m4b")].compactMap { $0 }

    var body: some View {
        @Bindable var library = library
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Audiobug")
            .navigationDestination(item: $library.selected) { book in
                PlayerView(book: book)
            }
            .safeAreaInset(edge: .bottom) { miniPlayer }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { menu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Label("Add Books", systemImage: "plus") }
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.audioTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { library.importFiles(urls) }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showUpload) { UploadServerView() }
        .sheet(item: $improvementNote) { ImprovementNoteView(request: $0) }
        .alert("Inbox synced", isPresented: Binding(get: { inboxReport != nil }, set: { if !$0 { inboxReport = nil } }),
               presenting: inboxReport) { _ in
            Button("OK") {}
        } message: { report in
            Text(report.summary)
        }
        .alert("Couldn't import", isPresented: Binding(get: { library.importError != nil }, set: { if !$0 { library.importError = nil } })) {
            Button("OK") {}
        } message: {
            Text(library.importError ?? "")
        }
        .alert("Apple Watch", isPresented: Binding(get: { watch.lastError != nil }, set: { if !$0 { watch.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(watch.lastError ?? "")
        }
        .confirmationDialog("Delete this book from the iPhone?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { book in
            Button("Delete \(book.title)", role: .destructive) { library.delete(book) }
        }
    }

    private var list: some View {
        List {
            if uploadServer.isRunning {
                Section { UploadServerBanner { showUpload = true } }
            }
            if !library.autoImported.isEmpty {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "icloud.and.arrow.down").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Imported from the Inbox").font(.subheadline.weight(.semibold))
                            Text(library.autoImported.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { library.autoImported = [] } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(library.sections, id: \.folder) { section in
                Section(section.folder.isEmpty ? "" : section.folder) {
                    ForEach(section.books) { book in
                        Button { library.open(book) } label: { BookRow(book: book, position: Positions.shared.position(for: book.id)) }
                            .accessibilityIdentifier("book.\(book.title)")
                            .tint(.primary)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = book } label: { Label("Delete", systemImage: "trash") }
                            }
                            .contextMenu { bookMenu(book) }
                    }
                }
            }
        }
        .refreshable {
            if let report = await library.syncInbox() { inboxReport = report }
        }
        .coverPicker($coverRequest)
    }

    @ViewBuilder
    private func bookMenu(_ book: Audiobook) -> some View {
        if watch.isAvailable {
            if watch.transfers[book.id] != nil {
                Button("Cancel sending to Watch", systemImage: "xmark") { watch.cancelSend(book) }
            } else if watch.wifiTransfers[book.id] != nil {
                Button("Cancel Wi-Fi transfer", systemImage: "xmark") { watch.cancelWiFiSend(book) }
            } else if watch.isOnWatch(book) {
                Button("Remove from Apple Watch", systemImage: "applewatch.slash") { watch.remove(book) }
            } else {
                Button("Send to Apple Watch", systemImage: "applewatch") { watch.send(book) }
                Button("Send over Wi-Fi (test)", systemImage: "wifi") { watch.sendOverWiFi(book) }
            }
        }
        CoverMenu(book: book, request: $coverRequest)
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = book }
    }

    private var menu: some View {
        Menu {
            Button("Sync iCloud Inbox", systemImage: "icloud.and.arrow.down") {
                Task { if let report = await library.syncInbox() { inboxReport = report } }
            }
            .disabled(library.isSyncingInbox)
            Button(uploadServer.isRunning ? "Wi-Fi Upload (on)…" : "Wi-Fi Upload…", systemImage: "wifi") { showUpload = true }
            Button("Settings", systemImage: "gear") { showSettings = true }
            if DeveloperBuild.isDeveloper {
                Button("Suggest an Improvement…", systemImage: "lightbulb") {
                    let context = player.book != nil && library.selected == nil ? "Library, playing \(player.feedbackContext)" : "Library"
                    Task { improvementNote = await .capture(context: context, file: player.book?.url.lastPathComponent) }
                }
            }
            if !library.inboxLocation.isEmpty {
                Section("Drop books into") { Text(library.inboxLocation) }
            }
        } label: {
            if library.isSyncingInbox { ProgressView() } else { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No audiobooks yet", systemImage: "headphones")
        } description: {
            Text("Tap + to pick M4B, M4A or MP3 files, open a book from Files or AirDrop, upload from a computer over Wi-Fi, or drop books into \(library.inboxLocation.isEmpty ? "the Inbox" : library.inboxLocation) — they're imported automatically.")
        } actions: {
            Button("Add Books") { showImporter = true }.buttonStyle(.borderedProminent)
            Button("Sync iCloud Inbox") { Task { if let report = await library.syncInbox() { inboxReport = report } } }
            Button("Upload over Wi-Fi") { showUpload = true }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if let book = player.book, library.selected == nil {
            HStack(spacing: 12) {
                Button { library.open(book) } label: {
                    HStack(spacing: 12) {
                        CoverView(book: book, contentMode: .fit).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(player.currentChapter?.title ?? TimeFormat.clock(player.currentTime)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                Button { player.skipBack() } label: { Image(systemName: "gobackward") }
                Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2) }
                    .accessibilityIdentifier("mini.playPause")
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skipForward() } label: { Image(systemName: "goforward") }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }
}

struct BookRow: View {
    let book: Audiobook
    let position: PlaybackPosition?
    @Environment(WatchLink.self) private var watch
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 12) {
            CoverView(book: book, contentMode: .fit).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).foregroundStyle(.primary).lineLimit(2)
                Text(status(position)).font(.caption).foregroundStyle(.secondary)
                if let fraction = position?.fraction, !(position?.finished ?? false) {
                    ProgressView(value: fraction).tint(.accentColor)
                }
            }
            Spacer()
            if let progress = watch.transfers[book.id] {
                VStack(spacing: 2) {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                    Text("\(Int(progress * 100))%").font(.caption2)
                }
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("row.transfer")
            } else if let wifi = watch.wifiTransfers[book.id] {
                VStack(spacing: 2) {
                    Image(systemName: "wifi")
                    Text("\(Int(wifi.fraction * 100))%").font(.caption2)
                    Text(SyncMessages.rate(wifi.bytesPerSecond)).font(.caption2)
                }
                .foregroundStyle(Color.accentColor)
            } else if watch.isOnWatch(book) {
                Image(systemName: "applewatch").foregroundStyle(.secondary)
                    .accessibilityIdentifier("row.onWatch")
            }
            if player.book?.id == book.id {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func status(_ position: PlaybackPosition?) -> String {
        let size = ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file)
        guard let position else { return "Not started · \(size)" }
        if position.finished { return "Finished · \(size)" }
        if let duration = position.duration {
            return "\(TimeFormat.compact(duration - position.time)) left · \(Int((position.fraction ?? 0) * 100))%"
        }
        return "At \(TimeFormat.clock(position.time))"
    }
}

struct SettingsView: View {
    @Environment(Settings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Playback") {
                    Picker("Default speed", selection: $settings.defaultRate) {
                        ForEach(Settings.rates, id: \.self) { Text(TimeFormat.rate($0)).tag($0) }
                    }
                    Picker("Skip forward", selection: $settings.skipForward) {
                        ForEach(Settings.skipChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    Picker("Skip back", selection: $settings.skipBack) {
                        ForEach(Settings.skipChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                }
                Section {
                    Text(library.inboxLocation.isEmpty ? "Resolving…" : library.inboxLocation)
                } header: {
                    Text("iCloud Inbox")
                } footer: {
                    Text("The Inbox mirrors the folders of your library. Drop audiobooks there from any device; they are imported into the same folder here (also in the background) and then removed from the Inbox. The library itself is in Files › On My iPhone › Audiobug › Books.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
