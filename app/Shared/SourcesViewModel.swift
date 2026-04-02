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
    @Published private(set) var plexReconnectReasons: [String: String] = [:]
    @Published private(set) var sourcesRevision: UInt64 = 0

    let bridge: any SourceManagerBridgeProtocol
    private let configStore: any SourceConfigStore
    private let credentialStore: any SourceCredentialStore
    private var connectTask: Task<Void, Never>?
    private var browseTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var sessionPasswords: [String: String] = [:]
    private var pendingConnectionSourceId: String?
    private let missingPlexTokenMessage = "Plex token missing — reconnect the source"

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
        syncPlexReconnectState()
        sourcesRevision &+= 1
    }

    private func sourceConfig(for sourceId: String) -> SourceConfig? {
        sources.first(where: { $0.id == sourceId })
    }

    private func message(_ err: BridgeOperationError, fallback: String) -> String {
        err.message.isEmpty ? fallback : err.message
    }

    private func syncPlexReconnectState() {
        let plexSourceIDs = Set(sources.filter { $0.type == .plex }.map(\.id))
        plexReconnectReasons = plexReconnectReasons.filter { plexSourceIDs.contains($0.key) }

        for source in sources where isMissingPlexToken(source) {
            if plexReconnectReasons[source.id] == nil {
                plexReconnectReasons[source.id] = missingPlexTokenMessage
            }
        }
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

    private func resolvedCredential(for sourceId: String, override: String?) -> String {
        guard let config = sourceConfig(for: sourceId) else {
            return override ?? ""
        }

        if config.type == .plex {
            if let override, !override.isEmpty {
                return override
            }
            return config.authToken ?? ""
        }

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

    private func isMissingPlexToken(_ config: SourceConfig) -> Bool {
        config.type == .plex && (config.authToken?.isEmpty ?? true)
    }

    private func markPlexReconnectRequired(sourceId: String, reason: String? = nil) {
        if let config = sourceConfig(for: sourceId), config.type != .plex {
            return
        }
        plexReconnectReasons[sourceId] = reason?.isEmpty == false ? reason : missingPlexTokenMessage
    }

    private func clearPlexReconnectRequired(sourceId: String) {
        plexReconnectReasons.removeValue(forKey: sourceId)
    }

    private func isPlexReconnectError(sourceId: String, message: String) -> Bool {
        guard let config = sourceConfig(for: sourceId), config.type == .plex else { return false }
        let lowered = message.lowercased()
        return lowered.contains("reconnect the source") ||
            lowered.contains("authentication expired") ||
            lowered.contains("plex token missing")
    }

    private func persistCredential(for config: SourceConfig, password: String) {
        if config.type == .plex {
            credentialStore.delete(for: config.id)
            sessionPasswords.removeValue(forKey: config.id)
            return
        }

        guard !password.isEmpty else { return }
        _ = credentialStore.save(password: password, for: config.id)
        sessionPasswords[config.id] = password
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

        persistCredential(for: config, password: password)
        if isMissingPlexToken(config) {
            markPlexReconnectRequired(sourceId: config.id)
        } else {
            clearPlexReconnectRequired(sourceId: config.id)
        }
        refreshSourceList()
        saveSources()
        return true
    }

    func addSourceAndConnect(_ config: SourceConfig, password: String) {
        let sourceId = config.id
        if addSource(config, password: password) {
            connect(
                sourceId: sourceId,
                passwordOverride: config.type == .plex ? nil : password
            )
        }
    }

    func reconnectPlexSource(_ config: SourceConfig) {
        let needsReset = currentSourceId == config.id || pendingConnectionSourceId == config.id
        if needsReset {
            invalidatePendingRequests()
            isConnecting = false
            isLoading = false
            currentSourceId = nil
            currentEntries = []
            navigationPath = []
            navigationDisplayNames = []
        }

        bridge.disconnect(sourceId: config.id)
        bridge.removeSource(id: config.id)

        switch bridge.addSource(config) {
        case .success:
            persistCredential(for: config, password: "")
            clearPlexReconnectRequired(sourceId: config.id)
            refreshSourceList()
            saveSources()
            connect(sourceId: config.id, passwordOverride: nil)
        case .failure(let err):
            markPlexReconnectRequired(sourceId: config.id, reason: message(err, fallback: missingPlexTokenMessage))
            error = message(err, fallback: "Failed to reconnect Plex source")
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
        clearPlexReconnectRequired(sourceId: id)
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

    func openSourceRoot(sourceId: String) {
        if needsReconnect(sourceId: sourceId) {
            error = reconnectMessage(sourceId: sourceId) ?? missingPlexTokenMessage
            return
        }

        if isConnected(sourceId: sourceId) {
            currentSourceId = sourceId
            navigationPath = []
            navigationDisplayNames = []
            browse(sourceId: sourceId, relativePath: "")
        } else {
            connect(sourceId: sourceId)
        }
    }

    func connect(sourceId: String, passwordOverride: String?) {
        invalidatePendingRequests()

        if let config = sourceConfig(for: sourceId), isMissingPlexToken(config) {
            markPlexReconnectRequired(sourceId: sourceId)
            isConnecting = false
            isLoading = false
            error = missingPlexTokenMessage
            return
        }

        isConnecting = true
        isLoading = false
        error = nil

        let credential = resolvedCredential(for: sourceId, override: passwordOverride)
        let generation = nextRequestGeneration()
        pendingConnectionSourceId = sourceId
        let bridge = bridge

        connectTask = Task { [bridge] in
            let result = await Task.detached(priority: .userInitiated) {
                bridge.connect(sourceId: sourceId, password: credential)
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard generation == self.requestGeneration else { return }
                self.pendingConnectionSourceId = nil
                self.isConnecting = false

                switch result {
                case .success:
                    self.clearPlexReconnectRequired(sourceId: sourceId)
                    self.currentSourceId = sourceId
                    self.navigationPath = []
                    self.navigationDisplayNames = []
                    self.browse(sourceId: sourceId, relativePath: "")
                case .failure(let err):
                    let errorMessage = self.message(
                        err,
                        fallback: "Connection failed — check address and credentials"
                    )
                    if self.isPlexReconnectError(sourceId: sourceId, message: errorMessage) {
                        self.markPlexReconnectRequired(sourceId: sourceId, reason: errorMessage)
                    }
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
                    if self.isPlexReconnectError(sourceId: sourceId, message: bridgeError) {
                        self.markPlexReconnectRequired(sourceId: sourceId, reason: bridgeError)
                    }
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
                authToken: config.authToken ?? "",
                ratingKey: plex.ratingKey,
                key: plex.key,
                type: plex.type,
                initialViewOffsetMs: plex.viewOffsetMs,
                initialViewCount: plex.viewCount
            )
        )
    }

    func needsReconnect(sourceId: String) -> Bool {
        plexReconnectReasons[sourceId] != nil
    }

    func reconnectMessage(sourceId: String) -> String? {
        plexReconnectReasons[sourceId]
    }

    func handlePlexAuthFailures(_ sourceIds: Set<String>) {
        for sourceId in sourceIds {
            markPlexReconnectRequired(sourceId: sourceId,
                                      reason: "Authentication expired — reconnect the source")
        }
    }

    func handlePlexAuthFailure(sourceId: String) {
        handlePlexAuthFailures(Set([sourceId]))
    }

    func currentPlaybackItems() -> [PlaybackItem] {
        currentEntries
            .filter { !$0.isDirectory }
            .map(playbackItem(for:))
    }
}
