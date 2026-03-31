import XCTest
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

    // MARK: - Play / Pause

    func testPlay() {
        vm.play()
        XCTAssertTrue(vm.isPlaying)
        XCTAssertTrue(mock.playCalled)
    }

    func testPause() {
        vm.play()
        vm.pause()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertTrue(mock.pauseCalled)
    }

    func testTogglePlayPause() {
        XCTAssertFalse(vm.isPlaying)
        vm.togglePlayPause()
        XCTAssertTrue(vm.isPlaying)
        vm.togglePlayPause()
        XCTAssertFalse(vm.isPlaying)
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
        vm.play()
        vm.stop()
        XCTAssertTrue(mock.stopCalled)
        XCTAssertTrue(mock.cancelSeekThumbnailsCalled)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.playbackSpeed, 1.0)
    }
}
