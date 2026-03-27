import MediaPlayer

@MainActor
class NowPlayingManager {
    static let shared = NowPlayingManager()

    private var playPauseHandler: (() -> Void)?
    private var playTarget: Any?
    private var pauseTarget: Any?
    private var toggleTarget: Any?

    func setup(onPlayPause: @escaping () -> Void) {
        playPauseHandler = onPlayPause

        let center = MPRemoteCommandCenter.shared()

        // Remove previous targets to avoid stacking
        if let t = playTarget { center.playCommand.removeTarget(t) }
        if let t = pauseTarget { center.pauseCommand.removeTarget(t) }
        if let t = toggleTarget { center.togglePlayPauseCommand.removeTarget(t) }

        center.playCommand.isEnabled = true
        playTarget = center.playCommand.addTarget { [weak self] _ in
            self?.playPauseHandler?()
            return .success
        }

        center.pauseCommand.isEnabled = true
        pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            self?.playPauseHandler?()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.playPauseHandler?()
            return .success
        }

        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
    }

    func updateNowPlaying(title: String, position: TimeInterval,
                          duration: TimeInterval, isPlaying: Bool) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    func clearNowPlaying() {
        let center = MPRemoteCommandCenter.shared()

        // Disable commands and remove targets so they stop intercepting the space key
        if let t = playTarget { center.playCommand.removeTarget(t); playTarget = nil }
        if let t = pauseTarget { center.pauseCommand.removeTarget(t); pauseTarget = nil }
        if let t = toggleTarget { center.togglePlayPauseCommand.removeTarget(t); toggleTarget = nil }
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false

        playPauseHandler = nil

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

}
