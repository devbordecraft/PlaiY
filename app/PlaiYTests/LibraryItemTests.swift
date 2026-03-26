import XCTest
@testable import PlaiY

final class LibraryItemTests: XCTestCase {

    private func makeItem(
        width: Int = 1920, height: Int = 1080,
        hdrType: Int = 0, fileSize: Int64 = 0,
        durationUs: Int64 = 0
    ) -> PlaiY.LibraryItem {
        PlaiY.LibraryItem(
            filePath: "/test/video.mkv",
            title: "Test",
            durationUs: durationUs,
            videoWidth: width,
            videoHeight: height,
            videoCodec: "hevc",
            audioCodec: "aac",
            hdrType: hdrType,
            fileSize: fileSize
        )
    }

    // MARK: - resolutionText

    func testResolution4K() {
        XCTAssertEqual(makeItem(width: 3840, height: 2160).resolutionText, "4K")
    }

    func testResolution1080p() {
        XCTAssertEqual(makeItem(width: 1920, height: 1080).resolutionText, "1080p")
    }

    func testResolution720p() {
        XCTAssertEqual(makeItem(width: 1280, height: 720).resolutionText, "720p")
    }

    func testResolutionCustom() {
        XCTAssertEqual(makeItem(width: 640, height: 480).resolutionText, "640x480")
    }

    func testResolutionZero() {
        XCTAssertEqual(makeItem(width: 0, height: 0).resolutionText, "")
    }

    // MARK: - hdrText

    func testHdrSDR() {
        XCTAssertEqual(makeItem(hdrType: 0).hdrText, "")
    }

    func testHdrHDR10() {
        XCTAssertEqual(makeItem(hdrType: 1).hdrText, "HDR10")
    }

    func testHdrHDR10Plus() {
        XCTAssertEqual(makeItem(hdrType: 2).hdrText, "HDR10+")
    }

    func testHdrHLG() {
        XCTAssertEqual(makeItem(hdrType: 3).hdrText, "HLG")
    }

    func testHdrDV() {
        XCTAssertEqual(makeItem(hdrType: 4).hdrText, "DV")
    }

    // MARK: - fileSizeText

    func testFileSizeGB() {
        // 2.5 GB
        let size: Int64 = 2_684_354_560
        XCTAssertEqual(makeItem(fileSize: size).fileSizeText, "2.5 GB")
    }

    func testFileSizeMB() {
        // 500 MB
        let size: Int64 = 524_288_000
        XCTAssertEqual(makeItem(fileSize: size).fileSizeText, "500 MB")
    }

    func testFileSizeExactlyOneGB() {
        let size: Int64 = 1_073_741_824
        XCTAssertEqual(makeItem(fileSize: size).fileSizeText, "1.0 GB")
    }

    // MARK: - durationText

    func testDurationText() {
        // 1 hour 30 minutes
        let item = makeItem(durationUs: 5_400_000_000)
        XCTAssertEqual(item.durationText, "1:30:00")
    }

    // MARK: - JSON decoding

    func testJSONDecoding() throws {
        let json = """
        {
            "file_path": "/test/movie.mkv",
            "title": "Movie",
            "duration_us": 7200000000,
            "video_width": 3840,
            "video_height": 2160,
            "video_codec": "hevc",
            "audio_codec": "eac3",
            "hdr_type": 4,
            "file_size": 5368709120
        }
        """
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(PlaiY.LibraryItem.self, from: data)
        XCTAssertEqual(item.filePath, "/test/movie.mkv")
        XCTAssertEqual(item.title, "Movie")
        XCTAssertEqual(item.videoWidth, 3840)
        XCTAssertEqual(item.hdrType, 4)
        XCTAssertEqual(item.resolutionText, "4K")
        XCTAssertEqual(item.hdrText, "DV")
    }
}
