import XCTest
@testable import PlaiY

private typealias AppLibraryItem = PlaiY.LibraryItem

final class BrowseStoreTests: XCTestCase {
    private var defaultsSuite: String!
    private var homeLayoutDefaults: UserDefaults!
    private var favoritesDefaults: UserDefaults!
    private var watchedDefaults: UserDefaults!
    private var appDefaults: UserDefaults!
    private var cleanupResumeKeys: [String] = []

    override func setUp() {
        super.setUp()
        defaultsSuite = "com.plaiy.tests.browse-store.\(UUID().uuidString)"
        homeLayoutDefaults = UserDefaults(suiteName: "\(defaultsSuite!).layout")
        favoritesDefaults = UserDefaults(suiteName: "\(defaultsSuite!).favorites")
        watchedDefaults = UserDefaults(suiteName: "\(defaultsSuite!).watched")
        appDefaults = UserDefaults(suiteName: "\(defaultsSuite!).app")
        for (defaults, suite) in [
            (homeLayoutDefaults, "\(defaultsSuite!).layout"),
            (favoritesDefaults, "\(defaultsSuite!).favorites"),
            (watchedDefaults, "\(defaultsSuite!).watched"),
            (appDefaults, "\(defaultsSuite!).app")
        ] {
            defaults?.removePersistentDomain(forName: suite)
        }
    }

    override func tearDown() {
        for key in cleanupResumeKeys {
            ResumeStore.clear(path: key)
        }
        cleanupResumeKeys.removeAll()
        homeLayoutDefaults = nil
        favoritesDefaults = nil
        watchedDefaults = nil
        appDefaults = nil
        defaultsSuite = nil
        super.tearDown()
    }

    @MainActor
    func testRefreshBuildsMoviesAndSearchFindsLocalMatches() {
        let store = makeStore()
        let item = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/Gladiator.2000.mkv")
        cleanupResumeKeys.append(item.filePath)

        store.refresh(libraryItems: [item], folders: [], sources: [])
        store.updateSearch(text: "gladiator")

        XCTAssertEqual(store.items(for: .movies).map(\.title), ["Gladiator (2000)"])
        XCTAssertEqual(store.searchResults.map(\.title), ["Gladiator (2000)"])
    }

    @MainActor
    func testSearchIncludesLocalEpisodesOutsideContinueWatching() {
        let episode = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/Dark/Season 1/Dark.S01E02.Lies.mkv")
        cleanupResumeKeys.append(episode.filePath)

        let store = makeStore()
        store.refresh(libraryItems: [episode], folders: [], sources: [])
        store.updateSearch(text: "lies")

        XCTAssertEqual(store.searchResults.map(\.title), ["Lies"])
        XCTAssertEqual(store.searchResults.first?.kind, .episode)
    }

    func testBrowseItemKindsUseLandscapeSearchThumbnailStyles() {
        XCTAssertEqual(BrowseItemKind.movie.searchThumbnailStyle, .landscape)
        XCTAssertEqual(BrowseItemKind.show.searchThumbnailStyle, .landscape)
        XCTAssertEqual(BrowseItemKind.episode.searchThumbnailStyle, .landscape)
        XCTAssertEqual(BrowseItemKind.folder.searchThumbnailStyle, .landscape)
        XCTAssertEqual(BrowseItemKind.source.searchThumbnailStyle, .landscape)
    }

    @MainActor
    func testSearchKeepsMixedMovieShowAndEpisodeResults() {
        let movie = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/Dark.City.1998.mkv")
        let episode = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/Dark/Season 1/Dark.S01E02.Dark.Matter.mkv")
        cleanupResumeKeys.append(contentsOf: [movie.filePath, episode.filePath])

        let store = makeStore()
        store.refresh(libraryItems: [movie, episode], folders: [], sources: [])
        store.updateSearch(text: "dark")

        XCTAssertEqual(store.searchResults.map(\.title), ["Dark", "Dark City (1998)", "Dark Matter"])
        XCTAssertEqual(store.searchResults.map(\.kind), [.show, .movie, .episode])
    }

    @MainActor
    func testToggleFavoritePersistsResolvedFavoriteItems() {
        let item = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/Alien.1979.mkv")
        cleanupResumeKeys.append(item.filePath)

        let store = makeStore()
        store.refresh(libraryItems: [item], folders: [], sources: [])
        let browseItem = tryUnwrap(store.items(for: .movies).first)

        store.toggleFavorite(browseItem)

        XCTAssertTrue(store.isFavorite(browseItem))
        XCTAssertEqual(store.items(for: .favorites).map(\.id), [browseItem.id])

        let reloaded = makeStore()
        reloaded.refresh(libraryItems: [item], folders: [], sources: [])
        XCTAssertEqual(reloaded.items(for: .favorites).map(\.id), [browseItem.id])
    }

