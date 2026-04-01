import Foundation

struct UserDefaultsHomeLayoutStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    private static func defaultDefaults() -> UserDefaults {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return UserDefaults(suiteName: "com.plaiy.tests.browse-layout") ?? .standard
        }
        return .standard
    }

    init(defaults: UserDefaults = defaultDefaults(), key: String = "browse.homeLayout") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> HomeLayoutState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(HomeLayoutState.self, from: data) else {
            return .default
        }
        return state
    }

    func save(_ state: HomeLayoutState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

struct UserDefaultsFavoritesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    private static func defaultDefaults() -> UserDefaults {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return UserDefaults(suiteName: "com.plaiy.tests.favorites") ?? .standard
        }
        return .standard
    }

    init(defaults: UserDefaults = defaultDefaults(), key: String = "browse.favorites") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [FavoriteEntry] {
        guard let data = defaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([FavoriteEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func save(_ favorites: [FavoriteEntry]) {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: key)
    }
}

struct UserDefaultsWatchStatusStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    private static func defaultDefaults() -> UserDefaults {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return UserDefaults(suiteName: "com.plaiy.tests.watch-status") ?? .standard
        }
        return .standard
    }

    init(defaults: UserDefaults = defaultDefaults(), key: String = "browse.watched") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func save(_ ids: Set<String>) {
        defaults.set(Array(ids).sorted(), forKey: key)
    }
}
