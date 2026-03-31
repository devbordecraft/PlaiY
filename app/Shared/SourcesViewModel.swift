import Foundation

protocol SourceConfigStore {
    func load() -> String?
    func save(_ json: String)
}

struct UserDefaultsSourceConfigStore: SourceConfigStore {
    private let defaults: UserDefaults
    private let key: String

    private static func defaultDefaults() -> UserDefaults {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return UserDefaults(suiteName: "com.plaiy.tests.sources") ?? .standard
        }
        return .standard
    }

    init(defaults: UserDefaults = defaultDefaults(), key: String = "savedSourceConfigs") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> String? {
        defaults.string(forKey: key)
    }

    func save(_ json: String) {
        defaults.set(json, forKey: key)
    }
}

protocol SourceCredentialStore {
    @discardableResult
    func save(password: String, for sourceId: String) -> Bool
    func password(for sourceId: String) -> String?
    func delete(for sourceId: String)
}

struct KeychainCredentialStore: SourceCredentialStore {
    private let service: String?

    init(service: String? = nil) {
        self.service = service
    }

    @discardableResult
    func save(password: String, for sourceId: String) -> Bool {
        KeychainHelper.save(password: password, for: sourceId, service: service)
    }

    func password(for sourceId: String) -> String? {
        KeychainHelper.password(for: sourceId, service: service)
    }

    func delete(for sourceId: String) {
        KeychainHelper.delete(for: sourceId, service: service)
    }
}

@MainActor
class SourcesViewModel: ObservableObject {
    @Published var sources: [SourceConfig] = []
    @Published var currentEntries: [SourceEntry] = []
    @Published var navigationPath: [String] = []
    @Published var navigationDisplayNames: [String] = []
    @Published var currentSourceId: String?
    @Published var isLoading = false
    @Published var isConnecting = false
    @Published var error: String?

    let bridge: SourceManagerBridge
    private let configStore: any SourceConfigStore
    private let credentialStore: any SourceCredentialStore

    init(
        bridge: SourceManagerBridge = SourceManagerBridge(),
        configStore: any SourceConfigStore = UserDefaultsSourceConfigStore(),
        credentialStore: any SourceCredentialStore = KeychainCredentialStore()
    ) {
        self.bridge = bridge
        self.configStore = configStore
        self.credentialStore = credentialStore
    }

    // MARK: - Lifecycle

    func loadSavedSources() {
        guard let jsonStr = configStore.load(), !jsonStr.isEmpty else { return }

        if bridge.loadConfigsJSON(jsonStr) {
            refreshSourceList()
        } else {
            error = "Failed to load saved sources"
        }
    }

    private func saveSources() {
        configStore.save(bridge.allConfigsJSON())
    }

    private func refreshSourceList() {
        let json = bridge.allConfigsJSON()
        guard let data = json.data(using: .utf8) else { return }
        sources = (try? JSONDecoder().decode([SourceConfig].self, from: data)) ?? []
    }

    private func message(_ err: BridgeOperationError, fallback: String) -> String {
        err.message.isEmpty ? fallback : err.message
    }

    // MARK: - Source CRUD

    @discardableResult
    func addSource(_ config: SourceConfig, password: String) -> Bool {
        switch bridge.addSource(config) {
        case .success:
            break
        case .failure(let err):
            error = message(err, fallback: "Failed to add source")
            return false
        }

        if !password.isEmpty {
            _ = credentialStore.save(password: password, for: config.id)
        }
        refreshSourceList()
        saveSources()
        return true
    }

    func addSourceAndConnect(_ config: SourceConfig, password: String) {
        let sourceId = config.id
        if addSource(config, password: password) {
            connect(sourceId: sourceId)
        }
    }

    func removeSource(id: String) {
        bridge.disconnect(sourceId: id)
        bridge.removeSource(id: id)
        credentialStore.delete(for: id)
        refreshSourceList()
        saveSources()

        if currentSourceId == id {
            currentSourceId = nil
            currentEntries = []
            navigationPath = []
            navigationDisplayNames = []
        }
    }

    // MARK: - Connection

    func connect(sourceId: String) {
        isConnecting = true
        error = nil

        let password = credentialStore.password(for: sourceId) ?? ""
        let result = bridge.connect(sourceId: sourceId, password: password)

        isConnecting = false
        switch result {
        case .success:
            currentSourceId = sourceId
            navigationPath = []
            navigationDisplayNames = []
            browse(sourceId: sourceId, relativePath: "")
        case .failure(let err):
            error = message(err, fallback: "Connection failed — check address and credentials")
        }
    }

    func disconnect(sourceId: String) {
        bridge.disconnect(sourceId: sourceId)
        if currentSourceId == sourceId {
            currentSourceId = nil
            currentEntries = []
            navigationPath = []
            navigationDisplayNames = []
        }
    }

    func isConnected(sourceId: String) -> Bool {
        bridge.isConnected(sourceId: sourceId)
    }

    // MARK: - Browsing

    func browse(sourceId: String, relativePath: String) {
        isLoading = true
        error = nil

        let entries = bridge.listDirectory(sourceId: sourceId, relativePath: relativePath)
        isLoading = false
        currentEntries = entries

        if entries.isEmpty {
            let bridgeError = bridge.lastError()
            if !bridgeError.isEmpty {
                error = bridgeError
            }
        }
    }

    func navigateInto(_ entry: SourceEntry) {
        guard let sourceId = currentSourceId, entry.isDirectory else { return }

        if let config = sources.first(where: { $0.id == sourceId }) {
            let newPath: String
            if config.type == .plex {
                // Plex: entry.uri contains the structured navigation key
                navigationPath.append(entry.uri)
                newPath = entry.uri
            } else {
                // Filesystem sources: build path from name components
                navigationPath.append(entry.name)
                newPath = navigationPath.joined(separator: "/")
            }
            navigationDisplayNames.append(entry.name)
            browse(sourceId: sourceId, relativePath: newPath)
        }
    }

    func navigateUp() {
        guard let sourceId = currentSourceId, !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
        navigationDisplayNames.removeLast()

        if let config = sources.first(where: { $0.id == sourceId }) {
            let path: String
            if config.type == .plex {
                path = navigationPath.last ?? ""
            } else {
                path = navigationPath.joined(separator: "/")
            }
            browse(sourceId: sourceId, relativePath: path)
        }
    }

    func navigateToRoot() {
        guard let sourceId = currentSourceId else { return }
        navigationPath = []
        navigationDisplayNames = []
        browse(sourceId: sourceId, relativePath: "")
    }

    func playablePath(for entry: SourceEntry) -> String {
        guard let sourceId = currentSourceId else { return entry.uri }
        let path = bridge.playablePath(sourceId: sourceId, entryURI: entry.uri)
        return path.isEmpty ? entry.uri : path
    }
}
