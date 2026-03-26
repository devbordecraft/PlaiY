import XCTest
@testable import PlaiY

final class ResumeStoreTests: XCTestCase {

    private let testPath = "/test/resume_store_test_\(UUID().uuidString).mkv"

    override func tearDown() {
        super.tearDown()
        ResumeStore.clear(path: testPath)
    }

    // MARK: - Save and retrieve

    func testSaveAndRetrieve() {
        // Position at 50% of a 2-minute file
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 120_000_000)
        let pos = ResumeStore.position(for: testPath)
        XCTAssertEqual(pos, 60_000_000)
    }

    // MARK: - Minimum position guard

    func testPositionBelowMinimumNotSaved() {
        // 20s into a 2-minute file — below 30s minimum
        ResumeStore.save(path: testPath, positionUs: 20_000_000, durationUs: 120_000_000)
        XCTAssertNil(ResumeStore.position(for: testPath))
    }

    func testPositionAtExactMinimumNotSaved() {
        // Exactly 30s — not > 30s, so not saved
        ResumeStore.save(path: testPath, positionUs: 30_000_000, durationUs: 120_000_000)
        XCTAssertNil(ResumeStore.position(for: testPath))
    }

    func testPositionJustAboveMinimumIsSaved() {
        // 31s — above 30s minimum
        ResumeStore.save(path: testPath, positionUs: 31_000_000, durationUs: 120_000_000)
        XCTAssertEqual(ResumeStore.position(for: testPath), 31_000_000)
    }

    // MARK: - Maximum fraction guard

    func testPositionPast95PercentNotSaved() {
        // 96% of a 100s file = 96s
        ResumeStore.save(path: testPath, positionUs: 96_000_000, durationUs: 100_000_000)
        XCTAssertNil(ResumeStore.position(for: testPath))
    }

    func testPositionAt94PercentIsSaved() {
        // 94% of a 100s file = 94s (above 30s minimum, below 95%)
        ResumeStore.save(path: testPath, positionUs: 94_000_000, durationUs: 100_000_000)
        XCTAssertEqual(ResumeStore.position(for: testPath), 94_000_000)
    }

    // MARK: - Duration guard

    func testZeroDurationDoesNotSave() {
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 0)
        XCTAssertNil(ResumeStore.position(for: testPath))
    }

    // MARK: - Clear

    func testClear() {
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 120_000_000)
        XCTAssertNotNil(ResumeStore.position(for: testPath))

        ResumeStore.clear(path: testPath)
        XCTAssertNil(ResumeStore.position(for: testPath))
    }

    // MARK: - Overwrite clears when invalid

    func testSaveValidThenInvalidClearsPosition() {
        // Save a valid position first
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 120_000_000)
        XCTAssertNotNil(ResumeStore.position(for: testPath))

        // Now save an invalid position (< 30s) — should clear
        ResumeStore.save(path: testPath, positionUs: 5_000_000, durationUs: 120_000_000)
        XCTAssertNil(ResumeStore.position(for: testPath))
    }
}
