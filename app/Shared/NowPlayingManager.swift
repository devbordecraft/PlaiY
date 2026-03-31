import MediaPlayer

@MainActor
class NowPlayingManager {
    static let shared = NowPlayingManager()

    private var playHandler: (() -> Void)?
    private var pauseHandler: (() -> Void)?
    private var togglePlayPauseHandler: (() -> Void)?
    private var nextTrackHandler: (() -> Void)?
    private var previousTrackHandler: (() -> Void)?
    private var playTarget: Any?
    private var pauseTarget: Any?
    private var toggleTarget: Any?
    private var nextTarget: Any?
    private var prevTarget: Any?

    func setup(onPlay: @escaping () -> Void,
               onPause: @escaping () -> Void,
               onTogglePlayPause: @escaping () -> Void,
               onNextTrack: (() -> Void)? = nil,
               onPreviousTrack: (() -> Void)? = nil) {
        playHandler = onPlay
        pauseHandler = onPause
        togglePlayPauseHandler = onTogglePlayPause
        nextTrackHandler = onNextTrack
        previousTrackHandler = onPreviousTrack

        let center = MPRemoteCommandCenter.shared()

        // Remove previous targets to avoid stacking
        if let t = playTarget { center.playCommand.removeTarget(t) }
        if let t = pauseTarget { center.pauseCommand.removeTarget(t) }
        if let t = toggleTarget { center.togglePlayPauseCommand.removeTarget(t) }
        if let t = nextTarget { center.nextTrackCommand.removeTarget(t) }
        if let t = prevTarget { center.previousTrackCommand.removeTarget(t) }

        center.playCommand.isEnabled = true
        playTarget = center.playCommand.addTarget { [weak self] _ in
            self?.handlePlayCommand() ?? .commandFailed
        }

        center.pauseCommand.isEnabled = true
        pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            self?.handlePauseCommand() ?? .commandFailed
        }

        center.togglePlayPauseCommand.isEnabled = true
        toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handleTogglePlayPauseCommand() ?? .commandFailed
        }

        center.nextTrackCommand.isEnabled = (onNextTrack != nil)
        if onNextTrack != nil {
            nextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
                return self?.handleNextTrackCommand() ?? .commandFailed
            }
        }

        center.previousTrackCommand.isEnabled = (onPreviousTrack != nil)
        if onPreviousTrack != nil {
            prevTarget = center.previousTrackCommand.addTarget { [weak self] _ in
                return self?.handlePreviousTrackCommand() ?? .commandFailed
            }
        }
    }

    func handlePlayCommand() -> MPRemoteCommandHandlerStatus {
        playHandler?()
        return .success
    }

    func handlePauseCommand() -> MPRemoteCommandHandlerStatus {
        pauseHandler?()
        return .success
    }

    func handleTogglePlayPauseCommand() -> MPRemoteCommandHandlerStatus {
        togglePlayPauseHandler?()
        return .success
    }

    func handleNextTrackCommand() -> MPRemoteCommandHandlerStatus {
        nextTrackHandler?()
        return .success
    }

    func handlePreviousTrackCommand() -> MPRemoteCommandHandlerStatus {
        previousTrackHandler?()
        return .success
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
        if let t = nextTarget { center.nextTrackCommand.removeTarget(t); nextTarget = nil }
        if let t = prevTarget { center.previousTrackCommand.removeTarget(t); prevTarget = nil }
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false

        playHandler = nil
        pauseHandler = nil
        togglePlayPauseHandler = nil
        nextTrackHandler = nil
        previousTrackHandler = nil

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

}
