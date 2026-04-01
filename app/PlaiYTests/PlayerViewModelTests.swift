import XCTest
import CoreGraphics
import QuartzCore
@testable import PlaiY

@MainActor
final class PlayerViewModelTests: XCTestCase {

    private var mock: MockPlayerBridge!
    private var vm: PlayerViewModel!

    override func setUp() {
        super.setUp()
        mock = MockPlayerBridge()
        vm = PlayerViewModel(bridge: mock)
    }

    private func waitUntil(timeout: TimeInterval = 1.0,
                           pollIntervalNs: UInt64 = 10_000_000,
                           _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
        XCTFail("Timed out waiting for condition")
    }

    // MARK: - Play / Pause

    func testPlay() {
        vm.play()
        XCTAssertTrue(mock.playCalled)
        XCTAssertFalse(vm.isPlaying)
    }

    func testPlayWhilePreparingDefersBridgePlayUntilReady() async {
        let settings = AppSettings()
        mock.stubState = Int32(PY_STATE_OPENING.rawValue)
        mock.stubMediaInfoJSON = #"{"tracks":[]}"#

        vm.open(item: .local(path: "/tmp/test-video.mkv"), settings: settings)
        vm.play()

        XCTAssertFalse(mock.playCalled)

        mock.emitState(Int32(PY_STATE_READY.rawValue))
        await waitUntil { self.mock.playCalled }

        XCTAssertTrue(mock.playCalled)
    }

    func testOpenRunsOffMainActor() async {
        let settings = AppSettings()
        mock.openDelay = 0.2

        let start = CACurrentMediaTime()
        vm.open(item: .local(path: "/tmp/test-video.mkv"), settings: settings)
        let elapsed = CACurrentMediaTime() - start

        XCTAssertLessThan(elapsed, 0.05)
        XCTAssertTrue(vm.isPreparingPlayback)
        await waitUntil { self.mock.openCallCount == 1 }
    }

    func testStateCallbackMarksPlaybackAsPlaying() {
        mock.emitState(Int32(PY_STATE_PLAYING.rawValue))
        XCTAssertTrue(vm.isPlaying)
        XCTAssertTrue(vm.transport.isPlaying)
    }

    func testPause() {
        mock.emitState(Int32(PY_STATE_PLAYING.rawValue))
        vm.pause()
        XCTAssertTrue(mock.pauseCalled)
        XCTAssertTrue(vm.isPlaying)
        mock.emitState(Int32(PY_STATE_PAUSED.rawValue))
        XCTAssertFalse(vm.isPlaying)
        XCTAssertFalse(vm.transport.isPlaying)
    }

    func testTogglePlayPause() {
        XCTAssertFalse(vm.isPlaying)
        mock.stubState = Int32(PY_STATE_READY.rawValue)
        vm.togglePlayPause()
        XCTAssertTrue(mock.playCalled)
        mock.emitState(Int32(PY_STATE_PLAYING.rawValue))
        XCTAssertTrue(vm.isPlaying)

        mock.playCalled = false
        vm.togglePlayPause()
        XCTAssertTrue(mock.pauseCalled)
    }

    func testStoppedStateMarksPlaybackEnded() {
        mock.emitState(Int32(PY_STATE_STOPPED.rawValue))
        XCTAssertTrue(vm.playbackEnded)
        XCTAssertFalse(vm.isPlaying)
    }

    func testReadyStateClearsPlaybackEnded() {
        mock.emitState(Int32(PY_STATE_STOPPED.rawValue))
        XCTAssertTrue(vm.playbackEnded)

        mock.emitState(Int32(PY_STATE_READY.rawValue))
        XCTAssertFalse(vm.playbackEnded)
        XCTAssertFalse(vm.isPlaying)
    }

    func testSeekThumbnailIntervalSelectionPrefersDensePreviewsForShortMedia() {
        XCTAssertEqual(PlayerViewModel.seekThumbnailIntervalSeconds(for: 600_000_000), 1)
        XCTAssertEqual(PlayerViewModel.seekThumbnailIntervalSeconds(for: 1_800_000_000), 1)
        XCTAssertEqual(PlayerViewModel.seekThumbnailIntervalSeconds(for: 3_600_000_000), 2)
        XCTAssertEqual(PlayerViewModel.seekThumbnailIntervalSeconds(for: 10_800_000_000), 5)
        XCTAssertEqual(PlayerViewModel.seekThumbnailIntervalSeconds(for: 21_600_000_000), 10)
    }

