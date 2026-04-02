import XCTest
@testable import PlaiY

private final class InMemorySourceConfigStore: SourceConfigStore {
    var storedJSON: String?

    init(storedJSON: String? = nil) {
        self.storedJSON = storedJSON
    }

    func load() -> String? {
        storedJSON
    }

    func save(_ json: String) {
        storedJSON = json
    }
}

private final class InMemoryCredentialStore: SourceCredentialStore {
    var passwords: [String: String] = [:]
    private(set) var passwordReadCount = 0

    @discardableResult
    func save(password: String, for sourceId: String) -> Bool {
        passwords[sourceId] = password
        return true
    }

    func password(for sourceId: String) -> String? {
        passwordReadCount += 1
        return passwords[sourceId]
    }

    func delete(for sourceId: String) {
        passwords.removeValue(forKey: sourceId)
    }
}

private final class MockSourceManagerBridge: SourceManagerBridgeProtocol, @unchecked Sendable {
    var configs: [SourceConfig] = []
    var connectDelay: TimeInterval = 0
    var connectResult: Result<Void, BridgeOperationError> = .success(())
    var directoryEntries: [SourceEntry] = []
    var lastErrorMessage = ""

    private(set) var connectCallCount = 0
    private(set) var listDirectoryCallCount = 0
    private(set) var disconnectedSourceIds: [String] = []
    private(set) var lastConnectPassword: String?

    func lastError() -> String {
        lastErrorMessage
    }

    func addSource(_ config: SourceConfig) -> Result<Void, BridgeOperationError> {
        guard !configs.contains(where: { $0.id == config.id }) else {
            return .failure(
                BridgeOperationError(
                    operation: "addSource",
                    code: Int32(PY_ERROR_INVALID_ARG.rawValue),
                    message: "Duplicate source"
                )
            )
        }
        configs.append(config)
        return .success(())
    }

    func removeSource(id: String) {
        configs.removeAll { $0.id == id }
    }

    var sourceCount: Int32 {
        Int32(configs.count)
    }

