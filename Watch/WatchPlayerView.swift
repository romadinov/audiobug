import AudiobugCore
import AVFoundation
import SwiftUI
import WatchKit

/// Two pages: our controls (speed, chapters, skips, volume on the Digital Crown) and the system Now Playing
/// page, which adds the audio-output picker.
struct WatchPlayerView: View {
    let book: Audiobook
    @Environment(Player.self) private var player

    var body: some View {
        TabView {
            ControlsPage(book: book)
            NowPlayingView()
        }
        .tabViewStyle(.verticalPage)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: book.id) { await player.open(book, autoplay: true) }
    }
}

private struct ControlsPage: View {
    let book: Audiobook
    @Environment(Player.self) private var player
    @Environment(Settings.self) private var settings
    @State private var showMore = false
    @State private var showSpeed = false

    private var isCurrent: Bool { player.book?.id == book.id }

    var body: some View {
        // A scroll view: the inline title bar insets it (a plain stack would sit under the title), and the
        // controls still fit on the smallest Watch.
        ScrollView {
        VStack(spacing: 8) {
            // The whole top half is a play/pause target: a tap anywhere on the title, progress, or times toggles.
            VStack(spacing: 8) {
                Text(player.currentChapter?.title ?? (isCurrent ? player.title : book.title))
                    .font(.footnote)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                ProgressView(value: player.duration > 0 ? min(1, player.currentTime / player.duration) : 0)
                    .tint(.accentColor)
                HStack {
                    Text(TimeFormat.clock(player.currentTime)).accessibilityIdentifier("player.elapsed")
                    Spacer()
                    Text("-" + TimeFormat.clock(player.remaining))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { togglePlayback() }
            HStack(spacing: 10) {
                Button { player.skipBack() } label: { Image(systemName: "gobackward.\(Int(settings.skipBack))") }
                Button { togglePlayback() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .accessibilityIdentifier("player.playPause")
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .buttonStyle(.borderedProminent)
                .handGestureShortcut(.primaryAction)   // Double Tap (Series 9 / Ultra 2 and later) = play/pause
                .disabled(player.isLoading || !isCurrent)
                Button { player.skipForward() } label: { Image(systemName: "goforward.\(Int(settings.skipForward))") }
            }
            .font(.title3)
            VolumeControl(tint: UIColor(Color.accentColor))
                .frame(height: 22)
                .accessibilityIdentifier("player.volume")
            HStack(spacing: 10) {
                Button { showSpeed = true } label: { Text(TimeFormat.rate(player.rate)).font(.footnote.weight(.semibold)) }
                    .accessibilityIdentifier("player.speed")
                Button { showMore = true } label: { Image(systemName: "ellipsis") }
                    .accessibilityIdentifier("player.more")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 4)
        }
        .background {
            // The cover, dimmed and softened behind the controls (as the system Now Playing page does).
            CoverView(book: book, cornerRadius: 0)
                .blur(radius: 10)
                .opacity(0.5)
                .ignoresSafeArea()
        }
        .navigationTitle(isCurrent ? player.title : book.title)
        .sheet(isPresented: $showSpeed) { SpeedSheet() }
        .sheet(isPresented: $showMore) { MoreSheet(book: book) }
    }

    private func togglePlayback() {
        guard isCurrent, !player.isLoading else { return }
        WKInterfaceDevice.current().play(player.isPlaying ? .stop : .start)
        player.toggle()
    }
}

private struct SpeedSheet: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(Settings.rates, id: \.self) { rate in
                Button {
                    player.setRate(rate)
                    dismiss()
                } label: {
                    HStack {
                        Text(TimeFormat.rate(rate))
                        Spacer()
                        if abs(player.rate - rate) < 0.01 { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
            }
        }
        .navigationTitle("Speed")
    }
}

private struct MoreSheet: View {
    let book: Audiobook
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var outputName = AudioSession.outputName

    var body: some View {
        NavigationStack {
            List {
                if !player.chapters.isEmpty {
                    NavigationLink {
                        List(player.chapters) { chapter in
                            Button {
                                player.jump(to: chapter)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(chapter.title).lineLimit(2)
                                    Spacer()
                                    if chapter == player.currentChapter { Image(systemName: "speaker.fill").foregroundStyle(.tint) }
                                }
                            }
                        }
                        .navigationTitle("Chapters")
                    } label: {
                        Label(player.currentChapter?.title ?? "Chapters", systemImage: "list.bullet")
                    }
                }
                Section("Audio output") {
                    Button {
                        chooseOutput()
                    } label: {
                        Label(outputName.isEmpty ? "Choose headphones…" : outputName, systemImage: "airpods")
                    }
                    Text("Swipe up on the player for the Now Playing page: its AirPlay button lists every output.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Sleep timer") {
                    ForEach([SleepTimer.off, .minutes(15), .minutes(30), .minutes(60), .endOfChapter], id: \.self) { timer in
                        Button {
                            player.setSleepTimer(timer)
                            dismiss()
                        } label: {
                            HStack {
                                Text(timer.label)
                                Spacer()
                                if player.sleepTimer == timer { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                }
                if DeveloperBuild.isDeveloper {
                    Section {
                        NavigationLink {
                            WatchNoteView(context: player.feedbackContext, file: book.url.lastPathComponent)
                        } label: {
                            Label("Suggest an Improvement", systemImage: "lightbulb")
                        }
                        .accessibilityIdentifier("player.suggest")
                    } footer: {
                        Text("A word read wrong here, or anything else: sent to the iPhone and on to the agents.")
                    }
                }
            }
            .navigationTitle("More")
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            outputName = AudioSession.outputName
        }
    }

    /// Re-activating the long-form session makes watchOS show its headphone picker when no headphones
    /// are connected.
    private func chooseOutput() {
        let wasPlaying = player.isPlaying
        if wasPlaying { player.pause() }
        AudioSession.deactivate()
        Task {
            let ok = await AudioSession.activate()
            outputName = AudioSession.outputName
            if ok, wasPlaying { player.play() }
        }
    }
}
