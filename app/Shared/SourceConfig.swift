import Foundation

enum SourceType: Int, Codable, CaseIterable, Sendable {
    case local = 0
    case smb = 1
    case nfs = 2
    case http = 3
    case plex = 4

    var displayName: String {
        switch self {
        case .local: "Local Folder"
        case .smb: "SMB / Windows Share"
        case .nfs: "NFS"
        case .http: "HTTP / HLS"
        case .plex: "Plex"
        }
    }

    var systemImage: String {
        switch self {
        case .local: "folder"
        case .smb: "externaldrive.connected.to.line.below"
        case .nfs: "externaldrive"
        case .http: "globe"
        case .plex: "play.rectangle"
        }
    }

    var jsonString: String {
        switch self {
        case .local: "local"
        case .smb: "smb"
        case .nfs: "nfs"
        case .http: "http"
        case .plex: "plex"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .local:
            #if os(tvOS)
            false
            #else
            true
            #endif
        case .http, .nfs, .smb:
            SourceManagerBridge.isSourceTypeSupported(self)
        case .plex:
            true
        }
    }
}

struct SourceConfig: Identifiable, Codable, Sendable {
    var id: String
    var displayName: String
    var type: SourceType
    var baseURI: String
    var username: String
    var authToken: String?

    enum CodingKeys: String, CodingKey {
        case id = "source_id"
        case displayName = "display_name"
        case type
        case baseURI = "base_uri"
        case username
        case authToken = "auth_token"
    }

    init(id: String = UUID().uuidString,
         displayName: String,
         type: SourceType,
         baseURI: String,
         username: String = "",
         authToken: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.baseURI = baseURI
        self.username = username
        self.authToken = authToken?.isEmpty == true ? nil : authToken
    }

    // Encode type as string ("plex") not integer (4) — the C++ bridge expects strings
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(type.jsonString, forKey: .type)
        try container.encode(baseURI, forKey: .baseURI)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(authToken?.isEmpty == true ? nil : authToken,
                                      forKey: .authToken)
    }

    // Decode type from either string or integer for backwards compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        baseURI = try container.decode(String.self, forKey: .baseURI)
        username = try container.decode(String.self, forKey: .username)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        if authToken?.isEmpty == true {
            authToken = nil
        }

        if let typeStr = try? container.decode(String.self, forKey: .type) {
            type = SourceType.allCases.first { $0.jsonString == typeStr } ?? .local
        } else if let rawVal = try? container.decode(Int.self, forKey: .type) {
            type = SourceType(rawValue: rawVal) ?? .local
        } else {
            type = .local
        }
    }
}

struct PlexEntryMetadata: Codable, Sendable, Equatable {
    let ratingKey: String
    let key: String
    let type: String
    let durationMs: Int64
    let viewOffsetMs: Int64
    let viewCount: Int
    let leafCount: Int
    let viewedLeafCount: Int
    let thumbURL: String
    let artURL: String
    let skipChildren: Bool
    let skipParent: Bool

    enum CodingKeys: String, CodingKey {
        case ratingKey = "rating_key"
        case key
        case type
        case durationMs = "duration_ms"
        case viewOffsetMs = "view_offset_ms"
        case viewCount = "view_count"
        case leafCount = "leaf_count"
        case viewedLeafCount = "viewed_leaf_count"
        case thumbURL = "thumb_url"
        case artURL = "art_url"
        case skipChildren = "skip_children"
        case skipParent = "skip_parent"
    }

    var isWatched: Bool { viewCount > 0 }

    var progressFraction: Double? {
        guard durationMs > 0, viewOffsetMs > 0 else { return nil }
        return min(max(Double(viewOffsetMs) / Double(durationMs), 0), 1)
    }

    var hierarchyProgressFraction: Double? {
        guard leafCount > 0 else { return nil }
        return min(max(Double(viewedLeafCount) / Double(leafCount), 0), 1)
    }
}

struct PlexPlaybackContext: Sendable, Equatable, Hashable {
    let sourceId: String
    let serverBaseURL: String
    let authToken: String
    let ratingKey: String
    let key: String
    let type: String
    let initialViewOffsetMs: Int64
    let initialViewCount: Int
}

struct PlexMarker: Sendable, Equatable {
    let id: String
    let type: String
    let startTimeOffsetMs: Int64
    let endTimeOffsetMs: Int64
}

struct PlaybackItem: Identifiable, Sendable, Equatable, Hashable {
    let path: String
    let displayName: String
    let resumeKey: String
    let plexContext: PlexPlaybackContext?

    var id: String { resumeKey }
    var isPlex: Bool { plexContext != nil }

    var initialResumePositionUs: Int64? {
        guard let plexContext, plexContext.initialViewOffsetMs > 0 else { return nil }
        return plexContext.initialViewOffsetMs * 1_000
    }

    static func local(path: String, displayName: String? = nil) -> PlaybackItem {
        PlaybackItem(
            path: path,
            displayName: displayName ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            resumeKey: path,
            plexContext: nil
        )
    }

    func startingFromBeginning() -> PlaybackItem {
        guard let plexContext else { return self }
        return PlaybackItem(
            path: path,
            displayName: displayName,
            resumeKey: resumeKey,
            plexContext: PlexPlaybackContext(
                sourceId: plexContext.sourceId,
                serverBaseURL: plexContext.serverBaseURL,
                authToken: plexContext.authToken,
                ratingKey: plexContext.ratingKey,
                key: plexContext.key,
                type: plexContext.type,
                initialViewOffsetMs: 0,
                initialViewCount: plexContext.initialViewCount
            )
        )
    }
}

struct SourceEntry: Identifiable, Sendable {
    var id: String { uri }
    let name: String
    let uri: String
    let isDirectory: Bool
    let size: Int64
    let plex: PlexEntryMetadata?

    init(name: String,
         uri: String,
         isDirectory: Bool,
         size: Int64,
         plex: PlexEntryMetadata? = nil) {
        self.name = name
        self.uri = uri
        self.isDirectory = isDirectory
        self.size = size
        self.plex = plex
    }

    var fileSizeText: String {
        guard size > 0 else { return "" }
        let gb = Double(size) / 1_073_741_824.0
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(size) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    var isWatched: Bool { plex?.isWatched ?? false }
    var progressFraction: Double? { plex?.progressFraction ?? plex?.hierarchyProgressFraction }
}