    // MARK: - Seek

    func testSeekToFraction() {
        mock.stubDuration = 10_000_000 // 10 seconds
        vm.transport.duration = 10_000_000

        vm.seek(to: 0.5) // 50% = 5 seconds
        XCTAssertEqual(mock.lastSeekTarget, 5_000_000)
        XCTAssertEqual(vm.transport.currentPosition, 5_000_000)
    }

    func testSeekRelativeForward() {
        mock.stubDuration = 10_000_000
        vm.transport.duration = 10_000_000
        vm.transport.currentPosition = 2_000_000 // at 2s

        vm.seekRelative(seconds: 3.0) // forward 3s -> 5s
        XCTAssertEqual(mock.lastSeekTarget, 5_000_000)
    }

    func testSeekRelativeClampsToZero() {
        mock.stubDuration = 10_000_000
        vm.transport.duration = 10_000_000
        vm.transport.currentPosition = 1_000_000

        vm.seekRelative(seconds: -5.0) // back 5s from 1s -> clamp to 0
        XCTAssertEqual(mock.lastSeekTarget, 0)
    }

    func testSeekRelativeClampsToDuration() {
        mock.stubDuration = 10_000_000
        vm.transport.duration = 10_000_000
        vm.transport.currentPosition = 9_000_000

        vm.seekRelative(seconds: 5.0) // forward 5s from 9s -> clamp to 10s
        XCTAssertEqual(mock.lastSeekTarget, 10_000_000)
    }

    // MARK: - Volume

    func testSetVolume() {
        vm.setVolume(0.75)
        XCTAssertEqual(vm.volume, 0.75, accuracy: 0.001)
        XCTAssertEqual(mock.lastSetVolume!, 0.75, accuracy: 0.001)
    }

    func testSetVolumeClamps() {
        vm.setVolume(1.5)
        XCTAssertEqual(vm.volume, 1.0, accuracy: 0.001)

        vm.setVolume(-0.5)
        XCTAssertEqual(vm.volume, 0.0, accuracy: 0.001)
    }

    func testSetVolumeUnmutes() {
        // Mute first
        vm.isMuted = true
        mock.stubIsMuted = true

        vm.setVolume(0.5)
        XCTAssertFalse(vm.isMuted)
        XCTAssertEqual(mock.lastSetMuted, false)
    }

    // MARK: - Mute

    func testToggleMuteOn() {
        vm.volume = 0.8
        vm.toggleMute()
        XCTAssertTrue(vm.isMuted)
        XCTAssertEqual(mock.lastSetMuted, true)
    }

    func testToggleMuteOffRestoresVolume() {
        vm.volume = 0.7
        vm.toggleMute() // mute
        vm.toggleMute() // unmute
        XCTAssertFalse(vm.isMuted)
        XCTAssertEqual(mock.lastSetMuted, false)
    }

    func testToggleMuteOffWithZeroVolume() {
        vm.volume = 0.6
        vm.toggleMute() // mute (saves preMuteVolume = 0.6)

        // Simulate volume at 0 while muted
        vm.volume = 0
        vm.toggleMute() // unmute -> volume should restore to 0.6

        XCTAssertFalse(vm.isMuted)
        XCTAssertEqual(vm.volume, 0.6, accuracy: 0.01)
    }

    // MARK: - Speed

    func testSetPlaybackSpeed() {
        vm.setPlaybackSpeed(2.0)
        XCTAssertEqual(vm.playbackSpeed, 2.0)
        XCTAssertEqual(mock.lastSetSpeed, 2.0)
    }

    func testSetPlaybackSpeedWhilePausedKeepsPlaybackPaused() {
        vm.isPlaying = false
        vm.transport.isPlaying = false

        vm.setPlaybackSpeed(1.5)

        XCTAssertEqual(vm.playbackSpeed, 1.5)
        XCTAssertEqual(mock.lastSetSpeed, 1.5)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertFalse(vm.transport.isPlaying)
    }

    func testSetSpatialMode() {
        vm.setSpatialMode(2)
        XCTAssertEqual(mock.lastSetSpatialMode, 2)
    }

