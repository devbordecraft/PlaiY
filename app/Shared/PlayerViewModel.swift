import Foundation
import Combine
import CoreGraphics
import QuartzCore

// ---------------------------------------------------------------------------
// PlaybackTransport: high-frequency state that must NOT trigger SwiftUI
// objectWillChange. Views that need these values poll via their own timers.
// This is the key to preventing UI interactions from dropping video frames.
// ---------------------------------------------------------------------------
@MainActor
final class PlaybackTransport {
    // Written by tick(), read by controls/subtitle views
    var currentPosition: Int64 = 0 {
        didSet {
            // Only reformat when the displayed second changes
            let newSec = Int(currentPosition / 1_000_000)
            if newSec != cachedPositionSec {
                cachedPositionSec = newSec
                cachedPositionText = formatTime(currentPosition)
            }
        }
    }
    var duration: Int64 = 0 {
        didSet { cachedDurationText = formatTime(duration) }
    }
    var currentSubtitle: SubtitleData?
    var passthroughActive: Bool = false
    var spatialActive: Bool = false
    var playbackStats: PYPlaybackStats?

    // Display settings (aspect ratio, crop, zoom, pan)
    // Accessed from both main thread and Metal render thread.
    nonisolated(unsafe) var displaySettings: VideoDisplaySettings = .default
    nonisolated(unsafe) var pendingCropDetection = false
    nonisolated(unsafe) var onCropDetected: (@Sendable (CropInsets) -> Void)?

    // Seek preview (written by thumb queue, read by controls view)
    nonisolated(unsafe) var seekPreviewImage: CGImage?

    // Interaction flags (written by controls, read by auto-hide timer)
    var isHoveringTimeline = false
    var isDraggingTimeline = false
    var isHoveringVolume = false
    var isHoveringControls = false
    var hoverFraction: Double = 0

    var isUserInteracting: Bool {
        isHoveringTimeline || isDraggingTimeline || isHoveringVolume || isHoveringControls
    }

    /// True only when the user is actively scrubbing the timeline.
    /// Used by tick() to avoid overwriting the scrub position.
    var isScrubbing: Bool {
        isHoveringTimeline || isDraggingTimeline
    }

    var positionFraction: Double {
        guard duration > 0 else { return 0 }
        return Double(currentPosition) / Double(duration)
    }

    func formatTime(_ us: Int64) -> String {
        TimeFormatting.display(us)
    }

    // Cached text — only reformatted when the second changes
    private var cachedPositionSec: Int = -1
    private(set) var cachedPositionText: String = "0:00"
    private(set) var cachedDurationText: String = "0:00"
    var positionText: String { cachedPositionText }
    var durationText: String { cachedDurationText }
}

// ---------------------------------------------------------------------------
// PlayerViewModel: only @Published properties that genuinely need to rebuild
// the SwiftUI view tree. High-frequency data lives in `transport`.
// ---------------------------------------------------------------------------
@MainActor
class PlayerViewModel: ObservableObject {
    let bridge = PlayerBridge()
    let transport = PlaybackTransport()

    // --- Properties that trigger view rebuilds (infrequent changes) ---
    @Published var isPlaying = false
    @Published var mediaTitle: String = ""
    @Published var audioTracks: [TrackInfo] = []
    @Published var subtitleTracks: [TrackInfo] = []
    @Published var activeAudioStream: Int = -1
    @Published var activeSubtitleStream: Int = -1
    @Published var isMuted = false
    // volume is NOT @Published — slider drag must not fire objectWillChange.
    // VolumeControlView uses local @State and reads this directly.
    var volume: Float = 1.0
    private var preMuteVolume: Float = 1.0
    @Published var playbackSpeed: Double = 1.0
    @Published var passthroughEnabled = false
    @Published var passthroughCaps = PYPassthroughCapabilities(ac3: false, eac3: false, dts: false, dts_hd_ma: false, truehd: false)
    @Published var headTrackingEnabled = false
    @Published var showDebugOverlay = false
    @Published var playbackEnded = false
    @Published var aspectRatioMode: AspectRatioMode = .auto
    @Published var cropActive: Bool = false
    @Published var openError: String?

    // NOT @Published — ContentView reads this in one-shot closures (onBack, playbackEnded),
    // not in body. Avoiding @Published prevents once-per-second PlayerView rebuilds.
    var currentPosition: Int64 = 0
    var duration: Int64 {
        get { transport.duration }
        set { transport.duration = newValue }
    }

    // Throttles for expensive per-frame operations
    private var lastNowPlayingUpdate: CFTimeInterval = 0
    private var lastSubtitleUpdate: CFTimeInterval = 0

    // Thumbnail async loading
    private let thumbQueue = DispatchQueue(label: "com.plaiy.seekthumb", qos: .userInitiated)
    private var thumbRequestId: UInt64 = 0
    private var lastThumbIndex: Int = -1

