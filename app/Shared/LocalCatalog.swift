import Foundation

struct LocalCatalogSnapshot: Sendable {
    let movies: [BrowseItem]
    let shows: [BrowseItem]
    let continueWatching: [BrowseItem]
    let recentlyAdded: [BrowseItem]
    let itemsByID: [String: BrowseItem]
    let showSections: [String: [BrowseDetailSection]]

    static let empty = LocalCatalogSnapshot(
        movies: [],
        shows: [],
        continueWatching: [],
        recentlyAdded: [],
        itemsByID: [:],
        showSections: [:]
    )
}

enum LocalCatalogBuilder {
    static func build(items: [LibraryItem],
                      watchedIDs: Set<String>) -> LocalCatalogSnapshot {
        var movies: [BrowseItem] = []
        var showsByID: [String: LocalShowGroup] = [:]
        var continueWatching: [BrowseItem] = []
        var itemsByID: [String: BrowseItem] = [:]

        for item in items {
            let parsed = LocalMetadataParser.parse(item: item, watchedIDs: watchedIDs)
            switch parsed.kind {
            case .movie:
                movies.append(parsed.browseItem)
                itemsByID[parsed.browseItem.id] = parsed.browseItem
                if parsed.browseItem.progress != nil && !parsed.browseItem.isWatched {
                    continueWatching.append(parsed.browseItem)
                }

            case .episode(let showID, let showTitle, let season):
                var group = showsByID[showID] ?? LocalShowGroup(
                    id: showID,
                    title: showTitle,
                    artwork: parsed.browseItem.artwork
                )
                group.artwork = group.artwork.hasArtwork ? group.artwork : parsed.browseItem.artwork
                group.addedAt = maxDate(group.addedAt, parsed.browseItem.addedAt)
                group.seasons[season, default: []].append(parsed.browseItem)
                group.episodes.append(parsed.browseItem)
                showsByID[showID] = group
                itemsByID[parsed.browseItem.id] = parsed.browseItem
                if parsed.browseItem.progress != nil && !parsed.browseItem.isWatched {
                    continueWatching.append(parsed.browseItem)
                }
            }
        }

        let shows = showsByID.values
            .map { $0.makeBrowseItem() }
            .sorted(by: browseItemSort)

        for show in shows {
            itemsByID[show.id] = show
        }

        let recentlyAdded = (movies + shows)
            .sorted {
                switch ($0.addedAt, $1.addedAt) {
                case let (lhs?, rhs?):
                    return lhs > rhs
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
            }

        let showSections = showsByID.reduce(into: [String: [BrowseDetailSection]]()) { partial, entry in
            partial[entry.key] = entry.value.makeSections()
        }

        return LocalCatalogSnapshot(
            movies: movies.sorted(by: browseItemSort),
            shows: shows,
            continueWatching: continueWatching.sorted(by: continueSort),
            recentlyAdded: recentlyAdded,
            itemsByID: itemsByID,
            showSections: showSections
        )
    }

    private static func browseItemSort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private static func continueSort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        switch (lhs.addedAt, rhs.addedAt) {
        case let (lhsDate?, rhsDate?):
            return lhsDate > rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (.some(lhs), .none):
            return lhs
        case let (.none, .some(rhs)):
            return rhs
        case (.none, .none):
            return nil
        }
    }
}

private struct LocalShowGroup {
    let id: String
    let title: String
    var artwork: BrowseArtwork
    var addedAt: Date?
    var episodes: [BrowseItem] = []
    var seasons: [Int: [BrowseItem]] = [:]

    func makeBrowseItem() -> BrowseItem {
        let sortedEpisodes = episodes.sorted(by: localEpisodeSort)
        let nextPlayable = sortedEpisodes.first(where: { !$0.isWatched }) ?? sortedEpisodes.first
        let isWatched = !sortedEpisodes.isEmpty && sortedEpisodes.allSatisfy(\.isWatched)
        let inProgressEpisode = sortedEpisodes.first(where: { ($0.progress ?? 0) > 0 })
        let episodeCount = sortedEpisodes.count

        return BrowseItem(
            id: "local:show:\(id)",
            kind: .show,
            source: .local,
            title: title,
            subtitle: episodeCount == 1 ? "1 episode" : "\(episodeCount) episodes",
            summary: nil,
            metadataLine: seasons.keys.sorted().map { "Season \($0)" }.joined(separator: " • "),
            badge: nil,
            artwork: artwork,
            progress: inProgressEpisode?.progress,
            isWatched: isWatched,
            sourceName: "Local Library",
            playbackItem: nextPlayable?.playbackItem,
            filePath: nil,
            ratingKey: nil,
            plexKey: nil,
            sourceID: nil,
            sourceTypeRawValue: SourceType.local.rawValue,
            addedAt: addedAt,
            year: nil,
            seasonNumber: nil,
            episodeNumber: nil
        )
    }