    func testCycleSpeedUp() {
        vm.playbackSpeed = 1.0
        vm.cycleSpeedUp()
        XCTAssertEqual(vm.playbackSpeed, 1.25)
    }

    func testCycleSpeedUpAtMax() {
        vm.playbackSpeed = 4.0
        vm.cycleSpeedUp()
        XCTAssertEqual(vm.playbackSpeed, 4.0) // stays at max
    }

    func testCycleSpeedDown() {
        vm.playbackSpeed = 1.0
        vm.cycleSpeedDown()
        XCTAssertEqual(vm.playbackSpeed, 0.75)
    }

    func testCycleSpeedDownAtMin() {
        vm.playbackSpeed = 0.25
        vm.cycleSpeedDown()
        XCTAssertEqual(vm.playbackSpeed, 0.25) // stays at min
    }

    // MARK: - Track selection

    func testSelectAudioTrack() {
        vm.selectAudioTrack(streamIndex: 3)
        XCTAssertEqual(mock.lastSelectedAudioTrack, 3)
        XCTAssertEqual(vm.activeAudioStream, 3)
    }

    func testDisableSubtitles() {
        vm.disableSubtitles()
        XCTAssertEqual(mock.lastSelectedSubtitleTrack, -1)
        XCTAssertEqual(vm.activeSubtitleStream, -1)
    }

    // MARK: - Stop

