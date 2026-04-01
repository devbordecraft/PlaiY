import Foundation
import SwiftUI

@MainActor
final class BrowseStore: ObservableObject {
    enum FilesMode: String, CaseIterable, Identifiable {
        case library
        case sources

        var id: String { rawValue }

        var title: String {
            switch self {
            case .library: "Library"
            case .sources: "Sources"
            }
        }
    }

    @Published var destination: BrowseDestination = .home
    @Published var homeLayout: HomeLayoutState
    @Published var searchText = ""
    @Published private(set) var searchResults: [BrowseItem] = []
    @Published private(set) var recentQueries: [String]
    @Published private(set) var isSearching = false
    @Published private(set) var isRefreshingPlex = false
    @Published private(set) var favoriteEntries: [FavoriteEntry]
    @Published private(set) var localSnapshot = LocalCatalogSnapshot.empty
    @Published private(set) var plexSnapshot = PlexCatalogSnapshot.empty
    @Published var filesMode: FilesMode = .library
    @Published private(set) var pinnedFolderPath: String?
    @Published private(set) var pinnedSourceID: String?
    @Published private(set) var pinNavigationToken = UUID()

    private let homeLayoutStore: UserDefaultsHomeLayoutStore
    private let favoritesStore: UserDefaultsFavoritesStore
    private let watchStatusStore: UserDefaultsWatchStatusStore
    private let plexClient: PlexCatalogClient
    private let defaults: UserDefaults
    private let recentQueriesKey = "browse.recentQueries"

    private var watchedIDs: Set<String>
    private var currentLibraryItems: [LibraryItem] = []
    private var currentFolders: [String] = []
    private var currentSources: [SourceConfig] = []
    private var refreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    init(homeLayoutStore: UserDefaultsHomeLayoutStore = UserDefaultsHomeLayoutStore(),
         favoritesStore: UserDefaultsFavoritesStore = UserDefaultsFavoritesStore(),
         watchStatusStore: UserDefaultsWatchStatusStore = UserDefaultsWatchStatusStore(),
         plexClient: PlexCatalogClient = PlexCatalogClient(),
         defaults: UserDefaults = .standard) {
        self.homeLayoutStore = homeLayoutStore
        self.favoritesStore = favoritesStore
        self.watchStatusStore = watchStatusStore
        self.plexClient = plexClient
        self.defaults = defaults
        self.homeLayout = homeLayoutStore.load()
        self.favoriteEntries = favoritesStore.load()
        self.watchedIDs = watchStatusStore.load()
        self.recentQueries = defaults.stringArray(forKey: recentQueriesKey) ?? []
        normalizeHomeLayout()
    }

    deinit {
        refreshTask?.cancel()
        searchTask?.cancel()
    }

