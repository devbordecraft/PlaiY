import SwiftUI

class AppSettings: ObservableObject {
    // MARK: - General
    @AppStorage("resumePlayback") var resumePlayback: Bool = true
    @AppStorage("autoplayOnOpen") var autoplayOnOpen: Bool = true

    // MARK: - Video
    // 0 = Auto, 1 = Force HW, 2 = Force SW
    @AppStorage("hwDecodePref") var hwDecodePref: Int = 0

    // MARK: - Audio
    @AppStorage("preferredAudioLanguage") var preferredAudioLanguage: String = ""
    @AppStorage("audioPassthrough") var audioPassthrough: Bool = false
    @AppStorage("volume") var volume: Double = 1.0
    // 0 = Auto, 1 = Off, 2 = Force Spatial
    @AppStorage("spatialAudioMode") var spatialAudioMode: Int = 0
    @AppStorage("headTrackingEnabled") var headTrackingEnabled: Bool = false

    // MARK: - Subtitles
    @AppStorage("preferredSubtitleLanguage") var preferredSubtitleLanguage: String = ""
    @AppStorage("autoSelectSubtitles") var autoSelectSubtitles: Bool = true
    // 0=Small, 1=Medium, 2=Large, 3=Very Large
    @AppStorage("srtFontSize") var srtFontSize: Int = 1
    // 0=White, 1=Yellow
    @AppStorage("srtTextColor") var srtTextColor: Int = 0
    // 0=Semi-transparent, 1=None, 2=Opaque
    @AppStorage("srtBackgroundStyle") var srtBackgroundStyle: Int = 0
    @AppStorage("assFontScale") var assFontScale: Double = 1.0

    // MARK: - Computed helpers

    var srtFont: Font {
        switch srtFontSize {
        case 0: return .body
        case 2: return .title2
        case 3: return .title
        default: return .title3
        }
    }

    var srtColor: Color {
        srtTextColor == 1 ? .yellow : .white
    }

    var srtBgColor: Color {
        switch srtBackgroundStyle {
        case 1: return .clear
        case 2: return .black.opacity(0.9)
        default: return .black.opacity(0.6)
        }
    }
}
