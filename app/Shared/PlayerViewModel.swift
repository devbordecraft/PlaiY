import Foundation
import Combine
import CoreGraphics

class PlayerViewModel: ObservableObject {
    let bridge = PlayerBridge()

    @Published var isPlaying = false
    @Published var currentPosition: Int64 = 0
    @Published var duration: Int64 = 0
    @Published var currentSubtitle: SubtitleData?
    @Published var mediaTitle: String = ""
    @Published var audioTracks: [TrackInfo] = []
    @Published var subtitleTracks: [TrackInfo] = []
    @Published var activeAudioStream: Int = -1
    @Published var activeSubtitleStream: Int = -1
    @Published var isMuted = false
    @Published var passthroughEnabled = false
    @Published var passthroughActive = false
    @Published var showDebugOverlay = false
    @Published var playbackStats: PYPlaybackStats?
    @Published var playbackEnded = false

    // Timeline interaction state
    @Published var isHoveringTimeline = false
    @Published var isDraggingTimeline = false
    @Published var hoverFraction: Double = 0
    @Published var seekPreviewImage: CGImage?

    private var positionTimer: Timer?

    func open(path: String, settings: AppSettings) {
        playbackEnded = false

        // Apply settings before opening
        bridge.setHWDecodePref(Int32(settings.hwDecodePref))
        bridge.setSubtitleFontScale(settings.assFontScale)

        guard bridge.open(path: path) else { return }
        duration = bridge.duration

        // Apply audio passthrough preference
        bridge.setAudioPassthrough(settings.audioPassthrough)
        passthroughEnabled = settings.audioPassthrough

        // Extract title from path
        let url = URL(fileURLWithPath: path)
        mediaTitle = url.deletingPathExtension().lastPathComponent

        // Parse track info
        let json = bridge.mediaInfoJSON()
        let parsed = TrackInfo.parseTracks(from: json)
        audioTracks = parsed.audio
        subtitleTracks = parsed.subtitle
        activeAudioStream = Int(bridge.activeAudioStream)
        activeSubtitleStream = Int(bridge.activeSubtitleStream)

        // Auto-select preferred audio language
        if !settings.preferredAudioLanguage.isEmpty {
            if let match = audioTracks.first(where: { $0.language == settings.preferredAudioLanguage }) {
                selectAudioTrack(streamIndex: match.streamIndex)
            }
        }

        // Auto-select preferred subtitle language
        if settings.autoSelectSubtitles && !settings.preferredSubtitleLanguage.isEmpty {
            if let match = subtitleTracks.first(where: { $0.language == settings.preferredSubtitleLanguage }) {
                selectSubtitleTrack(streamIndex: match.streamIndex)
            }
        } else if !settings.autoSelectSubtitles {
            disableSubtitles()
        }

        // Start background seek thumbnail generation
        let interval: Int32 = duration > 7_200_000_000 ? 30 : 10
        bridge.startSeekThumbnails(interval: interval)

        // Set up media key handling
        NowPlayingManager.shared.setup(onPlayPause: { [weak self] in
            self?.togglePlayPause()
        })
    }

    func play() {
        bridge.play()
        isPlaying = true
        startPositionUpdates()
    }

    func pause() {
        bridge.pause()
        isPlaying = false
        stopPositionUpdates()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to fraction: Double) {
        let target = Int64(fraction * Double(duration))
        bridge.seek(to: target)
        currentPosition = target
    }

    func seekRelative(seconds: Double) {
        let offsetUs = Int64(seconds * 1_000_000)
        let target = max(0, min(duration, currentPosition + offsetUs))
        bridge.seek(to: target)
        currentPosition = target
    }

    func toggleMute() {
        isMuted.toggle()
        bridge.setMuted(isMuted)
    }

    func stop() {
        bridge.cancelSeekThumbnails()
        bridge.stop()
        isPlaying = false
        currentPosition = 0
        seekPreviewImage = nil
        stopPositionUpdates()
        NowPlayingManager.shared.clearNowPlaying()
    }

    var positionFraction: Double {
        guard duration > 0 else { return 0 }
        return Double(currentPosition) / Double(duration)
    }

    var positionText: String {
        formatTime(currentPosition)
    }

    var durationText: String {
        formatTime(duration)
    }

    private func startPositionUpdates() {
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }

            // Detect end-of-stream (C++ engine sets Stopped on EOF)
            if self.bridge.state == PY_STATE_STOPPED.rawValue {
                self.isPlaying = false
                self.stopPositionUpdates()
                self.playbackEnded = true
                return
            }

            self.currentPosition = self.bridge.position
            self.currentSubtitle = self.bridge.getSubtitle(at: self.currentPosition)
            self.passthroughActive = self.bridge.isPassthroughActive
            if self.showDebugOverlay {
                self.playbackStats = self.bridge.getPlaybackStats()
            }

            NowPlayingManager.shared.updateNowPlaying(
                title: self.mediaTitle,
                position: Double(self.currentPosition) / 1_000_000.0,
                duration: Double(self.duration) / 1_000_000.0,
                isPlaying: self.isPlaying
            )
        }
    }

    private func stopPositionUpdates() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    func selectAudioTrack(streamIndex: Int) {
        bridge.selectAudioTrack(Int32(streamIndex))
        activeAudioStream = streamIndex
    }

    func selectSubtitleTrack(streamIndex: Int) {
        bridge.selectSubtitleTrack(Int32(streamIndex))
        activeSubtitleStream = streamIndex
    }

    func disableSubtitles() {
        bridge.selectSubtitleTrack(-1)
        activeSubtitleStream = -1
    }

    func setPassthrough(_ enabled: Bool) {
        passthroughEnabled = enabled
        bridge.setAudioPassthrough(enabled)
    }

    // MARK: - Timeline interaction

    func timelineHoverChanged(_ hovering: Bool) {
        isHoveringTimeline = hovering
        if !hovering {
            seekPreviewImage = nil
        }
    }

    func timelineHoverMoved(fraction: Double) {
        hoverFraction = max(0, min(1, fraction))
        updateSeekPreview()
    }

    func timelineDragStarted() {
        isDraggingTimeline = true
    }

    func timelineDragChanged(fraction: Double) {
        let clamped = max(0, min(1, fraction))
        hoverFraction = clamped
        seek(to: clamped)
        updateSeekPreview()
    }

    func timelineDragEnded() {
        isDraggingTimeline = false
        seekPreviewImage = nil
    }

    private func updateSeekPreview() {
        guard duration > 0 else { return }
        let timestampUs = Int64(hoverFraction * Double(duration))
        seekPreviewImage = bridge.seekThumbnail(at: timestampUs)
    }

    func timeText(for fraction: Double) -> String {
        let us = Int64(fraction * Double(duration))
        return formatTime(us)
    }

    private func formatTime(_ us: Int64) -> String {
        let totalSeconds = Int(us / 1_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