    func makeSections() -> [BrowseDetailSection] {
        seasons.keys.sorted().map { season in
            let items = (seasons[season] ?? []).sorted(by: localEpisodeSort)
            return BrowseDetailSection(
                id: "season-\(season)",
                title: "Season \(season)",
                items: items
            )
        }
    }

    private func localEpisodeSort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        if lhs.seasonNumber != rhs.seasonNumber {
            return (lhs.seasonNumber ?? 0) < (rhs.seasonNumber ?? 0)
        }
        if lhs.episodeNumber != rhs.episodeNumber {
            return (lhs.episodeNumber ?? 0) < (rhs.episodeNumber ?? 0)
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
}

private struct ParsedLocalMedia {
    enum Kind {
        case movie
        case episode(showID: String, showTitle: String, season: Int)
    }

    let kind: Kind
    let browseItem: BrowseItem
}

private struct CachedLocalMetadata {
    enum Kind {
        case movie(title: String, year: Int?)
        case episode(ParsedEpisode)
    }

    let kind: Kind
    let artwork: BrowseArtwork
    let addedAt: Date?
}

private struct LocalCatalogCacheKey: Hashable {
    let filePath: String
    let fileSize: Int64
    let fileModificationDate: Date?
    let directoryModificationDate: Date?
    let showDirectoryModificationDate: Date?
}

private enum LocalCatalogMetadataCache {
    private static let maxEntries = 4_096
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [LocalCatalogCacheKey: CachedLocalMetadata] = [:]
    nonisolated(unsafe) private static var insertionOrder: [LocalCatalogCacheKey] = []

    static func metadata(for item: LibraryItem, fileURL: URL) -> CachedLocalMetadata {
        let directories = LocalArtworkResolver.artworkDirectories(for: fileURL)
        let key = LocalCatalogCacheKey(
            filePath: item.filePath,
            fileSize: item.fileSize,
            fileModificationDate: modificationDate(for: fileURL),
            directoryModificationDate: modificationDate(for: directories.directory),
            showDirectoryModificationDate: directories.showDirectory.flatMap(modificationDate(for:))
        )

        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let metadata = LocalMetadataParser.buildCachedMetadata(fileURL: fileURL,
                                                               addedAt: key.fileModificationDate)

        lock.lock()
        if entries[key] == nil {
            entries[key] = metadata
            insertionOrder.append(key)
            trimIfNeeded()
        }
        let cached = entries[key] ?? metadata
        lock.unlock()
        return cached
    }

