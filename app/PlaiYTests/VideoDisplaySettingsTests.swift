import XCTest
@testable import PlaiY

final class VideoDisplaySettingsTests: XCTestCase {

    // MARK: - AspectRatioMode.forcedDAR

    func testAutoHasNilDAR() {
        XCTAssertNil(AspectRatioMode.auto.forcedDAR)
    }

    func testFillHasNilDAR() {
        XCTAssertNil(AspectRatioMode.fill.forcedDAR)
    }

    func testStretchHasNilDAR() {
        XCTAssertNil(AspectRatioMode.stretch.forcedDAR)
    }

    func test16x9DAR() {
        let dar = AspectRatioMode.ratio16x9.forcedDAR
        XCTAssertNotNil(dar)
        XCTAssertEqual(dar!, 16.0 / 9.0, accuracy: 0.001)
    }

    func test4x3DAR() {
        let dar = AspectRatioMode.ratio4x3.forcedDAR
        XCTAssertNotNil(dar)
        XCTAssertEqual(dar!, 4.0 / 3.0, accuracy: 0.001)
    }

    func test21x9DAR() {
        let dar = AspectRatioMode.ratio21x9.forcedDAR
        XCTAssertNotNil(dar)
        XCTAssertEqual(dar!, 21.0 / 9.0, accuracy: 0.001)
    }

    func test235x1DAR() {
        let dar = AspectRatioMode.ratio235x1.forcedDAR
        XCTAssertNotNil(dar)
        XCTAssertEqual(dar!, 2.35, accuracy: 0.001)
    }

    // MARK: - CropInsets

    func testZeroCropIsNotActive() {
        XCTAssertFalse(CropInsets.zero.isActive)
    }

    func testSmallCropBelowThreshold() {
        let crop = CropInsets(top: 0.0005, bottom: 0, left: 0, right: 0)
        XCTAssertFalse(crop.isActive)
    }

    func testCropAboveThreshold() {
        let crop = CropInsets(top: 0.1, bottom: 0.1, left: 0, right: 0)
        XCTAssertTrue(crop.isActive)
    }

    func testCropTextureCoords() {
        let crop = CropInsets(top: 0.1, bottom: 0.15, left: 0.05, right: 0.1)
        XCTAssertEqual(crop.texOriginX, Float(0.05), accuracy: 0.001)
        XCTAssertEqual(crop.texOriginY, Float(0.1), accuracy: 0.001)
        XCTAssertEqual(crop.texScaleX, Float(0.85), accuracy: 0.001) // 1 - 0.05 - 0.1
        XCTAssertEqual(crop.texScaleY, Float(0.75), accuracy: 0.001) // 1 - 0.1 - 0.15
    }

    // MARK: - VideoDisplaySettings

    func testDefaultIsDefault() {
        XCTAssertTrue(VideoDisplaySettings.default.isDefault)
    }

    func testModifiedIsNotDefault() {
        var settings = VideoDisplaySettings()
        settings.zoom = 1.5
        XCTAssertFalse(settings.isDefault)
    }

    func testChangedAspectIsNotDefault() {
        var settings = VideoDisplaySettings()
        settings.aspectRatioMode = .fill
        XCTAssertFalse(settings.isDefault)
    }

    // MARK: - AspectRatioMode.displayName

    func testDisplayNames() {
        XCTAssertEqual(AspectRatioMode.auto.displayName, "Auto")
        XCTAssertEqual(AspectRatioMode.fill.displayName, "Fill")
        XCTAssertEqual(AspectRatioMode.ratio235x1.displayName, "2.35:1")
    }
}
