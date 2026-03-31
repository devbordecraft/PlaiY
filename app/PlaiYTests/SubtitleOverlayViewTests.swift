import XCTest
import CoreGraphics
@testable import PlaiY

final class SubtitleOverlayViewTests: XCTestCase {
    func testSubtitleRegionFrameScalesWithViewport() {
        let view = SubtitleOverlayView(
            subtitle: nil,
            isHDRContent: false,
            videoWidth: 1920,
            videoHeight: 1080
        )
        let viewport = view.subtitleViewport(in: CGSize(width: 960, height: 540))
        let region = SubtitleBitmapRegion(
            data: Data(repeating: 255, count: 4 * 10 * 10),
            width: 480,
            height: 270,
            x: 960,
            y: 540
        )

        let frame = view.subtitleRegionFrame(region, in: viewport)

        XCTAssertEqual(frame.origin.x, 480, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 270, accuracy: 0.001)
        XCTAssertEqual(frame.size.width, 240, accuracy: 0.001)
        XCTAssertEqual(frame.size.height, 135, accuracy: 0.001)
    }

    func testMultipleSubtitleRegionsProduceDistinctFrames() {
        let view = SubtitleOverlayView(
            subtitle: nil,
            isHDRContent: false,
            videoWidth: 1920,
            videoHeight: 1080
        )
        let viewport = view.subtitleViewport(in: CGSize(width: 1920, height: 1080))
        let leftRegion = SubtitleBitmapRegion(
            data: Data(repeating: 255, count: 4 * 4 * 4),
            width: 100,
            height: 50,
            x: 100,
            y: 900
        )
        let rightRegion = SubtitleBitmapRegion(
            data: Data(repeating: 255, count: 4 * 4 * 4),
            width: 100,
            height: 50,
            x: 1400,
            y: 900
        )

        let leftFrame = view.subtitleRegionFrame(leftRegion, in: viewport)
        let rightFrame = view.subtitleRegionFrame(rightRegion, in: viewport)

        XCTAssertLessThan(leftFrame.midX, rightFrame.midX)
        XCTAssertEqual(leftFrame.size.width, rightFrame.size.width, accuracy: 0.001)
        XCTAssertEqual(leftFrame.size.height, rightFrame.size.height, accuracy: 0.001)
    }

    func testSubtitleRegionFrameFallsBackToRawCoordinatesWithoutVideoSize() {
        let view = SubtitleOverlayView(
            subtitle: nil,
            isHDRContent: false,
            videoWidth: 0,
            videoHeight: 0
        )
        let region = SubtitleBitmapRegion(
            data: Data(repeating: 255, count: 4),
            width: 200,
            height: 80,
            x: 30,
            y: 40
        )

        let frame = view.subtitleRegionFrame(region, in: .zero)

        XCTAssertEqual(frame.origin.x, 30, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, 40, accuracy: 0.001)
        XCTAssertEqual(frame.size.width, 200, accuracy: 0.001)
        XCTAssertEqual(frame.size.height, 80, accuracy: 0.001)
    }
}
