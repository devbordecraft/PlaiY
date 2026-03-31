import XCTest
@testable import PlaiY

final class ResumeStoreTests: XCTestCase {

    private let testPath = "/test/resume_store_test_\(UUID().uuidString).mkv"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suite = "com.plaiy.tests.resume.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        ResumeStore.clear(path: testPath, defaults: defaults)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Save and retrieve

    func testSaveAndRetrieve() {
        // Position at 50% of a 2-minute file
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 120_000_000, defaults: defaults)
        let pos = ResumeStore.position(for: testPath, defaults: defaults)
        XCTAssertEqual(pos, 60_000_000)
    }

    // MARK: - Minimum position guard

    func testPositionBelowMinimumNotSaved() {
        // 20s into a 2-minute file — below 30s minimum
        ResumeStore.save(path: testPath, positionUs: 20_000_000, durationUs: 120_000_000, defaults: defaults)
        XCTAssertNil(ResumeStore.position(for: testPath, defaults: defaults))
    }

    func testPositionAtExactMinimumNotSaved() {
        // Exactly 30s — not > 30s, so not saved
        ResumeStore.save(path: testPath, positionUs: 30_000_000, durationUs: 120_000_000, defaults: defaults)
        XCTAssertNil(ResumeStore.position(for: testPath, defaults: defaults))
    }

    func testPositionJustAboveMinimumIsSaved() {
        // 31s — above 30s minimum
        ResumeStore.save(path: testPath, positionUs: 31_000_000, durationUs: 120_000_000, defaults: defaults)
        XCTAssertEqual(ResumeStore.position(for: testPath, defaults: defaults), 31_000_000)
    }

    // MARK: - Maximum fraction guard

    func testPositionPast95PercentNotSaved() {
        // 96% of a 100s file = 96s
        ResumeStore.save(path: testPath, positionUs: 96_000_000, durationUs: 100_000_000, defaults: defaults)
        XCTAssertNil(ResumeStore.position(for: testPath, defaults: defaults))
    }

    func testPositionAt94PercentIsSaved() {
        // 94% of a 100s file = 94s (above 30s minimum, below 95%)
        ResumeStore.save(path: testPath, positionUs: 94_000_000, durationUs: 100_000_000, defaults: defaults)
        XCTAssertEqual(ResumeStore.position(for: testPath, defaults: defaults), 94_000_000)
    }

    // MARK: - Duration guard

    func testZeroDurationDoesNotSave() {
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 0, defaults: defaults)
        XCTAssertNil(ResumeStore.position(for: testPath, defaults: defaults))
    }

    // MARK: - Clear

    func testClear() {
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 120_000_000, defaults: defaults)
        XCTAssertNotNil(ResumeStore.position(for: testPath, defaults: defaults))

        ResumeStore.clear(path: testPath, defaults: defaults)
        XCTAssertNil(ResumeStore.position(for: testPath, defaults: defaults))
    }

    // MARK: - Overwrite clears when invalid

    func testSaveValidThenInvalidClearsPosition() {
        // Save a valid position first
        ResumeStore.save(path: testPath, positionUs: 60_000_000, durationUs: 120_000_000, defaults: defaults)
        XCTAssertNotNil(ResumeStore.position(for: testPath, defaults: defaults))

        // Now save an invalid position (< 30s) — should clear
        ResumeStore.save(path: testPath, positionUs: 5_000_000, durationUs: 120_000_000, defaults: defaults)
        XCTAssertNil(ResumeStore.position(for: testPath, defaults: defaults))
    }
}