    func refresh(libraryItems: [LibraryItem], folders: [String], sources: [SourceConfig]) {
        currentLibraryItems = libraryItems
        currentFolders = folders
        currentSources = sources
        localSnapshot = LocalCatalogBuilder.build(items: libraryItems, watchedIDs: watchedIDs)
        normalizeHomeLayout()

        refreshTask?.cancel()
        refreshTask = Task { [sources] in
            await MainActor.run { self.isRefreshingPlex = true }
            let snapshot = await plexClient.fetchSnapshot(sources: sources)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.plexSnapshot = snapshot
                self.isRefreshingPlex = false
                if !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.performSearch()
                }
            }
        }
    }

    func markPlaybackFinished(_ item: PlaybackItem) {
        guard !item.isPlex else { return }
        watchedIDs.insert("local:file:\(item.path)")
        watchStatusStore.save(watchedIDs)
        localSnapshot = LocalCatalogBuilder.build(items: currentLibraryItems, watchedIDs: watchedIDs)
    }

    func markPlaybackRestarted(_ item: PlaybackItem) {
        guard !item.isPlex else { return }
        watchedIDs.remove("local:file:\(item.path)")
        watchStatusStore.save(watchedIDs)
        localSnapshot = LocalCatalogBuilder.build(items: currentLibraryItems, watchedIDs: watchedIDs)
    }

    func toggleFavorite(_ item: BrowseItem) {
        if let index = favoriteEntries.firstIndex(where: { $0.id == item.id }) {
            favoriteEntries.remove(at: index)
        } else {
            favoriteEntries.insert(
                FavoriteEntry(
                    id: item.id,
                    title: item.title,
                    subtitle: item.subtitle,
                    kind: item.kind.rawValue,
                    createdAt: Date()
                ),
                at: 0
            )
        }
        favoritesStore.save(favoriteEntries)
    }

    func isFavorite(_ item: BrowseItem) -> Bool {
        favoriteEntries.contains(where: { $0.id == item.id })
    }

    func favoriteItems() -> [BrowseItem] {
        favoriteEntries.compactMap { entry in
            if let item = itemByID(entry.id) {
                return item
            }

            let kind = BrowseItemKind(rawValue: entry.kind) ?? .movie
            return BrowseItem(
                id: entry.id,
                kind: kind,
                source: entry.id.hasPrefix("plex:") ? .plex : .local,
                title: entry.title,
                subtitle: entry.subtitle,
                summary: nil,
                metadataLine: nil,
                badge: nil,
                artwork: BrowseArtwork(),
                progress: nil,
                isWatched: false,
                sourceName: nil,
                playbackItem: nil,
                filePath: nil,
                ratingKey: nil,
                plexKey: nil,
                sourceID: nil,
                sourceTypeRawValue: nil,
                addedAt: entry.createdAt,
                year: nil,
                seasonNumber: nil,
                episodeNumber: nil
            )
        }
    }

    func homeShelves() -> [BrowseShelf] {
        homeLayout.shelves
            .filter(\.isVisible)
            .compactMap { config in
                let items = shelfItems(for: config.kind)
                guard !items.isEmpty else { return nil }
                return BrowseShelf(
                    id: config.kind.rawValue,
                    kind: config.kind,
                    title: config.kind.title,
                    subtitle: shelfSubtitle(for: config.kind, itemCount: items.count),
                    items: Array(items.prefix(20))
                )
            }
    }

    func items(for destination: BrowseDestination) -> [BrowseItem] {
        switch destination {
        case .movies:
            return deduplicated(localSnapshot.movies + plexSnapshot.movies)
                .sorted(by: titleSort)
        case .shows:
            return deduplicated(localSnapshot.shows + plexSnapshot.shows)
                .sorted(by: titleSort)
        case .favorites:
            return favoriteItems()
        default:
            return []
        }
    }

    func browseItem(forLocalPath path: String) -> BrowseItem? {
        localSnapshot.itemsByID["local:file:\(path)"]
    }

    func itemByID(_ id: String) -> BrowseItem? {
        localSnapshot.itemsByID[id] ?? plexSnapshot.itemsByID[id]
    }

    func availableFolderPins() -> [PinnedDestination] {
        currentFolders.map { folder in
            PinnedDestination(
                id: "folder:\(folder)",
                kind: .folder,
                reference: folder,
                title: URL(fileURLWithPath: folder).lastPathComponent,
                subtitle: folder,
                sourceTypeRawValue: SourceType.local.rawValue,
                baseURI: nil
            )
        }
    }

    func availableSourcePins() -> [PinnedDestination] {
        currentSources.map { source in
            PinnedDestination(
                id: "source:\(source.id)",
                kind: .source,
                reference: source.id,
                title: source.displayName,
                subtitle: source.baseURI,
                sourceTypeRawValue: source.type.rawValue,
                baseURI: source.baseURI
            )
        }
    }

    func isPinned(_ pin: PinnedDestination) -> Bool {
        homeLayout.pins.contains(where: { $0.id == pin.id })
    }

    func togglePin(_ pin: PinnedDestination) {
        if let index = homeLayout.pins.firstIndex(where: { $0.id == pin.id }) {
            homeLayout.pins.remove(at: index)
        } else {
            homeLayout.pins.append(pin)
        }
        saveHomeLayout()
    }

    func moveShelves(from source: IndexSet, to destination: Int) {
        homeLayout.shelves.move(fromOffsets: source, toOffset: destination)
        saveHomeLayout()
    }

    func setShelfVisibility(_ kind: HomeShelfKind, isVisible: Bool) {
        guard let index = homeLayout.shelves.firstIndex(where: { $0.kind == kind }) else { return }
        homeLayout.shelves[index].isVisible = isVisible
        saveHomeLayout()
    }

    func updateSearch(text: String) {
        searchText = text
        performSearch()
    }

    func submitSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentQueries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentQueries.insert(trimmed, at: 0)
        recentQueries = Array(recentQueries.prefix(8))
        defaults.set(recentQueries, forKey: recentQueriesKey)
    }

    func removeRecentQuery(_ query: String) {
        recentQueries.removeAll { $0 == query }
        defaults.set(recentQueries, forKey: recentQueriesKey)
    }

    func resumeLabel(for item: BrowseItem) -> String? {
        guard let progress = item.progress, progress > 0 else { return nil }
        return item.kind == .show ? "Resume Show" : "Resume"
    }

    func playbackItem(for item: BrowseItem, sections: [BrowseDetailSection] = []) -> PlaybackItem? {
        if let playback = item.playbackItem {
            return playback
        }

        guard item.kind == .show else { return nil }

        let episodes = playbackEpisodes(for: item, sections: sections)
        if let current = episodes.first(where: { ($0.progress ?? 0) > 0 && !$0.isWatched })?.playbackItem {
            return current
        }
        if let next = episodes.first(where: { !$0.isWatched })?.playbackItem {
            return next
        }
        return episodes.first?.playbackItem
    }

    func defaultPlaybackItem(for item: BrowseItem) -> PlaybackItem? {
        playbackItem(for: item)
    }

    func buildBaseDetail(for item: BrowseItem) -> BrowseDetailModel {
        let metadata = [item.metadataLine, item.sourceName].compactMap { $0 }
        let sections: [BrowseDetailSection]
        if item.kind == .show, item.source == .local {
            let showID = item.id.replacingOccurrences(of: "local:show:", with: "")
            sections = localSnapshot.showSections[showID] ?? []
        } else {
            sections = []
        }

        let resolvedPlayback = playbackItem(for: item, sections: sections)
        var actions: [BrowseDetailAction] = [.favorite]
        if item.progress != nil, resolvedPlayback != nil {
            actions.insert(.resume, at: 0)
        }
        if resolvedPlayback != nil {
            actions.insert(.play, at: 0)
        }

        return BrowseDetailModel(
            item: item,
            heroTitle: item.title,
            heroSubtitle: item.subtitle,
            summary: item.summary,
            metadata: metadata,
            actions: actions,
            sections: sections
        )
    }

    func detailModel(for item: BrowseItem) async -> BrowseDetailModel {
        var model = buildBaseDetail(for: item)
        guard item.source == .plex else { return model }

        if let payload = await plexClient.fetchDetail(for: item) {
            let resolvedItem = payload.refreshedItem ?? item
            let resolvedPlayback = playbackItem(for: resolvedItem, sections: payload.sections)
            var actions: [BrowseDetailAction] = [.favorite]
            if resolvedItem.progress != nil, resolvedPlayback != nil {
                actions.insert(.resume, at: 0)
            }
            if resolvedPlayback != nil {
                actions.insert(.play, at: 0)
            }

            model = BrowseDetailModel(
                item: resolvedItem,
                heroTitle: resolvedItem.title,
                heroSubtitle: resolvedItem.subtitle,
                summary: payload.summary ?? resolvedItem.summary,
                metadata: payload.metadata.isEmpty ? model.metadata : payload.metadata,
                actions: actions,
                sections: payload.sections
            )
        }

        return model
    }

    func resolvePinnedItem(_ item: BrowseItem) -> BrowseDestination {
        guard item.source == .pin else { return destination }
        switch item.kind {
        case .source:
            filesMode = .sources
            pinnedSourceID = item.sourceID
            pinnedFolderPath = nil
        case .folder:
            filesMode = .library
            pinnedFolderPath = item.filePath
            pinnedSourceID = nil
        case .movie, .show, .episode:
            break
        }
        pinNavigationToken = UUID()
        destination = .files
        return destination
    }

    private func playbackEpisodes(for item: BrowseItem,
                                  sections: [BrowseDetailSection]) -> [BrowseItem] {
        if !sections.isEmpty {
            return sections.flatMap(\.items)
        }

        guard item.kind == .show, item.source == .local else {
            return []
        }

        let showID = item.id.replacingOccurrences(of: "local:show:", with: "")
        return (localSnapshot.showSections[showID] ?? []).flatMap(\.items)
    }

    private func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }

        let local = Array(localSnapshot.itemsByID.values).filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            ($0.subtitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
        searchResults = local.sorted(by: titleSort)
        isSearching = true

        let fallback = deduplicated(local + plexSnapshot.movies + plexSnapshot.shows + plexSnapshot.continueWatching)
        let sources = currentSources

        searchTask = Task { [trimmed, fallback, sources] in
            let results = await plexClient.search(query: trimmed, sources: sources, fallbackItems: fallback)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.searchResults = self.deduplicated(local + results).sorted(by: self.titleSort)
                self.isSearching = false
            }
        }
    }

    private func shelfItems(for kind: HomeShelfKind) -> [BrowseItem] {
        switch kind {
        case .continueWatching:
            return deduplicated(localSnapshot.continueWatching + plexSnapshot.continueWatching)
                .sorted(by: recencySort)
        case .favorites:
            return favoriteItems()
        case .recentlyAdded:
            return deduplicated(localSnapshot.recentlyAdded + plexSnapshot.recentlyAdded)
                .sorted(by: recencySort)
        case .unwatchedMovies:
            return deduplicated(localSnapshot.movies + plexSnapshot.movies)
                .filter { !$0.isWatched }
                .sorted(by: titleSort)
        case .unwatchedShows:
            return deduplicated(localSnapshot.shows + plexSnapshot.shows)
                .filter { !$0.isWatched }
                .sorted(by: titleSort)
        case .pinned:
            return homeLayout.pins.compactMap(makePinnedItem)
        }
    }

    private func makePinnedItem(from pin: PinnedDestination) -> BrowseItem? {
        switch pin.kind {
        case .source:
            return BrowseItem(
                id: pin.id,
                kind: .source,
                source: .pin,
                title: pin.title,
                subtitle: pin.subtitle,
                summary: nil,
                metadataLine: nil,
                badge: nil,
                artwork: BrowseArtwork(),
                progress: nil,
                isWatched: false,
                sourceName: "Pinned Source",
                playbackItem: nil,
                filePath: nil,
                ratingKey: nil,
                plexKey: nil,
                sourceID: pin.reference,
                sourceTypeRawValue: pin.sourceTypeRawValue,
                addedAt: nil,
                year: nil,
                seasonNumber: nil,
                episodeNumber: nil
            )
        case .folder:
            return BrowseItem(
                id: pin.id,
                kind: .folder,
                source: .pin,
                title: pin.title,
                subtitle: pin.subtitle,
                summary: nil,
                metadataLine: nil,
                badge: nil,
                artwork: BrowseArtwork(),
                progress: nil,
                isWatched: false,
                sourceName: "Pinned Folder",
                playbackItem: nil,
                filePath: pin.reference,
                ratingKey: nil,
                plexKey: nil,
                sourceID: nil,
                sourceTypeRawValue: pin.sourceTypeRawValue,
                addedAt: nil,
                year: nil,
                seasonNumber: nil,
                episodeNumber: nil
            )
        }
    }

    private func normalizeHomeLayout() {
        let known = Set(homeLayout.shelves.map(\.kind))
        for kind in HomeShelfKind.default where !known.contains(kind) {
            homeLayout.shelves.append(HomeShelfConfiguration(kind: kind, isVisible: true))
        }
        homeLayout.shelves.removeAll { !HomeShelfKind.default.contains($0.kind) }
    }

    private func saveHomeLayout() {
        normalizeHomeLayout()
        homeLayoutStore.save(homeLayout)
    }

    private func deduplicated(_ items: [BrowseItem]) -> [BrowseItem] {
        var seen: Set<String> = []
        var unique: [BrowseItem] = []
        for item in items where seen.insert(item.id).inserted {
            unique.append(item)
        }
        return unique
    }

    private func shelfSubtitle(for kind: HomeShelfKind, itemCount: Int) -> String? {
        switch kind {
        case .continueWatching:
            return itemCount == 1 ? "1 title in progress" : "\(itemCount) titles in progress"
        case .favorites:
            return itemCount == 1 ? "1 favorite" : "\(itemCount) favorites"
        case .recentlyAdded:
            return "Fresh additions from local and Plex"
        case .unwatchedMovies:
            return "Movies waiting to be watched"
        case .unwatchedShows:
            return "Shows you have not finished"
        case .pinned:
            return itemCount == 1 ? "1 quick shortcut" : "\(itemCount) quick shortcuts"
        }
    }

    private func titleSort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
        lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func recencySort(lhs: BrowseItem, rhs: BrowseItem) -> Bool {
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
}
