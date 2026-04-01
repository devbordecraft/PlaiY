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

    let bridge: any SourceManagerBridgeProtocol
    private let configStore: any SourceConfigStore
    private let credentialStore: any SourceCredentialStore
    private var connectTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var sessionPasswords: [String: String] = [:]
    private var pendingConnectionSourceId: String?

    init(
        bridge: any SourceManagerBridgeProtocol = SourceManagerBridge(),
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

    private func sourceConfig(for sourceId: String) -> SourceConfig? {
        sources.first(where: { $0.id == sourceId })
    }

    private func message(_ err: BridgeOperationError, fallback: String) -> String {
        err.message.isEmpty ? fallback : err.message
    }

    private func nextRequestGeneration() -> Int {
        requestGeneration += 1
        return requestGeneration
    }

    private func invalidatePendingRequests() {
        requestGeneration += 1
        pendingConnectionSourceId = nil
        connectTask?.cancel()
        connectTask = nil
        browseTask?.cancel()
        browseTask = nil
    }

    private func resolvedPassword(for sourceId: String, override: String?) -> String {
        if let override {
            if !override.isEmpty {
                sessionPasswords[sourceId] = override
            }
            return override
        }

        if let cached = sessionPasswords[sourceId] {
            return cached
        }

        let password = credentialStore.password(for: sourceId) ?? ""
        if !password.isEmpty {
            sessionPasswords[sourceId] = password
        }
        return password
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
            sessionPasswords[config.id] = password
        }
        refreshSourceList()
        saveSources()
        return true
    }

    func addSourceAndConnect(_ config: SourceConfig, password: String) {
        let sourceId = config.id
        if addSource(config, password: password) {
            connect(sourceId: sourceId, passwordOverride: password)
        }
    }

    func removeSource(id: String) {
        let needsReset = currentSourceId == id || pendingConnectionSourceId == id
        if needsReset {
            invalidatePendingRequests()
            isConnecting = false
            isLoading = false
        }
        bridge.disconnect(sourceId: id)
        bridge.removeSource(id: id)
        credentialStore.delete(for: id)
        sessionPasswords.removeValue(forKey: id)
        refreshSourceList()
        saveSources()

        if needsReset {
            currentSourceId = nil
            currentEntries = []
            navigationPath = []
            navigationDisplayNames = []
        }
    }

    // MARK: - Connection

    func connect(sourceId: String) {
        connect(sourceId: sourceId, passwordOverride: nil)
    }

    func connect(sourceId: String, passwordOverride: String?) {
        invalidatePendingRequests()
        isConnecting = true
        isLoading = false
        error = nil

        let password = resolvedPassword(for: sourceId, override: passwordOverride)
        let generation = nextRequestGeneration()
        pendingConnectionSourceId = sourceId
        let bridge = bridge

        connectTask = Task { [bridge] in
            let result = await Task.detached(priority: .userInitiated) {
                bridge.connect(sourceId: sourceId, password: password)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard generation == self.requestGeneration else { return }
                self.pendingConnectionSourceId = nil
                self.isConnecting = false

                switch result {
                case .success:
                    self.currentSourceId = sourceId
                    self.navigationPath = []
                    self.navigationDisplayNames = []
                    self.browse(sourceId: sourceId, relativePath: "")
                case .failure(let err):
                    self.error = self.message(
                        err,
                        fallback: "Connection failed — check address and credentials"
                    )
                }
            }
        }
    }

    func disconnect(sourceId: String) {
        let needsReset = currentSourceId == sourceId || pendingConnectionSourceId == sourceId
        if needsReset {
            invalidatePendingRequests()
            isConnecting = false
            isLoading = false
        }
        bridge.disconnect(sourceId: sourceId)
        if needsReset {
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
        browseTask?.cancel()
        isLoading = true
        error = nil
        let generation = nextRequestGeneration()
        let bridge = bridge

        browseTask = Task { [bridge] in
            let entries = await Task.detached(priority: .userInitiated) {
                bridge.listDirectory(sourceId: sourceId, relativePath: relativePath)
            }.value
            let bridgeError = entries.isEmpty
                ? await Task.detached(priority: .userInitiated) {
                    bridge.lastError()
                }.value
                : ""

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard generation == self.requestGeneration else { return }
                self.isLoading = false
                self.currentEntries = entries

                if !bridgeError.isEmpty {
                    self.error = bridgeError
                }
            }
        }
    }

    func navigateInto(_ entry: SourceEntry) {
        guard let sourceId = currentSourceId, entry.isDirectory else { return }

        if let config = sourceConfig(for: sourceId) {
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

        if let config = sourceConfig(for: sourceId) {
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

    func playbackItem(for entry: SourceEntry) -> PlaybackItem {
        let path = playablePath(for: entry)

        guard let sourceId = currentSourceId,
              let config = sourceConfig(for: sourceId),
              config.type == .plex,
              let plex = entry.plex else {
            return .local(path: path, displayName: entry.name)
        }

        return PlaybackItem(
            path: path,
            displayName: entry.name,
            resumeKey: "plex:\(sourceId):\(plex.ratingKey)",
            plexContext: PlexPlaybackContext(
                sourceId: sourceId,
                serverBaseURL: config.baseURI,
                ratingKey: plex.ratingKey,
                key: plex.key,
                type: plex.type,
                initialViewOffsetMs: plex.viewOffsetMs,
                initialViewCount: plex.viewCount
            )
        )
    }

    func currentPlaybackItems() -> [PlaybackItem] {
        currentEntries
            .filter { !$0.isDirectory }
            .map(playbackItem(for:))
    }
}
