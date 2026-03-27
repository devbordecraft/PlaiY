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
        #if os(tvOS)
        self == .smb || self == .plex
        #else
        self == .local || self == .smb || self == .plex
        #endif
    }
}

struct SourceConfig: Identifiable, Codable, Sendable {
    var id: String
    var displayName: String
    var type: SourceType
    var baseURI: String
    var username: String

    enum CodingKeys: String, CodingKey {
        case id = "source_id"
        case displayName = "display_name"
        case type
        case baseURI = "base_uri"
        case username
    }

    init(id: String = UUID().uuidString,
         displayName: String,
         type: SourceType,
         baseURI: String,
         username: String = "") {
        self.id = id
        self.displayName = displayName
        self.type = type
        self.baseURI = baseURI
        self.username = username
    }

    // Encode type as string ("plex") not integer (4) — the C++ bridge expects strings
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(type.jsonString, forKey: .type)
        try container.encode(baseURI, forKey: .baseURI)
        try container.encode(username, forKey: .username)
    }

    // Decode type from either string or integer for backwards compatibility
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        baseURI = try container.decode(String.self, forKey: .baseURI)
        username = try container.decode(String.self, forKey: .username)

        if let typeStr = try? container.decode(String.self, forKey: .type) {
            type = SourceType.allCases.first { $0.jsonString == typeStr } ?? .local
        } else if let rawVal = try? container.decode(Int.self, forKey: .type) {
            type = SourceType(rawValue: rawVal) ?? .local
        } else {
            type = .local
        }
    }
}

struct SourceEntry: Identifiable, Sendable {
    var id: String { uri }
    let name: String
    let uri: String
    let isDirectory: Bool
    let size: Int64

    var fileSizeText: String {
        guard size > 0 else { return "" }
        let gb = Double(size) / 1_073_741_824.0
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(size) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}