    private static func trimIfNeeded() {
        while insertionOrder.count > maxEntries {
            let evicted = insertionOrder.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    private static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private enum LocalMetadataParser {
    static func parse(item: LibraryItem, watchedIDs: Set<String>) -> ParsedLocalMedia {
        let fileURL = URL(fileURLWithPath: item.filePath)
        let cached = LocalCatalogMetadataCache.metadata(for: item, fileURL: fileURL)
        let progress = progress(for: item)
        let isWatched = watchedIDs.contains("local:file:\(item.filePath)")

        switch cached.kind {
        case let .episode(episode):
            let playbackItem = PlaybackItem.local(path: item.filePath, displayName: episode.episodeTitle)
            let browseItem = BrowseItem(
                id: "local:file:\(item.filePath)",
                kind: .episode,
                source: .local,
                title: episode.episodeTitle,
                subtitle: "\(episode.showTitle) • S\(episode.season)E\(episode.episode)",
                summary: nil,
                metadataLine: metadataLine(for: item),
                badge: item.hdrText.isEmpty ? item.resolutionText : item.hdrText,
                artwork: cached.artwork,
                progress: progress,
                isWatched: isWatched,
                sourceName: "Local Library",
                playbackItem: playbackItem,
                filePath: item.filePath,
                ratingKey: nil,
                plexKey: nil,
                sourceID: nil,
                sourceTypeRawValue: SourceType.local.rawValue,
                addedAt: cached.addedAt,
                year: nil,
                seasonNumber: episode.season,
                episodeNumber: episode.episode
            )
            return ParsedLocalMedia(
                kind: .episode(showID: episode.showID, showTitle: episode.showTitle, season: episode.season),
                browseItem: browseItem
            )

        case let .movie(title, year):
            let playbackItem = PlaybackItem.local(path: item.filePath, displayName: title)
            let movieItem = BrowseItem(
                id: "local:file:\(item.filePath)",
                kind: .movie,
                source: .local,
                title: title,
                subtitle: item.durationText,
                summary: nil,
                metadataLine: metadataLine(for: item),
                badge: item.hdrText.isEmpty ? item.resolutionText : item.hdrText,
                artwork: cached.artwork,
                progress: progress,
                isWatched: isWatched,
                sourceName: "Local Library",
                playbackItem: playbackItem,
                filePath: item.filePath,
                ratingKey: nil,
                plexKey: nil,
                sourceID: nil,
                sourceTypeRawValue: SourceType.local.rawValue,
                addedAt: cached.addedAt,
                year: year,
                seasonNumber: nil,
                episodeNumber: nil
            )
            return ParsedLocalMedia(kind: .movie, browseItem: movieItem)
        }
    }

    static func buildCachedMetadata(fileURL: URL, addedAt: Date?) -> CachedLocalMetadata {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let artwork = LocalArtworkResolver.resolve(for: fileURL)

        if let episode = parseEpisode(fileName: fileName, fileURL: fileURL) {
            return CachedLocalMetadata(kind: .episode(episode),
                                       artwork: artwork,
                                       addedAt: addedAt)
        }

        let year = parseYear(in: fileName)
        let movieTitle = cleanedMovieTitle(fileName: fileName, year: year)
        let title = year.map { "\(movieTitle) (\($0))" } ?? movieTitle
        return CachedLocalMetadata(kind: .movie(title: title, year: year),
                                   artwork: artwork,
                                   addedAt: addedAt)
    }

    private static func parseEpisode(fileName: String, fileURL: URL) -> ParsedEpisode? {
        let patterns = [
            #"[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})"#,
            #"(\d{1,2})x(\d{1,3})"#
        ]

        for pattern in patterns {
            if let match = firstRegexMatch(pattern: pattern, in: fileName),
               let season = Int(match.captures[0]),
               let episode = Int(match.captures[1]) {
                let prefix = (fileName as NSString).substring(to: match.range.location)
                let suffixStart = match.range.location + match.range.length
                let suffix = suffixStart < (fileName as NSString).length
                    ? (fileName as NSString).substring(from: suffixStart)
                    : ""
                let showTitle = cleanTitle(prefix).nonEmpty ?? inferredShowTitle(from: fileURL)
                let episodeTitle = cleanTitle(suffix).nonEmpty ?? "Episode \(episode)"
                return ParsedEpisode(
                    showID: normalizedID(for: inferredShowFolder(from: fileURL) ?? showTitle),
                    showTitle: showTitle,
                    season: season,
                    episode: episode,
                    episodeTitle: episodeTitle
                )
            }
        }

        let parentFolder = fileURL.deletingLastPathComponent().lastPathComponent
        if let season = parseSeasonFolder(parentFolder) {
            let showTitle = inferredShowTitle(from: fileURL)
            let episodeNumber = leadingEpisodeNumber(in: fileName) ?? 0
            let episodeTitle = cleanTitle(fileName).nonEmpty ?? "Episode \(episodeNumber)"
            return ParsedEpisode(
                showID: normalizedID(for: inferredShowFolder(from: fileURL) ?? showTitle),
                showTitle: showTitle,
                season: season,
                episode: episodeNumber,
                episodeTitle: episodeTitle
            )
        }

        return nil
    }

    private static func inferredShowTitle(from fileURL: URL) -> String {
        if let showFolder = inferredShowFolder(from: fileURL) {
            return cleanTitle(showFolder)
        }
        return cleanTitle(fileURL.deletingPathExtension().lastPathComponent)
    }

    private static func inferredShowFolder(from fileURL: URL) -> String? {
        let parent = fileURL.deletingLastPathComponent()
        let parentName = parent.lastPathComponent
        if LocalCatalogPatterns.parseSeasonFolder(parentName) != nil {
            let showFolder = parent.deletingLastPathComponent().lastPathComponent
            return showFolder.nonEmpty
        }
        return parentName.nonEmpty
    }

    private static func parseSeasonFolder(_ name: String) -> Int? {
        LocalCatalogPatterns.parseSeasonFolder(name)
    }

    private static func leadingEpisodeNumber(in fileName: String) -> Int? {
        if let match = firstRegexMatch(pattern: #"^(\d{1,3})"#, in: fileName),
           let number = Int(match.captures[0]) {
            return number
        }
        return nil
    }

    private static func parseYear(in value: String) -> Int? {
        if let match = firstRegexMatch(pattern: #"(19|20)\d{2}"#, in: value),
           let year = Int(match.fullMatch) {
            return year
        }
        return nil
    }

    private static func cleanedMovieTitle(fileName: String, year: Int?) -> String {
        let cleaned = cleanTitle(fileName)
        guard let year else { return cleaned }

        let yearSuffix = " \(year)"
        if cleaned.hasSuffix(yearSuffix) {
            let trimmed = String(cleaned.dropLast(yearSuffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? cleaned : trimmed
        }

        return cleaned
    }

    private static func cleanTitle(_ value: String) -> String {
        var text = value

        text = text.replacingOccurrences(of: "[._]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\([^\)]+\)"#, with: "", options: .regularExpression)
        text = LocalCatalogPatterns.stripReleaseTags(from: text)

        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func metadataLine(for item: LibraryItem) -> String {
        [item.durationText, item.resolutionText, item.videoCodec.uppercased(), item.audioCodec.uppercased()]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private static func progress(for item: LibraryItem) -> Double? {
        guard item.durationUs > 0, let position = ResumeStore.position(for: item.filePath) else { return nil }
        return min(max(Double(position) / Double(item.durationUs), 0), 1)
    }
    private static func firstRegexMatch(pattern: String, in text: String) -> RegexMatch? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let captures: [String] = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        guard let fullRange = Range(match.range(at: 0), in: text) else { return nil }
        return RegexMatch(
            range: match.range(at: 0),
            fullMatch: String(text[fullRange]),
            captures: captures
        )
    }

    private static func normalizedID(for value: String) -> String {
        cleanTitle(value).lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

private struct ParsedEpisode {
    let showID: String
    let showTitle: String
    let season: Int
    let episode: Int
    let episodeTitle: String
}

private struct RegexMatch {
    let range: NSRange
    let fullMatch: String
    let captures: [String]
}

private enum LocalArtworkResolver {
    private static let imageExtensions = ["jpg", "jpeg", "png"]
    private static let posterNames = ["poster", "folder"]
    private static let backdropNames = ["fanart", "backdrop", "background"]

    static func resolve(for fileURL: URL) -> BrowseArtwork {
        let fileName = fileURL.deletingPathExtension().lastPathComponent
        let directories = artworkDirectories(for: fileURL)

        return BrowseArtwork(
            posterPath: resolvePoster(fileName: fileName,
                                      directory: directories.directory,
                                      showDirectory: directories.showDirectory),
            posterURL: nil,
            backdropPath: resolveBackdrop(directory: directories.directory,
                                          showDirectory: directories.showDirectory),
            backdropURL: nil
        )
    }

    static func artworkDirectories(for fileURL: URL) -> (directory: URL, showDirectory: URL?) {
        let directory = fileURL.deletingLastPathComponent()
        return (directory: directory, showDirectory: showDirectory(for: fileURL))
    }

    private static func resolvePoster(fileName: String,
                                      directory: URL,
                                      showDirectory: URL?) -> String? {
        let sameFileCandidates = imageExtensions.map { directory.appendingPathComponent("\(fileName).\($0)").path }
        for candidate in sameFileCandidates where FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }

        for directory in [showDirectory, directory].compactMap({ $0 }) {
            for name in posterNames {
                for ext in imageExtensions {
                    let path = directory.appendingPathComponent("\(name).\(ext)").path
                    if FileManager.default.fileExists(atPath: path) {
                        return path
                    }
                }
            }
        }
        return nil
    }

    private static func resolveBackdrop(directory: URL, showDirectory: URL?) -> String? {
        for directory in [showDirectory, directory].compactMap({ $0 }) {
            for name in backdropNames {
                for ext in imageExtensions {
                    let path = directory.appendingPathComponent("\(name).\(ext)").path
                    if FileManager.default.fileExists(atPath: path) {
                        return path
                    }
                }
            }
        }
        return nil
    }

    private static func showDirectory(for fileURL: URL) -> URL? {
        let parent = fileURL.deletingLastPathComponent()
        let name = parent.lastPathComponent.lowercased()
        if LocalCatalogPatterns.parseSeasonFolder(name) != nil {
            return parent.deletingLastPathComponent()
        }
        return parent
    }
}

private enum LocalCatalogPatterns {
    private static let releaseTokens = [
        "2160p", "1080p", "720p", "480p", "bluray", "blu ray", "web dl", "webrip",
        "brrip", "dvdrip", "x264", "x265", "h264", "h265", "hevc", "aac", "dts",
        "hdr", "dolby vision", "dv", "remux", "atmos", "truehd", "ddp", "yts"
    ]

    private static let releaseTagRegex: NSRegularExpression? = {
        let tokenPattern = releaseTokens
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(tokenPattern))(?![\\p{L}\\p{N}])"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let seasonFolderRegex = try? NSRegularExpression(pattern: #"(?i)season[ ._-]?(\d{1,2})"#)

    static func parseSeasonFolder(_ name: String) -> Int? {
        guard let seasonFolderRegex else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = seasonFolderRegex.firstMatch(in: name, range: range),
              let capture = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return Int(name[capture])
    }

    static func stripReleaseTags(from text: String) -> String {
        guard let releaseTagRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return releaseTagRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
