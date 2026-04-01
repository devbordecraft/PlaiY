import Foundation

struct PlexCatalogSnapshot: Sendable {
    let movies: [BrowseItem]
    let shows: [BrowseItem]
    let continueWatching: [BrowseItem]
    let recentlyAdded: [BrowseItem]
    let itemsByID: [String: BrowseItem]

    static let empty = PlexCatalogSnapshot(
        movies: [],
        shows: [],
        continueWatching: [],
        recentlyAdded: [],
        itemsByID: [:]
    )
}

struct PlexDetailPayload: Sendable {
    let refreshedItem: BrowseItem?
    let summary: String?
    let metadata: [String]
    let sections: [BrowseDetailSection]
}

actor PlexCatalogClient {
    private struct PlexContext: Sendable {
        let config: SourceConfig
        let token: String
        let clientIdentifier: String
    }

    private struct PlexSection: Sendable {
        let key: String
        let type: String
    }

    private let session: URLSession

    init(session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()) {
        self.session = session
    }

    func fetchSnapshot(sources: [SourceConfig]) async -> PlexCatalogSnapshot {
        let contexts = sources.compactMap(Self.context(for:))
        guard !contexts.isEmpty else {
            return PlexCatalogSnapshot(
                movies: [],
                shows: [],
                continueWatching: [],
                recentlyAdded: [],
                itemsByID: [:]
            )
        }

        var movies: [BrowseItem] = []
        var shows: [BrowseItem] = []
        var continueWatching: [BrowseItem] = []
        var itemsByID: [String: BrowseItem] = [:]

        await withTaskGroup(of: [BrowseItem].self) { group in
            for context in contexts {
                group.addTask { [weak self] in
                    guard let self else { return [] }
                    return await self.fetchCatalogItems(for: context)
                }
            }

            for await catalog in group {
                for item in catalog {
                    itemsByID[item.id] = item
                    switch item.kind {
                    case .movie:
                        movies.append(item)
                    case .show:
                        shows.append(item)
                    case .episode:
                        if item.progress != nil && !item.isWatched {
                            continueWatching.append(item)
                        }
                    case .folder, .source:
                        break
                    }

                    if item.kind == .movie, item.progress != nil, !item.isWatched {
                        continueWatching.append(item)
                    }
                }
            }
        }

        let recentlyAdded = (movies + shows)
            .sorted(by: Self.recencySort)

        return PlexCatalogSnapshot(
            movies: movies.sorted(by: Self.titleSort),
            shows: shows.sorted(by: Self.titleSort),
            continueWatching: continueWatching.sorted(by: Self.recencySort),
            recentlyAdded: recentlyAdded,
            itemsByID: itemsByID
        )
    }

    func search(query: String, sources: [SourceConfig], fallbackItems: [BrowseItem]) async -> [BrowseItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let contexts = sources.compactMap(Self.context(for:))
        guard !contexts.isEmpty else { return [] }

        var results: [BrowseItem] = []
        for context in contexts {
            if let live = try? await liveSearch(query: trimmed, context: context), !live.isEmpty {
                results.append(contentsOf: live)
            }
        }

        if !results.isEmpty {
            return deduplicated(items: results).sorted(by: Self.titleSort)
        }

        return fallbackItems
            .filter { item in
                item.source == .plex &&
                item.title.localizedCaseInsensitiveContains(trimmed)
            }
            .sorted(by: Self.titleSort)
    }

    func fetchDetail(for item: BrowseItem) async -> PlexDetailPayload? {
        guard item.source == .plex,
              let sourceID = item.sourceID,
              let source = SourceConfigStoreResolver.shared.sourceConfig(sourceID: sourceID),
              let context = Self.context(for: source),
              let plexKey = item.plexKey ?? item.ratingKey.map({ "/library/metadata/\($0)" }) else {
            return nil
        }

        guard let itemResponse = try? await requestJSON(path: plexKey, context: context) else {
            return nil
        }
        let meta = firstMetadata(from: itemResponse)
        let refreshedItem = meta.map { parseBrowseItem(meta: $0, context: context) }
        let summary = meta?["summary"] as? String
        var metadata = [item.sourceName].compactMap { $0 }

        if let year = meta?["year"] as? Int {
            metadata.append(String(year))
        }
        if let durationMs = int64(meta?["duration"]) {
            metadata.append(TimeFormatting.display(durationMs * 1_000))
        }
        if let type = meta?["type"] as? String {
            metadata.append(type.capitalized)
        }

        var sections: [BrowseDetailSection] = []
        switch item.kind {
        case .show:
            if let ratingKey = item.ratingKey,
               let childrenResponse = try? await requestJSON(path: "/library/metadata/\(ratingKey)/grandchildren", context: context) {
                let episodes = metadataArray(from: childrenResponse).map { parseBrowseItem(meta: $0, context: context) }
                let grouped = Dictionary(grouping: episodes) { $0.seasonNumber ?? 0 }
                sections = grouped.keys.sorted().map { season in
                    BrowseDetailSection(
                        id: "season-\(season)",
                        title: season > 0 ? "Season \(season)" : "Episodes",
                        items: grouped[season]?.sorted(by: Self.episodeSort) ?? []
                    )
                }
            }

        case .episode:
            if item.sourceID != nil,
               item.ratingKey != nil {
                if let parentKey = string(meta?["grandparentRatingKey"]),
                   let siblingsResponse = try? await requestJSON(path: "/library/metadata/\(parentKey)/grandchildren", context: context) {
                    let siblings = metadataArray(from: siblingsResponse).map { parseBrowseItem(meta: $0, context: context) }
                    let season = item.seasonNumber ?? 0
                    let filtered = siblings
                        .filter { ($0.seasonNumber ?? 0) == season }
                        .sorted(by: Self.episodeSort)
                    if !filtered.isEmpty {
                        sections = [
                            BrowseDetailSection(
                                id: "season-\(season)",
                                title: season > 0 ? "Season \(season)" : "Episodes",
                                items: filtered
                            )
                        ]
                    }
                }
            }

        case .movie, .folder, .source:
            break
        }

        return PlexDetailPayload(
            refreshedItem: refreshedItem,
            summary: summary,
            metadata: metadata,
            sections: sections
        )
    }

    private func fetchCatalogItems(for context: PlexContext) async -> [BrowseItem] {
        guard let sectionsResponse = try? await requestJSON(path: "/library/sections", context: context) else {
            return []
        }

        let sections = directoryArray(from: sectionsResponse).compactMap { directory -> PlexSection? in
            guard let key = string(directory["key"]),
                  let type = string(directory["type"]),
                  type == "movie" || type == "show" else {
                return nil
            }
            return PlexSection(key: key, type: type)
        }

        var items: [BrowseItem] = []
        for section in sections {
            items.append(contentsOf: await fetchSectionItems(section: section, context: context))
        }

        return items
    }

    private func fetchSectionItems(section: PlexSection, context: PlexContext) async -> [BrowseItem] {
        let pageSize = 120
        var start = 0
        var items: [BrowseItem] = []

        while true {
            let path = "/library/sections/\(section.key)/all?X-Plex-Container-Start=\(start)&X-Plex-Container-Size=\(pageSize)"
            guard let response = try? await requestJSON(path: path, context: context) else { break }

            let metadata = metadataArray(from: response)
            guard !metadata.isEmpty else { break }

            items.append(contentsOf: metadata.map { parseBrowseItem(meta: $0, context: context) })

            let fetchedCount = metadata.count
            let totalSize = int(mediaContainer(from: response)?["totalSize"])

            if fetchedCount < pageSize {
                break
            }

            start += fetchedCount
            if let totalSize, start >= totalSize {
                break
            }
        }

        return items
    }

    private func liveSearch(query: String, context: PlexContext) async throws -> [BrowseItem] {
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let path = "/hubs/search?query=\(encodedQuery)&limit=20&includeCollections=0&includeExternalMedia=0"
        let json = try await requestJSON(path: path, context: context)

        var items: [BrowseItem] = []
        if let mediaContainer = json["MediaContainer"] as? [String: Any],
           let hubs = mediaContainer["Hub"] as? [[String: Any]] {
            for hub in hubs {
                guard let metadata = hub["Metadata"] as? [[String: Any]] else { continue }
                items.append(contentsOf: metadata.compactMap { parseBrowseItem(meta: $0, context: context) })
            }
        }

        return deduplicated(items: items)
    }

    private func requestJSON(path: String, context: PlexContext) async throws -> [String: Any] {
        let request = try makeRequest(path: path, context: context)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        return json
    }

    private func makeRequest(path: String, context: PlexContext) throws -> URLRequest {
        let trimmedBase = trimTrailingSlashes(context.config.baseURI)
        let urlString: String
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            urlString = path
        } else {
            let separator = path.hasPrefix("/") ? "" : "/"
            urlString = trimmedBase + separator + path
        }

        guard var components = URLComponents(string: urlString) else {
            throw URLError(.badURL)
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: context.token))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(context.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("PlaiY", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("1.0", forHTTPHeaderField: "X-Plex-Version")
        request.setValue(Self.platformName, forHTTPHeaderField: "X-Plex-Platform")
        return request
    }

    private func parseBrowseItem(meta: [String: Any], context: PlexContext) -> BrowseItem {
        let type = string(meta["type"]) ?? "movie"
        let ratingKey = string(meta["ratingKey"])
        let detailKey = normalizeDetailKey(from: meta)
        let title: String
        let subtitle: String?

        switch type {
        case "show":
            title = string(meta["title"]) ?? "Untitled"
            let leafCount = int(meta["leafCount"])
            subtitle = leafCount.map { $0 == 1 ? "1 episode" : "\($0) episodes" }
        case "episode":
            let showTitle = string(meta["grandparentTitle"]) ?? "Show"
            let season = int(meta["parentIndex"]) ?? 0
            let episode = int(meta["index"]) ?? 0
            title = string(meta["title"])?.nonEmpty ?? "Episode \(episode)"
            subtitle = "\(showTitle) • S\(season)E\(episode)"
        default:
            let rawTitle = string(meta["title"]) ?? "Untitled"
            if let year = int(meta["year"]) {
                title = "\(rawTitle) (\(year))"
            } else {
                title = rawTitle
            }
            subtitle = durationText(meta["duration"])
        }

        let partID = firstPartID(from: meta)
        let playbackItem: PlaybackItem?
        if type == "movie" || type == "episode", let partID {
            let path = playableURL(partID: partID, context: context)
            playbackItem = PlaybackItem(
                path: path,
                displayName: title,
                resumeKey: "plex:\(context.config.id):\(ratingKey ?? detailKey ?? title)",
                plexContext: PlexPlaybackContext(
                    sourceId: context.config.id,
                    serverBaseURL: context.config.baseURI,
                    ratingKey: ratingKey ?? "",
                    key: detailKey ?? "",
                    type: type,
                    initialViewOffsetMs: int64(meta["viewOffset"]) ?? 0,
                    initialViewCount: int(meta["viewCount"]) ?? 0
                )
            )
        } else {
            playbackItem = nil
        }

        let addedAt = addedDate(meta["addedAt"])
        let artwork = BrowseArtwork(
            posterPath: nil,
            posterURL: assetURL(string(meta["thumb"]), context: context),
            backdropPath: nil,
            backdropURL: assetURL(string(meta["art"]), context: context)
        )

        let viewCount = int(meta["viewCount"]) ?? 0
        let leafCount = int(meta["leafCount"])
        let viewedLeafCount = int(meta["viewedLeafCount"])
        let progress: Double?
        let watched: Bool

        if type == "show" {
            progress = hierarchyProgressFraction(leafCount: leafCount, viewedLeafCount: viewedLeafCount)
            if let leafCount, leafCount > 0 {
                watched = (viewedLeafCount ?? 0) >= leafCount
            } else {
                watched = viewCount > 0
            }
        } else {
            progress = progressFraction(durationMs: int64(meta["duration"]), offsetMs: int64(meta["viewOffset"]))
            watched = viewCount > 0
        }
        let source = context.config.displayName

        return BrowseItem(
            id: "plex:\(context.config.id):\(ratingKey ?? detailKey ?? title)",
            kind: browseKind(type),
            source: .plex,
            title: title,
            subtitle: subtitle,
            summary: string(meta["summary"]),
            metadataLine: metadataLine(meta: meta),
            badge: badge(meta: meta),
            artwork: artwork,
            progress: progress,
            isWatched: watched,
            sourceName: source,
            playbackItem: playbackItem,
            filePath: nil,
            ratingKey: ratingKey,
            plexKey: detailKey,
            sourceID: context.config.id,
            sourceTypeRawValue: SourceType.plex.rawValue,
            addedAt: addedAt,
            year: int(meta["year"]),
            seasonNumber: int(meta["parentIndex"]),
            episodeNumber: int(meta["index"])
        )
    }

    private func normalizeDetailKey(from meta: [String: Any]) -> String? {
        let ratingKey = string(meta["ratingKey"])
        if let key = string(meta["key"]), !key.isEmpty {
            if key.hasSuffix("/children") {
                return String(key.dropLast("/children".count))
            }
            if key.hasSuffix("/grandchildren") {
                return String(key.dropLast("/grandchildren".count))
            }
            return key
        }
        if let ratingKey {
            return "/library/metadata/\(ratingKey)"
        }
        return nil
    }

    private func playableURL(partID: String, context: PlexContext) -> String {
        let base = trimTrailingSlashes(context.config.baseURI)
        let query = "X-Plex-Token=\(context.token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? context.token)"
        return "\(base)/library/parts/\(partID)/file?\(query)"
    }

    private func assetURL(_ path: String?, context: PlexContext) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let base = trimTrailingSlashes(context.config.baseURI)
        let encodedToken = context.token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? context.token
        return "\(base)\(path)?X-Plex-Token=\(encodedToken)"
    }

    private func firstPartID(from meta: [String: Any]) -> String? {
        guard let media = (meta["Media"] as? [[String: Any]])?.first,
              let part = (media["Part"] as? [[String: Any]])?.first else {
            return nil
        }

        if let number = int64(part["id"]) {
            return String(number)
        }
        return string(part["id"])
    }

    private func metadataArray(from json: [String: Any]) -> [[String: Any]] {
        let mediaContainer = json["MediaContainer"] as? [String: Any]
        return mediaContainer?["Metadata"] as? [[String: Any]] ?? []
    }

    private func firstMetadata(from json: [String: Any]) -> [String: Any]? {
        metadataArray(from: json).first
    }

    private func mediaContainer(from json: [String: Any]) -> [String: Any]? {
        json["MediaContainer"] as? [String: Any]
    }

    private func directoryArray(from json: [String: Any]) -> [[String: Any]] {
        let mediaContainer = json["MediaContainer"] as? [String: Any]
        return mediaContainer?["Directory"] as? [[String: Any]] ?? []
    }

    private func metadataLine(meta: [String: Any]) -> String? {
        var parts: [String] = []
        if let year = int(meta["year"]) {
            parts.append(String(year))
        }
        if let duration = durationText(meta["duration"]) {
            parts.append(duration)
        }
        if let studio = string(meta["studio"]), !studio.isEmpty {
            parts.append(studio)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func badge(meta: [String: Any]) -> String? {
        if let media = (meta["Media"] as? [[String: Any]])?.first {
            if let width = int(media["width"]), width >= 3840 {
                return "4K"
            }
            if let width = int(media["width"]), width >= 1920 {
                return "1080p"
            }
            if let width = int(media["width"]), width >= 1280 {
                return "720p"
            }
        }
        return nil
    }

    private func browseKind(_ type: String) -> BrowseItemKind {
        switch type {
        case "show":
            return .show
        case "episode":
            return .episode
        default:
            return .movie
        }
    }

    private func deduplicated(items: [BrowseItem]) -> [BrowseItem] {
        var seen: Set<String> = []
        var unique: [BrowseItem] = []
        for item in items where seen.insert(item.id).inserted {
            unique.append(item)
        }
        return unique
    }

    private func progressFraction(durationMs: Int64?, offsetMs: Int64?) -> Double? {
        guard let durationMs, let offsetMs, durationMs > 0, offsetMs > 0 else { return nil }
        return min(max(Double(offsetMs) / Double(durationMs), 0), 1)
    }

    private func hierarchyProgressFraction(leafCount: Int?, viewedLeafCount: Int?) -> Double? {
        guard let leafCount, let viewedLeafCount, leafCount > 0, viewedLeafCount > 0 else { return nil }
        return min(max(Double(viewedLeafCount) / Double(leafCount), 0), 1)
    }

    private func addedDate(_ value: Any?) -> Date? {
        guard let timestamp = int64(value), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private func durationText(_ value: Any?) -> String? {
        guard let durationMs = int64(value), durationMs > 0 else { return nil }
        return TimeFormatting.display(durationMs * 1_000)
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func trimTrailingSlashes(_ value: String) -> String {
        var result = value
        while result.count > 1, result.last == "/" {
            result.removeLast()
        }
        return result
    }

    private static func context(for config: SourceConfig) -> PlexContext? {
        guard config.type == .plex,
              let token = KeychainHelper.password(for: config.id),
              !token.isEmpty else {
            return nil
        }

        let key = "plexClientIdentifier"
        let clientIdentifier: String
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            clientIdentifier = existing
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: key)
            clientIdentifier = generated
        }

        return PlexContext(config: config, token: token, clientIdentifier: clientIdentifier)
    }

    private static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #else
        return "iOS"
        #endif
    }

    private static func recencySort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        switch (lhs.addedAt, rhs.addedAt) {
        case let (lhsDate?, rhsDate?):
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return titleSort(lhs: lhs, rhs: rhs)
        }
    }

    private static func titleSort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func episodeSort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        if lhs.seasonNumber != rhs.seasonNumber {
            return (lhs.seasonNumber ?? 0) < (rhs.seasonNumber ?? 0)
        }
        if lhs.episodeNumber != rhs.episodeNumber {
            return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
        }
        return titleSort(lhs: lhs, rhs: rhs)
    }
}

private enum SourceConfigStoreResolver {
    static let shared = SourceConfigLookup()
}

private final class SourceConfigLookup: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let key = "savedSourceConfigs"

    func sourceConfig(sourceID: String) -> SourceConfig? {
        guard let json = defaults.string(forKey: key),
              let data = json.data(using: .utf8),
              let sources = try? JSONDecoder().decode([SourceConfig].self, from: data) else {
            return nil
        }
        return sources.first(where: { $0.id == sourceID })
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