    @MainActor
    func testMarkPlaybackFinishedRemovesMovieFromUnwatchedShelf() {
        let item = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/Blade.Runner.1982.mkv")
        cleanupResumeKeys.append(item.filePath)

        let store = makeStore()
        store.refresh(libraryItems: [item], folders: [], sources: [])

        XCTAssertEqual(store.homeShelves().first(where: { $0.kind == .unwatchedMovies })?.items.count, 1)

        store.markPlaybackFinished(.local(path: item.filePath))

        XCTAssertTrue(store.items(for: .movies).allSatisfy(\.isWatched))
        XCTAssertNil(store.homeShelves().first(where: { $0.kind == .unwatchedMovies }))
    }

    @MainActor
    func testPinnedSourceRoutesToFilesSourceMode() {
        let source = SourceConfig(
            id: "nas-source",
            displayName: "NAS",
            type: .smb,
            baseURI: "smb://nas/media",
            username: "guest"
        )
        let store = makeStore()
        store.refresh(libraryItems: [], folders: ["/Volumes/Movies"], sources: [source])

        let pin = tryUnwrap(store.availableSourcePins().first)
        store.togglePin(pin)

        let pinnedItem = tryUnwrap(store.homeShelves().first(where: { $0.kind == .pinned })?.items.first)
        let destination = store.resolvePinnedItem(pinnedItem)

        XCTAssertEqual(destination, .files)
        XCTAssertEqual(store.destination, .files)
        XCTAssertEqual(store.filesMode, .sources)
        XCTAssertEqual(store.pinnedSourceID, source.id)
        XCTAssertNil(store.pinnedFolderPath)
    }

    @MainActor
    func testPinnedFolderRoutesToFilteredLibraryMode() {
        let folder = "/Volumes/Shows"
        let store = makeStore()
        store.refresh(libraryItems: [], folders: [folder], sources: [])

        let pin = tryUnwrap(store.availableFolderPins().first)
        store.togglePin(pin)

        let pinnedItem = tryUnwrap(store.homeShelves().first(where: { $0.kind == .pinned })?.items.first)
        let destination = store.resolvePinnedItem(pinnedItem)

        XCTAssertEqual(destination, .files)
        XCTAssertEqual(store.destination, .files)
        XCTAssertEqual(store.filesMode, .library)
        XCTAssertEqual(store.pinnedFolderPath, folder)
        XCTAssertNil(store.pinnedSourceID)
    }

    @MainActor
    func testLocalShowDetailIncludesSectionsAndResumeAction() {
        let episodeOne = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/The Expanse/Season 1/The.Expanse.S01E01.Dulcinea.mkv")
        let episodeTwo = makeLibraryItem(path: "/tmp/\(UUID().uuidString)/The Expanse/Season 1/The.Expanse.S01E02.The.Big.Empty.mkv")
        cleanupResumeKeys.append(contentsOf: [episodeOne.filePath, episodeTwo.filePath])
        ResumeStore.save(path: episodeOne.filePath, positionUs: 60_000_000, durationUs: episodeOne.durationUs)

        let store = makeStore()
        store.refresh(libraryItems: [episodeOne, episodeTwo], folders: [], sources: [])
        let show = tryUnwrap(store.items(for: .shows).first)

        let detail = store.buildBaseDetail(for: show)

        XCTAssertTrue(detail.actions.contains(.play))
        XCTAssertTrue(detail.actions.contains(.resume))
        XCTAssertEqual(detail.sections.count, 1)
        XCTAssertEqual(detail.sections.first?.title, "Season 1")
        XCTAssertEqual(detail.sections.first?.items.map(\.title), ["Dulcinea", "The Big Empty"])
    }

    @MainActor
    func testPlaybackItemForPlexShowPrefersInProgressEpisode() {
        let store = makeStore()
        let show = makePlexShow(progress: 0.5, isWatched: false)
        let firstEpisode = makePlexEpisode(title: "S01E01", season: 1, episode: 1)
        let currentEpisode = makePlexEpisode(title: "S01E02", season: 1, episode: 2, progress: 0.35)

        let playback = store.playbackItem(
            for: show,
            sections: [makeSection(season: 1, items: [firstEpisode, currentEpisode])]
        )

        XCTAssertEqual(playback?.resumeKey, currentEpisode.playbackItem?.resumeKey)
    }

    @MainActor
    func testPlaybackItemForPlexShowFallsBackToNextUnwatchedEpisode() {
        let store = makeStore()
        let show = makePlexShow(progress: 0.5, isWatched: false)
        let watchedEpisode = makePlexEpisode(title: "S01E01", season: 1, episode: 1, isWatched: true)
        let nextEpisode = makePlexEpisode(title: "S01E02", season: 1, episode: 2)

        let playback = store.playbackItem(
            for: show,
            sections: [makeSection(season: 1, items: [watchedEpisode, nextEpisode])]
        )

        XCTAssertEqual(playback?.resumeKey, nextEpisode.playbackItem?.resumeKey)
    }