    private var pendingSeekFraction: Double?
    private var hoverEndWork: DispatchWorkItem?


    func open(path: String, settings: AppSettings) {
        playbackEnded = false
        playbackSpeed = 1.0

        bridge.setHWDecodePref(Int32(settings.hwDecodePref))
        bridge.setSubtitleFontScale(settings.assFontScale)
        bridge.setSpatialAudioMode(Int32(settings.spatialAudioMode))
        bridge.setHeadTracking(settings.headTrackingEnabled)
        headTrackingEnabled = settings.headTrackingEnabled

        guard bridge.open(path: path) else {
            openError = "Could not open: \(URL(fileURLWithPath: path).lastPathComponent)"
            mediaTitle = ""
            audioTracks = []
            subtitleTracks = []
            return
        }
        openError = nil
        transport.duration = bridge.duration

        bridge.setAudioPassthrough(settings.audioPassthrough)
        passthroughEnabled = settings.audioPassthrough
        passthroughCaps = bridge.queryPassthroughSupport()

        bridge.setDeviceChangeCallback { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.passthroughCaps = self.bridge.queryPassthroughSupport()
                self.transport.spatialActive = self.bridge.isSpatialActive
            }
        }

        volume = Float(settings.volume)
        bridge.setVolume(volume)

        let url = URL(fileURLWithPath: path)
        mediaTitle = url.deletingPathExtension().lastPathComponent

        loadDisplaySettings(for: path)
        transport.onCropDetected = { [weak self] crop in
            Task { @MainActor in self?.setCrop(crop) }
        }

        let json = bridge.mediaInfoJSON()
        let parsed = TrackInfo.parseTracks(from: json)
        audioTracks = parsed.audio
        subtitleTracks = parsed.subtitle
        activeAudioStream = Int(bridge.activeAudioStream)
        activeSubtitleStream = Int(bridge.activeSubtitleStream)

        if !settings.preferredAudioLanguage.isEmpty {
            if let match = audioTracks.first(where: { $0.language == settings.preferredAudioLanguage }) {
                selectAudioTrack(streamIndex: match.streamIndex)
            }
        }

        if settings.autoSelectSubtitles && !settings.preferredSubtitleLanguage.isEmpty {
            if let match = subtitleTracks.first(where: { $0.language == settings.preferredSubtitleLanguage }) {
                selectSubtitleTrack(streamIndex: match.streamIndex)
            }
        } else if !settings.autoSelectSubtitles {
            disableSubtitles()
        }

        let interval: Int32 = transport.duration > 7_200_000_000 ? 30 : 10
        bridge.startSeekThumbnails(interval: interval)

