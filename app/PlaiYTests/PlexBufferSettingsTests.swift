import XCTest
@testable import PlaiY

final class PlexBufferSettingsTests: XCTestCase {
    func testPlexBufferModeRawValues() {
        XCTAssertEqual(PlexBufferMode.off.rawValue, 0)
        XCTAssertEqual(PlexBufferMode.memory.rawValue, 1)
        XCTAssertEqual(PlexBufferMode.disk.rawValue, 2)
    }

    func testPlexBufferProfileRawValues() {
        XCTAssertEqual(PlexBufferProfile.fast.rawValue, 0)
        XCTAssertEqual(PlexBufferProfile.balanced.rawValue, 1)
        XCTAssertEqual(PlexBufferProfile.conservative.rawValue, 2)
    }
}