    func configJSON(at index: Int32) -> String {
        guard configs.indices.contains(Int(index)),
              let data = try? JSONEncoder().encode(configs[Int(index)]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    func allConfigsJSON() -> String {
        guard let data = try? JSONEncoder().encode(configs),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    func loadConfigsJSON(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([SourceConfig].self, from: data) else {
            return false
        }
        configs = decoded
        return true
    }

    func connect(sourceId: String, password: String) -> Result<Void, BridgeOperationError> {
        connectCallCount += 1
        lastConnectPassword = password
        if connectDelay > 0 {
            Thread.sleep(forTimeInterval: connectDelay)
        }
        return connectResult
    }

    func disconnect(sourceId: String) {
        disconnectedSourceIds.append(sourceId)
    }

    func isConnected(sourceId: String) -> Bool {
        false
    }

    func listDirectory(sourceId: String, relativePath: String) -> [SourceEntry] {
        listDirectoryCallCount += 1
        return directoryEntries
    }

    func playablePath(sourceId: String, entryURI: String) -> String {
        entryURI
    }
}

@MainActor
final class SourcesViewModelTests: XCTestCase {
    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testAddSourceAndConnectDoesNotConnectWhenAddFails() {
        let store = InMemorySourceConfigStore()
        let creds = InMemoryCredentialStore()
        let vm = SourcesViewModel(
            bridge: SourceManagerBridge(),
            configStore: store,
            credentialStore: creds
        )
        let config = SourceConfig(
            id: "dup-source-id",
            displayName: "Duplicate",
            type: .local,
            baseURI: "/tmp"
        )

        XCTAssertTrue(vm.addSource(config, password: ""))
        vm.addSourceAndConnect(config, password: "")

        XCTAssertNil(vm.currentSourceId)
        XCTAssertNotNil(vm.error)
    }

    func testAddSourceAndConnectUsesProvidedPasswordWithoutCredentialLookup() async throws {
        let store = InMemorySourceConfigStore()
        let creds = InMemoryCredentialStore()
        let vm = SourcesViewModel(
            bridge: SourceManagerBridge(),
            configStore: store,
            credentialStore: creds
        )
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        let fileURL = rootURL.appendingPathComponent("movie.mkv")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)

        let config = SourceConfig(
            id: "local-connect",
            displayName: "Local Test",
            type: .local,
            baseURI: rootURL.path
        )

        vm.addSourceAndConnect(config, password: "secret-token")
        await waitUntil {
            vm.currentSourceId == config.id && !vm.isConnecting && !vm.isLoading
        }

        XCTAssertEqual(vm.currentSourceId, config.id)
        XCTAssertEqual(vm.currentEntries.count, 1)
        XCTAssertEqual(creds.passwordReadCount, 0)
    }

    func testLoadAndSaveUseInjectedStore() {
        let seeded = """
        [{"source_id":"seed-1","display_name":"Seed","type":"local","base_uri":"/tmp","username":""}]
        """
        let store = InMemorySourceConfigStore(storedJSON: seeded)
        let creds = InMemoryCredentialStore()
        let vm = SourcesViewModel(
            bridge: SourceManagerBridge(),
            configStore: store,
            credentialStore: creds
        )

        vm.loadSavedSources()
        XCTAssertEqual(vm.sources.count, 1)
        XCTAssertEqual(vm.sources.first?.id, "seed-1")

        let newConfig = SourceConfig(
            id: "seed-2",
            displayName: "Second",
            type: .local,
            baseURI: "/tmp"
        )
        XCTAssertTrue(vm.addSource(newConfig, password: "secret"))
        XCTAssertNotNil(store.storedJSON)
        XCTAssertEqual(creds.password(for: "seed-2"), "secret")
    }

    func testLoadSavedPlexWithoutAuthTokenMarksReconnect() {
        let seeded = """
        [{"source_id":"plex-1","display_name":"Plex","type":"plex","base_uri":"http://127.0.0.1:32400","username":""}]
        """
        let store = InMemorySourceConfigStore(storedJSON: seeded)
        let vm = SourcesViewModel(
            bridge: MockSourceManagerBridge(),
            configStore: store,
            credentialStore: InMemoryCredentialStore()
        )

        vm.loadSavedSources()

        XCTAssertEqual(vm.sources.count, 1)
        XCTAssertTrue(vm.needsReconnect(sourceId: "plex-1"))
    }

    func testPlexConnectUsesStoredTokenWithoutCredentialLookup() async {
        let store = InMemorySourceConfigStore()
        let creds = InMemoryCredentialStore()
        let bridge = MockSourceManagerBridge()
        let vm = SourcesViewModel(
            bridge: bridge,
            configStore: store,
            credentialStore: creds
        )
        let config = SourceConfig(
            id: "plex-source",
            displayName: "Plex",
            type: .plex,
            baseURI: "http://127.0.0.1:32400",
            authToken: "plex-token"
        )

        XCTAssertTrue(vm.addSource(config, password: "plex-token"))
        vm.connect(sourceId: config.id)
        await waitUntil {
            !vm.isConnecting
        }

        XCTAssertEqual(creds.passwordReadCount, 0)
        XCTAssertNil(creds.passwords[config.id])
        XCTAssertEqual(bridge.lastConnectPassword, "plex-token")
        XCTAssertFalse(vm.needsReconnect(sourceId: config.id))
    }

    func testConnectFailureMarksPlexForReconnect() async {
        let store = InMemorySourceConfigStore()
        let creds = InMemoryCredentialStore()
        let bridge = MockSourceManagerBridge()
        bridge.connectResult = .failure(
            BridgeOperationError(
                operation: "connect",
                code: Int32(PY_ERROR_NETWORK.rawValue),
                message: "Authentication expired — reconnect the source"
            )
        )
        let vm = SourcesViewModel(
            bridge: bridge,
            configStore: store,
            credentialStore: creds
        )
        let config = SourceConfig(
            id: "plex-source",
            displayName: "Plex",
            type: .plex,
            baseURI: "http://127.0.0.1:32400",
            authToken: "plex-token"
        )

        XCTAssertTrue(vm.addSource(config, password: ""))
        vm.connect(sourceId: config.id)
        await waitUntil {
            !vm.isConnecting
        }

        XCTAssertTrue(vm.needsReconnect(sourceId: config.id))
        XCTAssertEqual(creds.passwordReadCount, 0)
    }

    func testRemoveSourceCancelsPendingConnectBeforeBrowseStarts() async {
        let store = InMemorySourceConfigStore()
        let creds = InMemoryCredentialStore()
        let bridge = MockSourceManagerBridge()
        bridge.connectDelay = 0.15
        bridge.directoryEntries = [
            SourceEntry(name: "movie.mkv", uri: "movie.mkv", isDirectory: false, size: 1)
        ]
        let vm = SourcesViewModel(
            bridge: bridge,
            configStore: store,
            credentialStore: creds
        )
        let config = SourceConfig(
            id: "pending-connect",
            displayName: "Pending",
            type: .local,
            baseURI: "/tmp"
        )

        XCTAssertTrue(vm.addSource(config, password: ""))
        vm.connect(sourceId: config.id)
        XCTAssertTrue(vm.isConnecting)
        XCTAssertNil(vm.currentSourceId)

        vm.removeSource(id: config.id)
        await waitUntil {
            !vm.isConnecting && vm.sources.isEmpty
        }

        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(vm.currentSourceId)
        XCTAssertTrue(vm.currentEntries.isEmpty)
        XCTAssertTrue(vm.navigationPath.isEmpty)
        XCTAssertEqual(bridge.connectCallCount, 1)
        XCTAssertEqual(bridge.listDirectoryCallCount, 0)
        XCTAssertEqual(bridge.disconnectedSourceIds, [config.id])
    }
}
