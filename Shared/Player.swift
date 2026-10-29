import AudiobugCore
import AVFoundation
import Foundation
import MediaPlayer
import Observation
import os

private let log = Logger(subsystem: "com.romadinov.audiobug", category: "Player")

enum SleepTimer: Hashable {
    case off
    case minutes(Int)
    case endOfChapter

    var label: String {
        switch self {
        case .off: return "Off"
        case .minutes(let m): return "\(m) min"
        case .endOfChapter: return "End of chapter"
        }
    }
}

/// The playback engine, shared by the iPhone and the Watch: one book at a time, remembers where you are,
/// plays at any speed, knows its chapters, and drives the lock screen / Now Playing controls.
@MainActor @Observable
final class Player {
    private(set) var book: Audiobook?
    private(set) var metadata: AudiobookMetadata?
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Float = 1.0
    private(set) var errorMessage: String?
    private(set) var sleepTimer: SleepTimer = .off
    private(set) var sleepsAt: Date?

    /// Called whenever a position is written, so it can be sent to the other device.
    var onPositionSaved: ((PlaybackPosition) -> Void)?

    var chapters: [Chapter] { metadata?.chapters ?? [] }
    /// Where an improvement note written in the player belongs: the book, the chapter, the time and the speed
    /// (what ebooker needs to find a word that was read wrong).
    var feedbackContext: String {
        var parts = [title]
        if let chapter = currentChapter { parts.append(chapter.title) }
        parts.append("at \(TimeFormat.clock(currentTime)) of \(TimeFormat.clock(duration)), \(TimeFormat.rate(rate))")
        return parts.joined(separator: ", ")
    }
    var currentChapter: Chapter? { metadata?.chapter(at: currentTime) }
    var title: String { metadata?.title ?? book?.title ?? "" }
    var author: String? { metadata?.author }
    var remaining: TimeInterval { max(0, duration - currentTime) }
    /// Remaining listening time at the current speed.
    var remainingAtRate: TimeInterval { remaining / Double(max(rate, 0.1)) }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var observers: [NSObjectProtocol] = []
    private var lastSave = Date.distantPast
    private var generation = 0
    private var sleepTask: Task<Void, Never>?
    private var finished = false
    private let settings = Settings.shared

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        AudioSession.configure()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
        observeSession()
        RemoteCommands.install(for: self)
    }

    // MARK: Opening

    /// Opens a book at its remembered position. Already open: just plays if asked.
    func open(_ book: Audiobook, autoplay: Bool = false) async {
        if self.book?.id == book.id {
            if autoplay { play() }
            return
        }
        if isPlaying { pause() } else { savePosition(force: true) }
        generation += 1
        let gen = generation
        self.book = book
        metadata = nil
        errorMessage = nil
        finished = false
        currentTime = 0
        duration = 0
        isLoading = true
        setSleepTimer(.off)

        let saved = Positions.shared.position(for: book.id)
        rate = saved?.rate ?? settings.defaultRate
        player.defaultRate = rate

        let item = AVPlayerItem(url: book.url)
        item.audioTimePitchAlgorithm = .timeDomain   // clear speech at any speed, cheap on the Watch
        player.replaceCurrentItem(with: item)

        let meta = try? await AudiobookInspector.load(book.url)
        guard gen == generation else { return }
        metadata = meta
        CoverStore.shared.offer(meta?.artwork, for: book.id)
        if let d = meta?.duration, d > 0 {
            duration = d
        } else if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
            duration = d.seconds
        }
        guard gen == generation else { return }
        if let saved, !saved.finished, saved.time < duration - 2 {
            await seek(to: saved.time, save: false)
        }
        isLoading = false
        NowPlaying.update(self, full: true)
        if autoplay { play() }
    }

    func close() {
        if isPlaying { pause() } else { savePosition(force: true) }
        generation += 1
        player.replaceCurrentItem(with: nil)
        book = nil
        metadata = nil
        NowPlaying.clear()
    }

    // MARK: Transport

    func play() {
        guard book != nil, !isPlaying else { return }
        if finished || (duration > 0 && currentTime >= duration - 0.5) {
            finished = false
            Task { await seek(to: 0) }
        }
        let gen = generation
        Task {
            guard await AudioSession.activate(), gen == generation else { return }
            player.playImmediately(atRate: rate)
            isPlaying = true
            NowPlaying.update(self)
            armSleepTimer()
        }
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
        savePosition(force: true)
        NowPlaying.update(self)
        sleepTask?.cancel()
    }

    func toggle() { isPlaying ? pause() : play() }

    func skipForward() { Task { await seek(to: currentTime + settings.skipForward) } }
    func skipBack() { Task { await seek(to: currentTime - settings.skipBack) } }

    func seek(to time: TimeInterval, save: Bool = true) async {
        let target = min(max(0, time), max(0, duration))
        let was = isPlaying
        finished = false
        await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = target
        if was { player.rate = rate }
        if save { savePosition(force: true) }
        NowPlaying.update(self)
    }

    func setRate(_ newRate: Float) {
        rate = min(max(newRate, 0.5), 3.0)
        player.defaultRate = rate
        if isPlaying { player.rate = rate }
        savePosition(force: true)
        NowPlaying.update(self)
    }

    // MARK: Chapters

    func jump(to chapter: Chapter) { Task { await seek(to: chapter.start) } }

    func nextChapter() {
        guard let current = currentChapter, let index = chapters.firstIndex(of: current), index + 1 < chapters.count else {
            return
        }
        jump(to: chapters[index + 1])
    }

    /// Back to the start of this chapter, or to the previous one when already near its start.
    func previousChapter() {
        guard let current = currentChapter, let index = chapters.firstIndex(of: current) else {
            Task { await seek(to: 0) }
            return
        }
        if currentTime - current.start > 3 || index == 0 {
            jump(to: current)
        } else {
            jump(to: chapters[index - 1])
        }
    }

    // MARK: Sleep timer

    func setSleepTimer(_ timer: SleepTimer) {
        sleepTimer = timer
        switch timer {
        case .off: sleepsAt = nil
        case .minutes(let m): sleepsAt = Date().addingTimeInterval(TimeInterval(m * 60))
        case .endOfChapter: sleepsAt = nil
        }
        armSleepTimer()
    }

    private func armSleepTimer() {
        sleepTask?.cancel()
        guard isPlaying, sleepTimer != .off else { return }
        let gen = generation
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, gen == self.generation, self.isPlaying else { return }
                switch self.sleepTimer {
                case .minutes:
                    if let at = self.sleepsAt, Date() >= at {
                        self.pause()
                        self.setSleepTimer(.off)
                        return
                    }
                case .endOfChapter:
                    if let chapter = self.currentChapter, self.currentTime >= chapter.end - 0.6 {
                        self.pause()
                        self.setSleepTimer(.off)
                        return
                    }
                case .off: return
                }
            }
        }
    }

    // MARK: Positions

    private func tick(_ time: CMTime) {
        guard time.seconds.isFinite, !isLoading else { return }
        currentTime = time.seconds
        if isPlaying, Date().timeIntervalSince(lastSave) > 5 { savePosition() }
    }

    func savePosition(force: Bool = false) {
        guard let book, duration > 0 || force else { return }
        lastSave = Date()
        let position = PlaybackPosition(bookID: book.id, time: currentTime, duration: duration > 0 ? duration : nil,
                                        rate: rate, finished: finished, device: DeviceName.current)
        Positions.shared.save(position)
        onPositionSaved?(position)
    }

    /// A newer position arrived from the other device: move there unless we're playing right now.
    func apply(remote position: PlaybackPosition) {
        guard let book, book.id == position.bookID, !isPlaying else { return }
        if let r = position.rate { rate = r; player.defaultRate = r }
        Task { await seek(to: position.time, save: false) }
    }

    // MARK: Session events

    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.interrupted(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.routeChanged(note) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem, item == self.player.currentItem else { return }
                self.finished = true
                self.isPlaying = false
                self.currentTime = self.duration
                self.savePosition(force: true)
                self.NowPlayingClear()
            }
        })
    }

    private func NowPlayingClear() { NowPlaying.update(self) }

    private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isPlaying { pause() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume) { play() }
        @unknown default: break
        }
    }

    private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones unplugged / AirPods taken off: don't blast the speaker.
        if reason == .oldDeviceUnavailable, isPlaying { pause() }
        log.info("Route changed (\(raw)): \(AudioSession.outputName, privacy: .public)")
    }
}
