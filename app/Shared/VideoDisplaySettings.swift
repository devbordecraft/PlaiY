import Foundation

enum AspectRatioMode: Int, Codable, CaseIterable, Identifiable {
    case auto = 0
    case fill
    case stretch
    case ratio16x9
    case ratio4x3
    case ratio21x9
    case ratio235x1

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .fill: return "Fill"
        case .stretch: return "Stretch"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .ratio21x9: return "21:9"
        case .ratio235x1: return "2.35:1"
        }
    }

    /// Returns the forced display aspect ratio, or nil for modes that derive it from the video.
    var forcedDAR: Double? {
        switch self {
        case .auto, .fill, .stretch: return nil
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3: return 4.0 / 3.0
        case .ratio21x9: return 21.0 / 9.0
        case .ratio235x1: return 2.35
        }
    }
}

struct CropInsets: Codable, Equatable {
    var top: Double = 0     // Normalized [0, 0.5)
    var bottom: Double = 0
    var left: Double = 0
    var right: Double = 0

    static let zero = CropInsets()

    var isActive: Bool {
        top > 0.001 || bottom > 0.001 || left > 0.001 || right > 0.001
    }

    var texOriginX: Float { Float(left) }
    var texOriginY: Float { Float(top) }
    var texScaleX: Float { Float(1.0 - left - right) }
    var texScaleY: Float { Float(1.0 - top - bottom) }
}

struct VideoDisplaySettings: Codable, Equatable {
    var aspectRatioMode: AspectRatioMode = .auto
    var crop: CropInsets = .zero
    var zoom: Double = 1.0
    var panX: Double = 0.0
    var panY: Double = 0.0

    static let `default` = VideoDisplaySettings()

    var isDefault: Bool { self == .default }
}