    func testStop() {
        mock.emitState(Int32(PY_STATE_PLAYING.rawValue))
        vm.stop()
        XCTAssertTrue(mock.stopCalled)
        XCTAssertTrue(mock.cancelSeekThumbnailsCalled)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.playbackSpeed, 1.0)
    }

    func testOpenFailureSurfacesBridgeMessage() async {
        mock.openResult = .failure(
            BridgeOperationError(
                operation: "open",
                code: Int32(PY_ERROR_DECODER.rawValue),
                message: "Failed to open media stream"
            )
        )
        let settings = AppSettings()

        vm.open(item: .local(path: "/tmp/test-video.mkv"), settings: settings)
        await waitUntil { self.vm.openError != nil }

        XCTAssertEqual(vm.openError, "Failed to open media stream")
        XCTAssertEqual(vm.mediaTitle, "")
        XCTAssertTrue(vm.audioTracks.isEmpty)
        XCTAssertTrue(vm.subtitleTracks.isEmpty)
    }

    func testOpenPlexConfiguresBufferingAndFinishesOnReady() async {
        let settings = AppSettings()
        settings.plexBufferModeValue = PlexBufferMode.memory.rawValue
        settings.plexBufferProfileValue = PlexBufferProfile.conservative.rawValue
        mock.stubState = Int32(PY_STATE_OPENING.rawValue)
        mock.stubDuration = 123_000_000
        mock.stubMediaInfoJSON = """
        {"tracks":[{"type":1,"width":1920,"height":1080,"sar_num":1,"sar_den":1}]}
        """

        let item = PlaybackItem(
            path: "http://plex.example/library/parts/1/file?token=abc",
            displayName: "Big Movie",
            resumeKey: "plex:test:1",
            plexContext: PlexPlaybackContext(
                sourceId: "plex-source",
                serverBaseURL: "http://plex.example",
                ratingKey: "1",
                key: "/library/metadata/1",
                type: "movie",
                initialViewOffsetMs: 0,
                initialViewCount: 0
            )
        )

        vm.open(item: item, settings: settings)

        XCTAssertTrue(vm.isPreparingPlayback)
        XCTAssertEqual(mock.lastRemoteSourceKind, Int32(PY_REMOTE_SOURCE_PLEX.rawValue))
        XCTAssertEqual(mock.lastRemoteBufferMode, Int32(PY_REMOTE_BUFFER_MEMORY.rawValue))
        XCTAssertEqual(mock.lastRemoteBufferProfile, Int32(PY_REMOTE_BUFFER_CONSERVATIVE.rawValue))

        mock.emitState(Int32(PY_STATE_READY.rawValue))
        await waitUntil {
            self.vm.duration == 123_000_000 &&
            self.vm.transport.videoWidth == 1920 &&
            self.vm.transport.videoHeight == 1080
        }

        XCTAssertFalse(vm.isPreparingPlayback)
        XCTAssertEqual(vm.mediaTitle, "Big Movie")
        XCTAssertEqual(vm.duration, 123_000_000)
        XCTAssertEqual(vm.transport.videoWidth, 1920)
        XCTAssertEqual(vm.transport.videoHeight, 1080)
    }

    func testAsyncOpenFailureUsesLastErrorMessage() async {
        let settings = AppSettings()
        mock.stubState = Int32(PY_STATE_OPENING.rawValue)

        vm.open(item: .local(path: "/tmp/test-video.mkv"), settings: settings)

        mock.stubLastErrorMessage = "Network timeout"
        mock.emitState(Int32(PY_STATE_IDLE.rawValue))
        await waitUntil { self.vm.openError != nil }

        XCTAssertEqual(vm.openError, "Network timeout")
        XCTAssertFalse(vm.isPreparingPlayback)
    }

    func testTimelineLabelsUseLivePlaybackWhenInactive() {
        vm.transport.duration = 10_000_000
        vm.transport.currentPosition = 2_000_000

        XCTAssertEqual(vm.timelineElapsedText(), "0:02")
        XCTAssertEqual(vm.timelineRemainingText(), "-0:08")
    }

    func testTimelineLabelsUseHoverPositionWhilePreviewing() {
        vm.transport.duration = 10_000_000
        vm.transport.currentPosition = 2_000_000

        vm.timelineHoverChanged(true)
        vm.timelineHoverMoved(fraction: 0.7)

        XCTAssertEqual(vm.timelineElapsedText(), "0:07")
        XCTAssertEqual(vm.timelineRemainingText(), "-0:03")
    }

    func testTimelineHoverEndReturnsLabelsToLivePlaybackImmediately() {
        vm.transport.duration = 10_000_000
        vm.transport.currentPosition = 2_000_000

        vm.timelineHoverChanged(true)
        vm.timelineHoverMoved(fraction: 0.7)
        vm.timelineHoverChanged(false)

        XCTAssertEqual(vm.timelineElapsedText(), "0:02")
        XCTAssertEqual(vm.timelineRemainingText(), "-0:08")
    }

    func testTimelineDragEndCommitsSeekAndClearsPreviewState() {
        vm.transport.duration = 10_000_000
        vm.transport.currentPosition = 2_000_000
        vm.transport.seekPreviewImage = Self.makeTestImage()

        vm.timelineDragStarted()
        vm.timelineDragChanged(fraction: 0.8)
        vm.timelineDragEnded()

        XCTAssertEqual(mock.lastSeekTarget, 8_000_000)
        XCTAssertEqual(vm.transport.currentPosition, 8_000_000)
        XCTAssertFalse(vm.transport.isDraggingTimeline)
        XCTAssertNil(vm.transport.seekPreviewImage)
        XCTAssertEqual(vm.timelineElapsedText(), "0:08")
        XCTAssertEqual(vm.timelineRemainingText(), "-0:02")
    }

    func testTimelineHoverEndCancelsPendingThumbnail() async {
        mock.seekThumbnailHandler = { _ in
            Thread.sleep(forTimeInterval: 0.075)
            return Self.makeTestImage()
        }
        vm.transport.duration = 10_000_000

        vm.timelineHoverChanged(true)
        vm.timelineHoverMoved(fraction: 0.5)
        vm.timelineHoverChanged(false)

        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(vm.transport.seekPreviewImage)
    }

    func testTimelineHoverRetriesThumbnailWhenGenerationProgresses() async {
        mock.stubSeekThumbnailProgress = 40
        mock.seekThumbnailHandler = { [weak mock] _ in
            guard let mock else { return nil }
            if mock.seekThumbnailCallCount == 1 {
                return nil
            }
            mock.stubSeekThumbnailProgress = 100
            return Self.makeTestImage()
        }
        vm.transport.duration = 10_000_000

        vm.timelineHoverChanged(true)
        vm.timelineHoverMoved(fraction: 0.5)

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(vm.transport.seekPreviewImage)
        XCTAssertGreaterThanOrEqual(mock.seekThumbnailCallCount, 2)
    }

    private static func makeTestImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let data: [UInt8] = [255, 255, 255, 255]
        guard let provider = CGDataProvider(data: Data(data) as CFData) else { return nil }
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
