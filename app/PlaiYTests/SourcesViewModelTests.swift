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

    @discardableResult
    func save(password: String, for sourceId: String) -> Bool {
        passwords[sourceId] = password
        return true
    }

    func password(for sourceId: String) -> String? {
        passwords[sourceId]
    }

    func delete(for sourceId: String) {
        passwords.removeValue(forKey: sourceId)
    }
}

@MainActor
final class SourcesViewModelTests: XCTestCase {
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
}
