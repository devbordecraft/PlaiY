import XCTest
@testable import PlaiY

@MainActor
final class NowPlayingManagerTests: XCTestCase {
    private var manager: NowPlayingManager!

    override func setUp() {
        super.setUp()
        manager = NowPlayingManager()
    }

    override func tearDown() {
        manager.clearNowPlaying()
        manager = nil
        super.tearDown()
    }

    func testExplicitPlayUsesPlayHandlerOnly() {
        var playCount = 0
        var pauseCount = 0
        var toggleCount = 0

        manager.setup(
            onPlay: { playCount += 1 },
            onPause: { pauseCount += 1 },
            onTogglePlayPause: { toggleCount += 1 }
        )

        XCTAssertEqual(manager.handlePlayCommand(), .success)
        XCTAssertEqual(playCount, 1)
        XCTAssertEqual(pauseCount, 0)
        XCTAssertEqual(toggleCount, 0)
    }

    func testExplicitPauseUsesPauseHandlerOnly() {
        var playCount = 0
        var pauseCount = 0
        var toggleCount = 0

        manager.setup(
            onPlay: { playCount += 1 },
            onPause: { pauseCount += 1 },
            onTogglePlayPause: { toggleCount += 1 }
        )

        XCTAssertEqual(manager.handlePauseCommand(), .success)
        XCTAssertEqual(playCount, 0)
        XCTAssertEqual(pauseCount, 1)
        XCTAssertEqual(toggleCount, 0)
    }

    func testToggleUsesToggleHandlerOnly() {
        var playCount = 0
        var pauseCount = 0
        var toggleCount = 0

        manager.setup(
            onPlay: { playCount += 1 },
            onPause: { pauseCount += 1 },
            onTogglePlayPause: { toggleCount += 1 }
        )

        XCTAssertEqual(manager.handleTogglePlayPauseCommand(), .success)
        XCTAssertEqual(playCount, 0)
        XCTAssertEqual(pauseCount, 0)
        XCTAssertEqual(toggleCount, 1)
    }
}
