import XCTest
@testable import PlaiY

final class TrackInfoTests: XCTestCase {

    // MARK: - parseTracks

    func testParseValidJSON() {
        let json = """
        {
            "tracks": [
                {
                    "stream_index": 1,
                    "type": 2,
                    "codec_name": "aac",
                    "language": "eng",
                    "title": "Stereo",
                    "is_default": true,
                    "sample_rate": 48000,
                    "channels": 2,
                    "subtitle_format": 0,
                    "codec_id": 86018,
                    "codec_profile": 1,
                    "bits_per_sample": 0
                },
                {
                    "stream_index": 2,
                    "type": 3,
                    "codec_name": "subrip",
                    "language": "eng",
                    "title": "English",
                    "is_default": true,
                    "sample_rate": 0,
                    "channels": 0,
                    "subtitle_format": 1,
                    "codec_id": 94210,
                    "codec_profile": -1,
                    "bits_per_sample": 0
                }
            ]
        }
        """
        let (audio, subtitle) = TrackInfo.parseTracks(from: json)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(subtitle.count, 1)
        XCTAssertEqual(audio[0].streamIndex, 1)
        XCTAssertEqual(audio[0].codecName, "aac")
        XCTAssertEqual(audio[0].channels, 2)
        XCTAssertEqual(subtitle[0].subtitleFormat, 1)
    }

    func testParseEmptyJSON() {
        let (audio, subtitle) = TrackInfo.parseTracks(from: "")
        XCTAssertTrue(audio.isEmpty)
        XCTAssertTrue(subtitle.isEmpty)
    }

    func testParseMalformedJSON() {
        let (audio, subtitle) = TrackInfo.parseTracks(from: "{invalid json")
        XCTAssertTrue(audio.isEmpty)
        XCTAssertTrue(subtitle.isEmpty)
    }

    func testParseFiltersVideoTracks() {
        let json = """
        {
            "tracks": [
                { "stream_index": 0, "type": 1, "codec_name": "h264", "language": "", "title": "", "is_default": true, "sample_rate": 0, "channels": 0, "subtitle_format": 0, "codec_id": 27, "codec_profile": -1, "bits_per_sample": 0 }
            ]
        }
        """
        let (audio, subtitle) = TrackInfo.parseTracks(from: json)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertTrue(subtitle.isEmpty)
    }

    // MARK: - displayName

    func testDisplayNameWithTitle() {
        let track = TrackInfo(streamIndex: 1, type: 2, codecName: "aac", language: "eng",
                              title: "Surround", isDefault: false, sampleRate: 48000,
                              channels: 6, subtitleFormat: 0, codecId: 0, codecProfile: -1,
                              bitsPerSample: 0)
        XCTAssertTrue(track.displayName.contains("Surround"))
        XCTAssertTrue(track.displayName.contains("5.1"))
    }

    func testDisplayNameWithLanguageFallback() {
        let track = TrackInfo(streamIndex: 1, type: 2, codecName: "aac", language: "jpn",
                              title: "", isDefault: false, sampleRate: 48000,
                              channels: 2, subtitleFormat: 0, codecId: 0, codecProfile: -1,
                              bitsPerSample: 0)
        XCTAssertTrue(track.displayName.contains("Japanese"))
    }

    func testDisplayNameFallsBackToTrackNumber() {
        let track = TrackInfo(streamIndex: 5, type: 2, codecName: "", language: "",
                              title: "", isDefault: false, sampleRate: 0,
                              channels: 0, subtitleFormat: 0, codecId: 0, codecProfile: -1,
                              bitsPerSample: 0)
        XCTAssertEqual(track.displayName, "Track 5")
    }

    // MARK: - Enhanced codec names

    func testAtmosCodecName() {
        let track = TrackInfo(streamIndex: 1, type: 2, codecName: "eac3", language: "eng",
                              title: "", isDefault: false, sampleRate: 48000,
                              channels: 8, subtitleFormat: 0, codecId: 0, codecProfile: 30,
                              bitsPerSample: 0)
        XCTAssertTrue(track.displayName.contains("Dolby Atmos"))
    }

    func testDTSHDMACodecName() {
        let track = TrackInfo(streamIndex: 1, type: 2, codecName: "dts", language: "eng",
                              title: "", isDefault: false, sampleRate: 48000,
                              channels: 6, subtitleFormat: 0, codecId: 0, codecProfile: 60,
                              bitsPerSample: 24)
        XCTAssertTrue(track.displayName.contains("DTS-HD MA"))
    }

    func testTrueHDCodecName() {
        let track = TrackInfo(streamIndex: 1, type: 2, codecName: "truehd", language: "eng",
                              title: "", isDefault: false, sampleRate: 48000,
                              channels: 8, subtitleFormat: 0, codecId: 0, codecProfile: -1,
                              bitsPerSample: 24)
        XCTAssertTrue(track.displayName.contains("TrueHD"))
    }

    // MARK: - Channel labels

    func testMonoLabel() {
        let track = TrackInfo(streamIndex: 1, type: 2, codecName: "aac", language: "",
                              title: "Commentary", isDefault: false, sampleRate: 48000,
                              channels: 1, subtitleFormat: 0, codecId: 0, codecProfile: -1,
                              bitsPerSample: 0)
        XCTAssertTrue(track.displayName.contains("Mono"))
    }

    func test71Label() {
        let track = TrackInfo(streamIndex: 1, type: 2, codecName: "aac", language: "",
                              title: "Main", isDefault: false, sampleRate: 48000,
                              channels: 8, subtitleFormat: 0, codecId: 0, codecProfile: -1,
                              bitsPerSample: 0)
        XCTAssertTrue(track.displayName.contains("7.1"))
    }

    // MARK: - Subtitle format

    func testSubtitleFormatSRT() {
        let track = TrackInfo(streamIndex: 2, type: 3, codecName: "subrip", language: "eng",
                              title: "", isDefault: false, sampleRate: 0,
                              channels: 0, subtitleFormat: 1, codecId: 0, codecProfile: -1,
                              bitsPerSample: 0)
        XCTAssertTrue(track.displayName.contains("SRT"))
    }

    func testSubtitleFormatPGS() {
        let track = TrackInfo(streamIndex: 3, type: 3, codecName: "hdmv_pgs_subtitle", language: "fra",
                              title: "", isDefault: false, sampleRate: 0,
                              channels: 0, subtitleFormat: 3, codecId: 0, codecProfile: -1,
                              bitsPerSample: 0)
        XCTAssertTrue(track.displayName.contains("PGS"))
        XCTAssertTrue(track.displayName.contains("French"))
    }

    // MARK: - languageName

    func testLanguageNameEnglish() {
        XCTAssertEqual(TrackInfo.languageName(for: "eng"), "English")
        XCTAssertEqual(TrackInfo.languageName(for: "en"), "English")
    }

    func testLanguageNameJapanese() {
        XCTAssertEqual(TrackInfo.languageName(for: "jpn"), "Japanese")
    }

    func testLanguageNameUnknownCode() {
        // Unknown codes should be uppercased
        XCTAssertEqual(TrackInfo.languageName(for: "xyz"), "XYZ")
    }
}
