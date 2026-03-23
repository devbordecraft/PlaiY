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
    @Published var playbackSpeed: Double = 1.0
    @Published var passthroughEnabled = false
    @Published var passthroughActive = false
    @Published var showDebugOverlay = false
    @Published var playbackStats: PYPlaybackStats?
    @Published var playbackEnded = false

    // Timeline interaction state
    var isHoveringTimeline = false
    var isDraggingTimeline = false
    var hoverFraction: Double = 0
    var seekPreviewImage: CGImage?

    private var positionTimer: Timer?

    // Thumbnail async loading
    private let thumbQueue = DispatchQueue(label: "com.plaiy.seekthumb", qos: .userInitiated)
    private var thumbRequestId: UInt64 = 0
    private var lastThumbIndex: Int = -1

    private var pendingSeekFraction: Double?
    private var hoverEndWork: DispatchWorkItem?

    func open(path: String, settings: AppSettings) {
        playbackEnded = false
        playbackSpeed = 1.0

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

    private static let speedPresets: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

    func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        bridge.setPlaybackSpeed(speed)
    }

    func cycleSpeedUp() {
        if let idx = Self.speedPresets.firstIndex(where: { $0 > playbackSpeed + 0.01 }) {
            setPlaybackSpeed(Self.speedPresets[idx])
        }
    }

    func cycleSpeedDown() {
        if let idx = Self.speedPresets.lastIndex(where: { $0 < playbackSpeed - 0.01 }) {
            setPlaybackSpeed(Self.speedPresets[idx])
        }
    }

    func stop() {
        bridge.cancelSeekThumbnails()
        bridge.stop()
        isPlaying = false
        currentPosition = 0
        playbackSpeed = 1.0
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

            // Skip @Published updates during timeline interaction to avoid
            // objectWillChange churn that competes with Metal draw(in:)
            if self.isHoveringTimeline || self.isDraggingTimeline { return }

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
        hoverEndWork?.cancel()
        hoverEndWork = nil
        if hovering {
            isHoveringTimeline = true
        } else {
            // Delay hover-end so the position timer doesn't resume during quick re-entry
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isHoveringTimeline = false
                self.seekPreviewImage = nil
                self.lastThumbIndex = -1
            }
            hoverEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func timelineHoverMoved(fraction: Double) {
        hoverFraction = max(0, min(1, fraction))
        updateSeekPreview(fraction: hoverFraction)
    }

    func timelineDragStarted() {
        isDraggingTimeline = true
    }

    func timelineDragChanged(fraction: Double) {
        let clamped = max(0, min(1, fraction))
        hoverFraction = clamped
        updateSeekPreview(fraction: clamped)
        pendingSeekFraction = clamped
    }

    func timelineDragEnded() {
        if let fraction = pendingSeekFraction {
            seek(to: fraction)
        }
        pendingSeekFraction = nil

        isDraggingTimeline = false
        seekPreviewImage = nil
        lastThumbIndex = -1
    }

    private func updateSeekPreview(fraction: Double) {
        guard duration > 0 else { return }
        let timestampUs = Int64(fraction * Double(duration))

        // Skip dispatch if quantized thumbnail index hasn't changed
        let intervalSec = duration > 7_200_000_000 ? 30 : 10
        let index = Int(timestampUs / 1_000_000) / intervalSec
        guard index != lastThumbIndex else { return }
        lastThumbIndex = index

        thumbRequestId &+= 1
        let requestId = thumbRequestId
        let bridge = self.bridge

        thumbQueue.async { [weak self] in
            guard let self, self.thumbRequestId == requestId else { return }
            let image = bridge.seekThumbnail(at: timestampUs)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.thumbRequestId == requestId else { return }
                self.seekPreviewImage = image
            }
        }
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
