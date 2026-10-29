import AudiobugCore
import Foundation
import MediaPlayer
import UIKit

/// Lock screen / Control Centre / Watch Now Playing information.
@MainActor
enum NowPlaying {
    private static var artworkCache: (image: UIImage, artwork: MPMediaItemArtwork)?

    static func update(_ player: Player, full: Bool = false) {
        guard let book = player.book else { clear(); return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: player.currentChapter?.title ?? player.title,
            MPMediaItemPropertyAlbumTitle: player.title,
            MPMediaItemPropertyPlaybackDuration: player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? Double(player.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let author = player.author { info[MPMediaItemPropertyArtist] = author }
        if let chapter = player.currentChapter, let index = player.chapters.firstIndex(of: chapter) {
            info[MPNowPlayingInfoPropertyChapterNumber] = index + 1
            info[MPNowPlayingInfoPropertyChapterCount] = player.chapters.count
        }
        if let image = CoverStore.shared.image(for: book.id) ?? player.metadata?.artwork.flatMap(UIImage.init(data:)) {
            if let cached = artworkCache, cached.image === image {
                info[MPMediaItemPropertyArtwork] = cached.artwork
            } else {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                artworkCache = (image, artwork)
                info[MPMediaItemPropertyArtwork] = artwork
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    static func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

/// Headphone buttons, lock screen and Watch Now Playing controls.
@MainActor
enum RemoteCommands {
    private static var installed = false

    static func install(for player: Player) {
        guard !installed else { return }
        installed = true
        let settings = Settings.shared
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak player] _ in player?.play(); return .success }
        center.pauseCommand.addTarget { [weak player] _ in player?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak player] _ in player?.toggle(); return .success }
        center.stopCommand.addTarget { [weak player] _ in player?.pause(); return .success }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: settings.skipForward)]
        center.skipForwardCommand.addTarget { [weak player] event in
            guard let player else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? settings.skipForward
            Task { await player.seek(to: player.currentTime + interval) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: settings.skipBack)]
        center.skipBackwardCommand.addTarget { [weak player] event in
            guard let player else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? settings.skipBack
            Task { await player.seek(to: player.currentTime - interval) }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak player] _ in player?.nextChapter(); return .success }
        center.previousTrackCommand.addTarget { [weak player] _ in player?.previousChapter(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak player] event in
            guard let player, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { await player.seek(to: event.positionTime) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Settings.rates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak player] event in
            guard let player, let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            player.setRate(event.playbackRate)
            return .success
        }
    }
}
