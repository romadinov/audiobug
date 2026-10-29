import AudiobugCore
import AVFoundation
import SwiftUI

struct PlayerView: View {
    let book: Audiobook
    @Environment(Player.self) private var player
    @Environment(WatchLink.self) private var watch
    @Environment(Settings.self) private var settings
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @State private var showChapters = false
    @State private var outputName = AudioSession.outputName
    @State private var coverRequest: CoverRequest?
    @State private var improvementNote: ImprovementNoteRequest?

    private var isCurrent: Bool { player.book?.id == book.id }
    private var shownTime: TimeInterval { scrubbing ? scrubTime : player.currentTime }

    var body: some View {
        VStack(spacing: 20) {
            artwork
            VStack(spacing: 4) {
                Text(isCurrent ? player.title : book.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let author = player.author, isCurrent {
                    Text(author).foregroundStyle(.secondary)
                }
                if isCurrent, !player.chapters.isEmpty {
                    Button { showChapters = true } label: {
                        Label(player.currentChapter?.title ?? "Chapters", systemImage: "list.bullet")
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("player.chapter")
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 6)
                }
            }
            scrubber
            transport
            extras
            Spacer(minLength: 0)
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if DeveloperBuild.isDeveloper {
                ToolbarItem(placement: .topBarTrailing) {
                    // A word read or stressed wrong right here: note it with the book, chapter and time.
                    Button {
                        Task { improvementNote = await .capture(context: player.feedbackContext, file: book.url.lastPathComponent) }
                    } label: { Label("Suggest an Improvement", systemImage: "lightbulb") }
                    .accessibilityIdentifier("player.suggest")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                RoutePickerButton().frame(width: 32, height: 32)
            }
        }
        .sheet(item: $improvementNote) { ImprovementNoteView(request: $0) }
        .task(id: book.id) { await player.open(book, autoplay: true) }
        .coverPicker($coverRequest)
        .sheet(isPresented: $showChapters) { ChaptersView() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            outputName = AudioSession.outputName
        }
    }

    /// The cover (long-press to choose another picture).
    private var artwork: some View {
        CoverView(book: book, contentMode: .fit, cornerRadius: 24)
            .frame(maxHeight: 300)
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            .padding(.horizontal, 24)
            .contextMenu { CoverMenu(book: book, request: $coverRequest) }
            .accessibilityIdentifier("player.cover")
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(value: Binding(get: { shownTime }, set: { scrubTime = $0 }),
                   in: 0...max(1, player.duration)) { editing in
                if editing {
                    scrubTime = player.currentTime
                    scrubbing = true
                } else {
                    scrubbing = false
                    Task { await player.seek(to: scrubTime) }
                }
            }
            .disabled(!isCurrent || player.isLoading)
            HStack {
                Text(TimeFormat.clock(shownTime)).accessibilityIdentifier("player.elapsed")
                Spacer()
                if player.isLoading, isCurrent {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(TimeFormat.compact(player.remainingAtRate)) left at \(TimeFormat.rate(player.rate))")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("player.remaining")
                }
                Spacer()
                Text("-" + TimeFormat.clock(max(0, player.duration - shownTime)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill") }
                .disabled(player.chapters.isEmpty)
            Button { player.skipBack() } label: {
                skipGlyph("gobackward", seconds: settings.skipBack)
            }
            .accessibilityIdentifier("player.skipBack")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
            }
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .disabled(!isCurrent || player.isLoading)
            Button { player.skipForward() } label: {
                skipGlyph("goforward", seconds: settings.skipForward)
            }
            .accessibilityIdentifier("player.skipForward")
            Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill") }
                .disabled(player.chapters.isEmpty)
        }
        .font(.title)
        .buttonStyle(.plain)
    }

    private func skipGlyph(_ base: String, seconds: TimeInterval) -> some View {
        let n = Int(seconds)
        let known = [10, 15, 30, 45, 60, 75, 90]
        return Image(systemName: known.contains(n) ? "\(base).\(n)" : base)
    }

    private var extras: some View {
        HStack(spacing: 12) {
            speedMenu
            sleepMenu
            outputControl
            watchButton
        }
        .font(.subheadline)
    }

    private var speedMenu: some View {
        Menu {
            Section("Speed") {
                ForEach(Settings.rates, id: \.self) { rate in
                    Button {
                        player.setRate(rate)
                    } label: {
                        if abs(player.rate - rate) < 0.01 {
                            Label(TimeFormat.rate(rate), systemImage: "checkmark")
                        } else {
                            Text(TimeFormat.rate(rate))
                        }
                    }
                }
            }
            Section {
                Button("Slower (−0.1)") { player.setRate(player.rate - 0.1) }
                Button("Faster (+0.1)") { player.setRate(player.rate + 0.1) }
            }
        } label: {
            pill(TimeFormat.rate(player.rate), systemImage: "gauge.with.dots.needle.67percent")
        }
        .accessibilityIdentifier("player.speed")
    }

    private var sleepMenu: some View {
        Menu {
            Button("Off") { player.setSleepTimer(.off) }
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") { player.setSleepTimer(.minutes(minutes)) }
            }
            Button("End of chapter") { player.setSleepTimer(.endOfChapter) }.disabled(player.chapters.isEmpty)
        } label: {
            pill(sleepLabel, systemImage: player.sleepTimer == .off ? "moon.zzz" : "moon.zzz.fill")
        }
        .accessibilityIdentifier("player.sleep")
    }

    private var sleepLabel: String {
        switch player.sleepTimer {
        case .off: return "Sleep"
        case .endOfChapter: return "Chapter"
        case .minutes:
            if let at = player.sleepsAt { return TimeFormat.clock(max(0, at.timeIntervalSinceNow)) }
            return "Sleep"
        }
    }

    /// The system output picker, with the current destination's name beside it.
    private var outputControl: some View {
        pill(outputName.isEmpty ? "Output" : outputName, systemImage: "airplay.audio")
            .overlay { RoutePickerButton(tint: .clear).opacity(0.02) }   // sized to the pill; the tap goes to the real picker
            .accessibilityIdentifier("player.output")
    }

    private var watchButton: some View {
        Group {
            if let progress = watch.transfers[book.id] {
                pill("\(Int(progress * 100))%", systemImage: "applewatch.radiowaves.left.and.right")
            } else if watch.isOnWatch(book) {
                Menu {
                    Button("Remove from Apple Watch", role: .destructive) { watch.remove(book) }
                } label: {
                    pill("On Watch", systemImage: "applewatch")
                }
            } else if watch.isAvailable {
                Button { watch.send(book) } label: { pill("To Watch", systemImage: "applewatch") }
                    .accessibilityIdentifier("player.toWatch")
            }
        }
    }

    private func pill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.primary)
    }
}

struct ChaptersView: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(player.chapters) { chapter in
                Button {
                    player.jump(to: chapter)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(chapter.title).foregroundStyle(.primary)
                            Text(TimeFormat.clock(chapter.start)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if chapter == player.currentChapter {
                            Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill").foregroundStyle(.tint)
                        }
                        Text(TimeFormat.compact(chapter.duration)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("chapter.\(chapter.id)")
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