    @MainActor
    func testPlaybackItemForPlexShowFallsBackToFirstEpisodeWhenAllWatched() {
        let store = makeStore()
        let show = makePlexShow(progress: 1.0, isWatched: true)
        let firstEpisode = makePlexEpisode(title: "S01E01", season: 1, episode: 1, isWatched: true)
        let secondEpisode = makePlexEpisode(title: "S01E02", season: 1, episode: 2, isWatched: true)

        let playback = store.playbackItem(
            for: show,
            sections: [makeSection(season: 1, items: [firstEpisode, secondEpisode])]
        )

        XCTAssertEqual(playback?.resumeKey, firstEpisode.playbackItem?.resumeKey)
    }

    @MainActor
    private func makeStore() -> BrowseStore {
        BrowseStore(
            homeLayoutStore: UserDefaultsHomeLayoutStore(defaults: homeLayoutDefaults!, key: "layout"),
            favoritesStore: UserDefaultsFavoritesStore(defaults: favoritesDefaults!, key: "favorites"),
            watchStatusStore: UserDefaultsWatchStatusStore(defaults: watchedDefaults!, key: "watched"),
            plexClient: PlexCatalogClient(),
            defaults: appDefaults!
        )
    }

    private func makeLibraryItem(path: String,
                                 durationUs: Int64 = 120_000_000) -> AppLibraryItem {
        AppLibraryItem(
            filePath: path,
            title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            durationUs: durationUs,
            videoWidth: 1920,
            videoHeight: 1080,
            videoCodec: "hevc",
            audioCodec: "aac",
            hdrType: 0,
            fileSize: 0
        )
    }

    private func tryUnwrap<T>(_ value: T?,
                              file: StaticString = #filePath,
                              line: UInt = #line) -> T {
        guard let value else {
            XCTFail("Expected non-nil value", file: file, line: line)
            fatalError("Expected non-nil value")
        }
        return value
    }

    private func makePlexShow(progress: Double?, isWatched: Bool) -> BrowseItem {
        BrowseItem(
            id: "plex:test:show",
            kind: .show,
            source: .plex,
            title: "The Show",
            subtitle: "2 episodes",
            summary: nil,
            metadataLine: nil,
            badge: nil,
            artwork: BrowseArtwork(),
            progress: progress,
            isWatched: isWatched,
            sourceName: "Plex Test",
            playbackItem: nil,
            filePath: nil,
            ratingKey: "show-rating-key",
            plexKey: "/library/metadata/show-rating-key",
            sourceID: "plex-test",
            sourceTypeRawValue: SourceType.plex.rawValue,
            addedAt: nil,
            year: nil,
            seasonNumber: nil,
            episodeNumber: nil
        )
    }

    private func makePlexEpisode(title: String,
                                 season: Int,
                                 episode: Int,
                                 progress: Double? = nil,
                                 isWatched: Bool = false) -> BrowseItem {
        let playback = PlaybackItem(
            path: "http://127.0.0.1/\(title)",
            displayName: title,
            resumeKey: "plex:test:\(title)",
            plexContext: PlexPlaybackContext(
                sourceId: "plex-test",
                serverBaseURL: "http://127.0.0.1:32400",
                authToken: "plex-token",
                ratingKey: "\(season)-\(episode)",
                key: "/library/metadata/\(season)-\(episode)",
                type: "episode",
                initialViewOffsetMs: progress == nil ? 0 : 120_000,
                initialViewCount: isWatched ? 1 : 0
            )
        )

        return BrowseItem(
            id: "plex:test:\(title)",
            kind: .episode,
            source: .plex,
            title: title,
            subtitle: "The Show • S\(season)E\(episode)",
            summary: nil,
            metadataLine: nil,
            badge: nil,
            artwork: BrowseArtwork(),
            progress: progress,
            isWatched: isWatched,
            sourceName: "Plex Test",
            playbackItem: playback,
            filePath: nil,
            ratingKey: "\(season)-\(episode)",
            plexKey: "/library/metadata/\(season)-\(episode)",
            sourceID: "plex-test",
            sourceTypeRawValue: SourceType.plex.rawValue,
            addedAt: nil,
            year: nil,
            seasonNumber: season,
            episodeNumber: episode
        )
    }

    private func makeSection(season: Int, items: [BrowseItem]) -> BrowseDetailSection {
        BrowseDetailSection(
            id: "season-\(season)",
            title: "Season \(season)",
            items: items
        )
    }
}
