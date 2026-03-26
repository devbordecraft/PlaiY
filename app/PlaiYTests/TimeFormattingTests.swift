import XCTest
@testable import PlaiY

final class TimeFormattingTests: XCTestCase {

    // MARK: - display()

    func testDisplayZero() {
        XCTAssertEqual(TimeFormatting.display(0), "0:00")
    }

    func testDisplayOneSecond() {
        XCTAssertEqual(TimeFormatting.display(1_000_000), "0:01")
    }

    func testDisplayOneMinuteOneSecond() {
        XCTAssertEqual(TimeFormatting.display(61_000_000), "1:01")
    }

    func testDisplayOneHourOneMinuteOneSecond() {
        XCTAssertEqual(TimeFormatting.display(3_661_000_000), "1:01:01")
    }

    func testDisplayTenMinutes() {
        XCTAssertEqual(TimeFormatting.display(600_000_000), "10:00")
    }

    func testDisplayTwoHours() {
        XCTAssertEqual(TimeFormatting.display(7_200_000_000), "2:00:00")
    }

    func testDisplaySubSecondTruncates() {
        // 1.9 seconds should display as 0:01 (truncation)
        XCTAssertEqual(TimeFormatting.display(1_900_000), "0:01")
    }

    func testDisplayNegativeValue() {
        // Negative microseconds — verify no crash
        let result = TimeFormatting.display(-1_000_000)
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - debug()

    func testDebugFormat() {
        let result = TimeFormatting.debug(61_500_000)
        // Should contain "1:" prefix and millisecond precision
        XCTAssertTrue(result.hasPrefix("1:"))
        XCTAssertTrue(result.contains("."))
    }

    func testDebugZero() {
        let result = TimeFormatting.debug(0)
        XCTAssertTrue(result.contains("0:"))
    }
}
