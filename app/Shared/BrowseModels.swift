import Foundation

enum BrowseDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case search
    case movies
    case shows
    case favorites
    case files
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .movies: "Movies"
        case .shows: "TV Shows"
        case .favorites: "Favorites"
        case .files: "Files"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .movies: "film"
        case .shows: "tv"
        case .favorites: "heart"
        case .files: "folder"
        case .settings: "gearshape"
        }
    }
}

enum HomeShelfKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case continueWatching
    case favorites
    case recentlyAdded
    case unwatchedMovies
    case unwatchedShows
    case pinned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continueWatching: "Continue Watching"
        case .favorites: "Favorites"
        case .recentlyAdded: "Recently Added"
        case .unwatchedMovies: "Unwatched Movies"
        case .unwatchedShows: "Unwatched TV Shows"
        case .pinned: "Pinned Sources & Folders"
        }
    }

    static let `default`: [HomeShelfKind] = [
        .continueWatching,
        .favorites,
        .recentlyAdded,
        .unwatchedMovies,
        .unwatchedShows,
        .pinned
    ]
}

struct HomeShelfConfiguration: Identifiable, Codable, Equatable, Hashable, Sendable {
    let kind: HomeShelfKind
    var isVisible: Bool

    var id: String { kind.rawValue }
}

enum PinnedDestinationKind: String, Codable, Hashable, Sendable {
    case source
    case folder
}

struct PinnedDestination: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let kind: PinnedDestinationKind
    let reference: String
    let title: String
    let subtitle: String?
    let sourceTypeRawValue: Int?
    let baseURI: String?
}

struct HomeLayoutState: Codable, Equatable, Hashable, Sendable {
    var shelves: [HomeShelfConfiguration]
    var pins: [PinnedDestination]

    static let `default` = HomeLayoutState(
        shelves: HomeShelfKind.default.map { HomeShelfConfiguration(kind: $0, isVisible: true) },
        pins: []
    )
}

struct FavoriteEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let kind: String
    let createdAt: Date
}

enum BrowseItemKind: String, Codable, Hashable, Sendable {
    case movie
    case show
    case episode
    case folder
    case source
}

enum BrowseItemSource: String, Codable, Hashable, Sendable {
    case local
    case plex
    case pin
}

struct BrowseArtwork: Hashable, Sendable {
    var posterPath: String?
    var posterURL: String?
    var backdropPath: String?
    var backdropURL: String?

    var hasArtwork: Bool {
        posterPath != nil || posterURL != nil || backdropPath != nil || backdropURL != nil
    }
}

struct BrowseItem: Identifiable, Hashable, Sendable {
    let id: String
    let kind: BrowseItemKind
    let source: BrowseItemSource
    let title: String
    let subtitle: String?
    let summary: String?
    let metadataLine: String?
    let badge: String?
    let artwork: BrowseArtwork
    let progress: Double?
    let isWatched: Bool
    let sourceName: String?
    let playbackItem: PlaybackItem?
    let filePath: String?
    let ratingKey: String?
    let plexKey: String?
    let sourceID: String?
    let sourceTypeRawValue: Int?
    let addedAt: Date?
    let year: Int?
    let seasonNumber: Int?
    let episodeNumber: Int?
}

struct BrowseShelf: Identifiable, Hashable, Sendable {
    let id: String
    let kind: HomeShelfKind
    let title: String
    let subtitle: String?
    let items: [BrowseItem]
}

struct BrowseDetailSection: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [BrowseItem]
}

struct BrowseDetailModel: Hashable, Sendable {
    let item: BrowseItem
    let heroTitle: String
    let heroSubtitle: String?
    let summary: String?
    let metadata: [String]
    let actions: [BrowseDetailAction]
    let sections: [BrowseDetailSection]
}

enum BrowseDetailAction: String, Hashable, Sendable {
    case play
    case resume
    case favorite
}
