import Foundation
import CoreGraphics
@testable import PlaiY

final class MockPlayerBridge: PlayerBridgeProtocol, @unchecked Sendable {
    // MARK: - Stub return values

    var openResult: Result<Void, BridgeOperationError> = .success(())
    var stubState: Int32 = 0
    var stubPosition: Int64 = 0
    var stubDuration: Int64 = 10_000_000 // 10 seconds
    var stubAudioTrackCount: Int32 = 0
    var stubSubtitleTrackCount: Int32 = 0
    var stubActiveAudioStream: Int32 = -1
    var stubActiveSubtitleStream: Int32 = -1
    var stubIsPassthroughActive = false
    var stubPassthroughCaps = PYPassthroughCapabilities()
    var stubSpatialAudioMode: Int32 = 0
    var stubIsSpatialActive = false
    var stubIsHeadTracking = false
    var stubIsMuted = false
    var stubVolume: Float = 1.0
    var stubPlaybackSpeed: Double = 1.0
    var stubPlaybackStats = PYPlaybackStats()
    var stubMediaInfoJSON = "{\"tracks\":[]}"
    var stubSeekThumbnailProgress: Int32 = 0
    var seekThumbnailHandler: ((Int64) -> CGImage?)?

    // MARK: - Call tracking

    var playCalled = false
    var pauseCalled = false
    var stopCalled = false
    var lastSeekTarget: Int64?
    var lastSelectedAudioTrack: Int32?
    var lastSelectedSubtitleTrack: Int32?
    var lastSetVolume: Float?
    var lastSetMuted: Bool?
    var lastSetSpeed: Double?
    var lastSetPassthrough: Bool?
    var lastSetSpatialMode: Int32?
    var lastSetHeadTracking: Bool?
    var startSeekThumbnailsCalled = false
    var cancelSeekThumbnailsCalled = false

    // MARK: - PlayerBridgeProtocol

    func open(path: String) -> Result<Void, BridgeOperationError> { openResult }
    func play() { playCalled = true }
    func pause() { pauseCalled = true }
    func seek(to microseconds: Int64) { lastSeekTarget = microseconds }
    func stop() { stopCalled = true }

    var state: Int32 { stubState }
    var position: Int64 { stubPosition }
    var duration: Int64 { stubDuration }

    var audioTrackCount: Int32 { stubAudioTrackCount }
    var subtitleTrackCount: Int32 { stubSubtitleTrackCount }

    func selectAudioTrack(_ index: Int32) { lastSelectedAudioTrack = index }
    func selectSubtitleTrack(_ index: Int32) { lastSelectedSubtitleTrack = index }

    var activeAudioStream: Int32 { stubActiveAudioStream }
    var activeSubtitleStream: Int32 { stubActiveSubtitleStream }

    func setHWDecodePref(_ pref: Int32) {}
    func setSubtitleFontScale(_ scale: Double) {}

    func setAudioPassthrough(_ enabled: Bool) { lastSetPassthrough = enabled }
    var isPassthroughActive: Bool { stubIsPassthroughActive }
    func queryPassthroughSupport() -> PYPassthroughCapabilities { stubPassthroughCaps }

    func setVolume(_ volume: Float) { lastSetVolume = volume; stubVolume = volume }
    var volume: Float { stubVolume }
    func setMuted(_ muted: Bool) { lastSetMuted = muted; stubIsMuted = muted }
    var isMuted: Bool { stubIsMuted }

    func setSpatialAudioMode(_ mode: Int32) { lastSetSpatialMode = mode }
    var spatialAudioMode: Int32 { stubSpatialAudioMode }
    var isSpatialActive: Bool { stubIsSpatialActive }
    func setHeadTracking(_ enabled: Bool) { lastSetHeadTracking = enabled }
    var isHeadTracking: Bool { stubIsHeadTracking }

    func setPlaybackSpeed(_ speed: Double) { lastSetSpeed = speed; stubPlaybackSpeed = speed }
    var playbackSpeed: Double { stubPlaybackSpeed }

    func getPlaybackStats() -> PYPlaybackStats { stubPlaybackStats }
    func mediaInfoJSON() -> String { stubMediaInfoJSON }

    func setDeviceChangeCallback(_ callback: @escaping () -> Void) {}
    func setStateCallback(_ callback: @escaping (Int32) -> Void) { lastStateCallback = callback }
    var lastStateCallback: ((Int32) -> Void)?

    func startSeekThumbnails(interval: Int32) { startSeekThumbnailsCalled = true }
    func cancelSeekThumbnails() { cancelSeekThumbnailsCalled = true }
    func seekThumbnail(at timestampUs: Int64) -> CGImage? {
        seekThumbnailHandler?(timestampUs)
    }
    var seekThumbnailProgress: Int32 { stubSeekThumbnailProgress }

    func getSubtitle(at timestamp: Int64) -> SubtitleData? { nil }
}
