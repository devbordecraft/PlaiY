import Foundation
import CoreGraphics

/// Protocol abstracting PlayerBridge for testability.
/// PlayerViewModel depends on this protocol instead of the concrete class.
protocol PlayerBridgeProtocol: AnyObject, Sendable {
    // Lifecycle
    func open(path: String) -> Result<Void, BridgeOperationError>
    func lastErrorMessage() -> String
    func play()
    func pause()
    func seek(to microseconds: Int64)
    func stop()

    // State
    var state: Int32 { get }
    var position: Int64 { get }
    var duration: Int64 { get }
    func getTransportSnapshot() -> PlayerTransportSnapshot

    // Track management
    var audioTrackCount: Int32 { get }
    var subtitleTrackCount: Int32 { get }
    func selectAudioTrack(_ index: Int32)
    func selectSubtitleTrack(_ index: Int32)
    var activeAudioStream: Int32 { get }
    var activeSubtitleStream: Int32 { get }

    // Configuration
    func setHWDecodePref(_ pref: Int32)
    func setSubtitleFontScale(_ scale: Double)
    func setRemoteSourceKind(_ kind: Int32)
    func setRemoteBufferMode(_ mode: Int32)
    func setRemoteBufferProfile(_ profile: Int32)

    // Audio
    func setAudioPassthrough(_ enabled: Bool)
    var isPassthroughActive: Bool { get }
    func queryPassthroughSupport() -> PYPassthroughCapabilities
    func setVolume(_ volume: Float)
    var volume: Float { get }
    func setMuted(_ muted: Bool)
    var isMuted: Bool { get }

    // Spatial audio
    func setSpatialAudioMode(_ mode: Int32)
    var spatialAudioMode: Int32 { get }
    var isSpatialActive: Bool { get }
    func setHeadTracking(_ enabled: Bool)
    var isHeadTracking: Bool { get }

    // Playback speed
    func setPlaybackSpeed(_ speed: Double)
    var playbackSpeed: Double { get }

    // Metadata
    func getPlaybackStats() -> PYPlaybackStats
    func mediaInfoJSON() -> String

    // Callbacks
    func setDeviceChangeCallback(_ callback: @escaping () -> Void)
    func setStateCallback(_ callback: @escaping (Int32) -> Void)

    // Seek thumbnails
    func startSeekThumbnails(interval: Int32)
    func cancelSeekThumbnails()
    func seekThumbnail(at timestampUs: Int64) -> CGImage?
    var seekThumbnailProgress: Int32 { get }

    // Subtitles
    func getSubtitleFrame(at timestamp: Int64) -> ResolvedSubtitle?
}

extension PlayerBridge: PlayerBridgeProtocol {}
