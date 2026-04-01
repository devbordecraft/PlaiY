import XCTest
@testable import PlaiY

final class BrowsePersistenceTests: XCTestCase {

    private func makeDefaults(suite: String = "com.plaiy.tests.\(UUID().uuidString)") -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testHomeLayoutStoreReturnsDefaultWhenEmpty() {
        let defaults = makeDefaults()
        let store = UserDefaultsHomeLayoutStore(defaults: defaults, key: "layout")

        XCTAssertEqual(store.load(), .default)
    }

    func testHomeLayoutStoreRoundtripPersistsShelvesAndPins() {
        let defaults = makeDefaults()
        let store = UserDefaultsHomeLayoutStore(defaults: defaults, key: "layout")
        let state = HomeLayoutState(
            shelves: [
                HomeShelfConfiguration(kind: .favorites, isVisible: true),
                HomeShelfConfiguration(kind: .continueWatching, isVisible: false)
            ],
            pins: [
                PinnedDestination(
                    id: "source:test",
                    kind: .source,
                    reference: "test",
                    title: "NAS",
                    subtitle: "smb://nas/media",
                    sourceTypeRawValue: SourceType.smb.rawValue,
                    baseURI: "smb://nas/media"
                )
            ]
        )

        store.save(state)

        XCTAssertEqual(store.load(), state)
    }

    func testFavoritesStoreRoundtripPersistsEntries() {
        let defaults = makeDefaults()
        let store = UserDefaultsFavoritesStore(defaults: defaults, key: "favorites")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            FavoriteEntry(
                id: "local:file:/movies/alien.mkv",
                title: "Alien (1979)",
                subtitle: "1:57:00",
                kind: BrowseItemKind.movie.rawValue,
                createdAt: createdAt
            )
        ]

        store.save(entries)

        XCTAssertEqual(store.load(), entries)
    }

    func testWatchStatusStoreRoundtripPersistsIDs() {
        let defaults = makeDefaults()
        let store = UserDefaultsWatchStatusStore(defaults: defaults, key: "watched")
        let watched: Set<String> = [
            "local:file:/movies/blade-runner.mkv",
            "local:file:/shows/dark/s01e01.mkv"
        ]

        store.save(watched)

        XCTAssertEqual(store.load(), watched)
    }
}