        NowPlayingManager.shared.setup(onPlayPause: { [weak self] in
            self?.togglePlayPause()
        })
    }

    func play() {
        bridge.play()
        isPlaying = true
    }

    func pause() {
        bridge.pause()
        isPlaying = false
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to fraction: Double) {
        let target = Int64(fraction * Double(transport.duration))
        bridge.seek(to: target)
        transport.currentPosition = target
        currentPosition = target
    }

    func seekRelative(seconds: Double) {
        let offsetUs = Int64(seconds * 1_000_000)
        let target = max(0, min(transport.duration, transport.currentPosition + offsetUs))
        bridge.seek(to: target)
        transport.currentPosition = target
        currentPosition = target
    }

    func toggleMute() {
        if isMuted {
            isMuted = false
            bridge.setMuted(false)
            if volume == 0 {
                volume = preMuteVolume > 0 ? preMuteVolume : 1.0
                bridge.setVolume(volume)
            }
        } else {
            preMuteVolume = volume
            isMuted = true
            bridge.setMuted(true)
        }
    }

    func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        volume = clamped
        bridge.setVolume(clamped)
        if isMuted && clamped > 0 {
            isMuted = false
            bridge.setMuted(false)
        }
    }

    static let speedPresets: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]

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
        transport.currentPosition = 0
        playbackSpeed = 1.0
        transport.seekPreviewImage = nil
        transport.displaySettings = .default
        transport.onCropDetected = nil
        aspectRatioMode = .auto
        cropActive = false
        displaySettingsPath = nil
        NowPlayingManager.shared.clearNowPlaying()
    }

    // MARK: - Display-Synchronized Tick
    // Called by TimelineView(.animation) at the display's native refresh rate.
    // Writes ONLY to transport and plain properties — ZERO objectWillChange fires
    // (except for end-of-stream detection).

    func tick() {
        guard isPlaying else { return }

        // Skip while the user is scrubbing the timeline to avoid fighting
        if transport.isScrubbing { return }

        // End-of-stream detection (only @Published fire here)
        if bridge.state == PY_STATE_STOPPED.rawValue {
            isPlaying = false
            playbackEnded = true
            return
        }

        // Update transport and plain property — no objectWillChange
        transport.currentPosition = bridge.position
        currentPosition = transport.currentPosition
        transport.passthroughActive = bridge.isPassthroughActive
        transport.spatialActive = bridge.isSpatialActive

        let now = CACurrentMediaTime()

        // Subtitle: throttle to ~20Hz — subtitles change every 0.5-5s,
        // no need to cross the C bridge and alloc/free memory 120x/sec
        if now - lastSubtitleUpdate >= 0.05 {
            lastSubtitleUpdate = now
            transport.currentSubtitle = bridge.getSubtitle(at: transport.currentPosition)
        }

        // Throttle NowPlaying updates to ~1Hz
        if now - lastNowPlayingUpdate >= 1.0 {
            lastNowPlayingUpdate = now
            NowPlayingManager.shared.updateNowPlaying(
                title: mediaTitle,
                position: Double(transport.currentPosition) / 1_000_000.0,
                duration: Double(transport.duration) / 1_000_000.0,
                isPlaying: isPlaying
            )
        }
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

    func setSpatialMode(_ mode: Int) {
        bridge.setSpatialAudioMode(Int32(mode))
    }

    func setHeadTracking(_ enabled: Bool) {
        headTrackingEnabled = enabled
        bridge.setHeadTracking(enabled)
    }

    // MARK: - Display Settings (aspect ratio, crop, zoom, pan)

    private var displaySettingsPath: String?

    func setAspectRatioMode(_ mode: AspectRatioMode) {
        transport.displaySettings.aspectRatioMode = mode
        aspectRatioMode = mode
        // Reset pan when switching modes
        transport.displaySettings.panX = 0
        transport.displaySettings.panY = 0
        saveDisplaySettings()
    }

    func setCrop(_ crop: CropInsets) {
        transport.displaySettings.crop = crop
        cropActive = crop.isActive
        saveDisplaySettings()
    }

    func setZoom(_ zoom: Double) {
        transport.displaySettings.zoom = max(1.0, min(5.0, zoom))
        if transport.displaySettings.zoom <= 1.001 {
            transport.displaySettings.panX = 0
            transport.displaySettings.panY = 0
        }
    }

    func setPan(x: Double, y: Double) {
        transport.displaySettings.panX = max(-1, min(1, x))
        transport.displaySettings.panY = max(-1, min(1, y))
    }

    func adjustZoom(by delta: Double) {
        setZoom(transport.displaySettings.zoom + delta)
    }

    func resetDisplaySettings() {
        transport.displaySettings = .default
        aspectRatioMode = .auto
        cropActive = false
        saveDisplaySettings()
    }

    func detectBlackBars() {
        transport.pendingCropDetection = true
    }

    private func loadDisplaySettings(for path: String) {
        displaySettingsPath = path
        let settings = VideoDisplaySettingsStore.settings(for: path)
        transport.displaySettings = settings
        aspectRatioMode = settings.aspectRatioMode
        cropActive = settings.crop.isActive
    }

    private func saveDisplaySettings() {
        guard let path = displaySettingsPath else { return }
        VideoDisplaySettingsStore.save(path: path, settings: transport.displaySettings)
    }

    // MARK: - Timeline interaction (writes to transport, not @Published)

    func timelineHoverChanged(_ hovering: Bool) {
        hoverEndWork?.cancel()
        hoverEndWork = nil
        if hovering {
            transport.isHoveringTimeline = true
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.transport.isHoveringTimeline = false
                self.transport.seekPreviewImage = nil
                self.lastThumbIndex = -1
            }
            hoverEndWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    func timelineHoverMoved(fraction: Double) {
        transport.hoverFraction = max(0, min(1, fraction))
        updateSeekPreview(fraction: transport.hoverFraction)
    }

    func timelineDragStarted() {
        transport.isDraggingTimeline = true
    }

    func timelineDragChanged(fraction: Double) {
        let clamped = max(0, min(1, fraction))
        transport.hoverFraction = clamped
        updateSeekPreview(fraction: clamped)
        pendingSeekFraction = clamped
    }

    func timelineDragEnded() {
        if let fraction = pendingSeekFraction {
            seek(to: fraction)
        }
        pendingSeekFraction = nil
        transport.isDraggingTimeline = false
        transport.seekPreviewImage = nil
        lastThumbIndex = -1
    }

    private func updateSeekPreview(fraction: Double) {
        guard transport.duration > 0 else { return }
        let timestampUs = Int64(fraction * Double(transport.duration))

        let intervalSec = transport.duration > 7_200_000_000 ? 30 : 10
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
                self.transport.seekPreviewImage = image
            }
        }
    }

    func timeText(for fraction: Double) -> String {
        let us = Int64(fraction * Double(transport.duration))
        return transport.formatTime(us)
    }
}
