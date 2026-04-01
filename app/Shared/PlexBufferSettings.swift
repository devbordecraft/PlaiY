import Foundation

enum PlexBufferMode: Int, CaseIterable, Sendable {
    case off = 0
    case memory = 1
    case disk = 2

    var title: String {
        switch self {
        case .off: "Off"
        case .memory: "Memory"
        case .disk: "Disk"
        }
    }

    var statusText: String {
        switch self {
        case .off: "Opening Plex media..."
        case .memory: "Buffering Plex media in memory..."
        case .disk: "Buffering Plex media on disk..."
        }
    }
}

enum PlexBufferProfile: Int, CaseIterable, Sendable {
    case fast = 0
    case balanced = 1
    case conservative = 2

    var title: String {
        switch self {
        case .fast: "Fast Start"
        case .balanced: "Balanced"
        case .conservative: "Conservative"
        }
    }
}
