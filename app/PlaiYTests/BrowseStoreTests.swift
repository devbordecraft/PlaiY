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
}
