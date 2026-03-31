import XCTest
@testable import PlaiY

final class VideoDisplaySettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let path = "/tmp/video-settings-test.mkv"

    override func setUp() {
        super.setUp()
        suiteName = "com.plaiy.tests.videodisplay.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSaveAndLoadUsesInjectedDefaultsStore() {
        var settings = VideoDisplaySettings()
        settings.aspectRatioMode = .fill
        settings.zoom = 1.4

        VideoDisplaySettingsStore.save(path: path, settings: settings, defaults: defaults)
        let loaded = VideoDisplaySettingsStore.settings(for: path, defaults: defaults)

        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(VideoDisplaySettingsStore.settings(for: path), .default)
    }

    func testClearUsesInjectedDefaultsStore() {
        var settings = VideoDisplaySettings()
        settings.zoom = 1.3

        VideoDisplaySettingsStore.save(path: path, settings: settings, defaults: defaults)
        XCTAssertNotEqual(VideoDisplaySettingsStore.settings(for: path, defaults: defaults), .default)

        VideoDisplaySettingsStore.clear(path: path, defaults: defaults)
        XCTAssertEqual(VideoDisplaySettingsStore.settings(for: path, defaults: defaults), .default)
    }
}
