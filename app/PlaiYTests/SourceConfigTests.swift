import XCTest
@testable import PlaiY

final class SourceConfigTests: XCTestCase {

    // MARK: - SourceType

    func testSourceTypeDisplayNames() {
        XCTAssertEqual(SourceType.local.displayName, "Local Folder")
        XCTAssertEqual(SourceType.smb.displayName, "SMB / Windows Share")
        XCTAssertEqual(SourceType.nfs.displayName, "NFS")
        XCTAssertEqual(SourceType.http.displayName, "HTTP / HLS")
        XCTAssertEqual(SourceType.plex.displayName, "Plex")
    }

    func testSourceTypeSystemImages() {
        XCTAssertFalse(SourceType.local.systemImage.isEmpty)
        XCTAssertFalse(SourceType.smb.systemImage.isEmpty)
        XCTAssertFalse(SourceType.nfs.systemImage.isEmpty)
        XCTAssertFalse(SourceType.http.systemImage.isEmpty)
        XCTAssertFalse(SourceType.plex.systemImage.isEmpty)
    }

    func testSourceTypeJSONStrings() {
        XCTAssertEqual(SourceType.local.jsonString, "local")
        XCTAssertEqual(SourceType.smb.jsonString, "smb")
        XCTAssertEqual(SourceType.nfs.jsonString, "nfs")
        XCTAssertEqual(SourceType.http.jsonString, "http")
        XCTAssertEqual(SourceType.plex.jsonString, "plex")
    }

    func testSourceTypeAvailability() {
        #if os(tvOS)
        XCTAssertFalse(SourceType.local.isAvailable)
        #else
        XCTAssertTrue(SourceType.local.isAvailable)
        #endif
        XCTAssertEqual(SourceType.smb.isAvailable, SourceManagerBridge.isSourceTypeSupported(.smb))
        XCTAssertEqual(SourceType.nfs.isAvailable, SourceManagerBridge.isSourceTypeSupported(.nfs))
        XCTAssertEqual(SourceType.http.isAvailable, SourceManagerBridge.isSourceTypeSupported(.http))
        XCTAssertTrue(SourceType.plex.isAvailable)
    }

    func testSourceTypeRawValues() {
        XCTAssertEqual(SourceType.local.rawValue, 0)
        XCTAssertEqual(SourceType.smb.rawValue, 1)
        XCTAssertEqual(SourceType.nfs.rawValue, 2)
        XCTAssertEqual(SourceType.http.rawValue, 3)
        XCTAssertEqual(SourceType.plex.rawValue, 4)
    }

    // MARK: - SourceConfig

    func testSourceConfigInit() {
        let config = SourceConfig(
            displayName: "My NAS",
            type: .smb,
            baseURI: "smb://192.168.1.50/media",
            username: "admin"
        )
        XCTAssertFalse(config.id.isEmpty)  // Auto-generated UUID
        XCTAssertEqual(config.displayName, "My NAS")
        XCTAssertEqual(config.type, .smb)
        XCTAssertEqual(config.baseURI, "smb://192.168.1.50/media")
        XCTAssertEqual(config.username, "admin")
        XCTAssertNil(config.authToken)
    }

    func testSourceConfigDefaultUsername() {
        let config = SourceConfig(displayName: "Test", type: .local, baseURI: "/tmp")
        XCTAssertEqual(config.username, "")
    }

    func testSourceConfigJSONRoundtrip() throws {
        let original = SourceConfig(
            id: "test-uuid-123",
            displayName: "Test NAS",
            type: .smb,
            baseURI: "smb://10.0.0.1/videos",
            username: "user1"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SourceConfig.self, from: data)

        XCTAssertEqual(decoded.id, "test-uuid-123")
        XCTAssertEqual(decoded.displayName, "Test NAS")
        XCTAssertEqual(decoded.type, .smb)
        XCTAssertEqual(decoded.baseURI, "smb://10.0.0.1/videos")
        XCTAssertEqual(decoded.username, "user1")
        XCTAssertNil(decoded.authToken)
    }

    func testPlexSourceConfigRoundtripPreservesAuthToken() throws {
        let original = SourceConfig(
            id: "plex-source",
            displayName: "Plex",
            type: .plex,
            baseURI: "http://127.0.0.1:32400",
            authToken: "plex-token"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SourceConfig.self, from: data)

        XCTAssertEqual(decoded.type, .plex)
        XCTAssertEqual(decoded.authToken, "plex-token")
    }

    func testSourceConfigJSONKeys() throws {
        let config = SourceConfig(
            id: "abc",
            displayName: "D",
            type: .local,
            baseURI: "/tmp",
            username: "u"
        )
        let data = try JSONEncoder().encode(config)
        let json = String(data: data, encoding: .utf8)!

        // Verify snake_case keys from CodingKeys
        XCTAssertTrue(json.contains("\"source_id\""))
        XCTAssertTrue(json.contains("\"display_name\""))
        XCTAssertTrue(json.contains("\"base_uri\""))
    }

    // MARK: - SourceEntry

    func testSourceEntryFileSizeText() {
        let small = SourceEntry(name: "a.mkv", uri: "/a.mkv", isDirectory: false, size: 524_288_000)
        XCTAssertEqual(small.fileSizeText, "500 MB")

        let large = SourceEntry(name: "b.mkv", uri: "/b.mkv", isDirectory: false, size: 2_684_354_560)
        XCTAssertEqual(large.fileSizeText, "2.5 GB")

        let zero = SourceEntry(name: "c.mkv", uri: "/c.mkv", isDirectory: false, size: 0)
        XCTAssertEqual(zero.fileSizeText, "")
    }

    func testSourceEntryId() {
        let entry = SourceEntry(name: "test", uri: "/path/test", isDirectory: false, size: 0)
        XCTAssertEqual(entry.id, "/path/test")
    }

    // MARK: - KeychainHelper

    func testKeychainSaveAndRetrieve() {
        let service = "com.plaiy.tests.\(UUID().uuidString)"
        let testId = "test-keychain-\(UUID().uuidString)"
        defer { KeychainHelper.delete(for: testId, service: service) }

        let saved = KeychainHelper.save(password: "mypassword", for: testId, service: service)
        XCTAssertTrue(saved)

        let retrieved = KeychainHelper.password(for: testId, service: service)
        XCTAssertEqual(retrieved, "mypassword")
    }

    func testKeychainOverwrite() {
        let service = "com.plaiy.tests.\(UUID().uuidString)"
        let testId = "test-overwrite-\(UUID().uuidString)"
        defer { KeychainHelper.delete(for: testId, service: service) }

        _ = KeychainHelper.save(password: "first", for: testId, service: service)
        _ = KeychainHelper.save(password: "second", for: testId, service: service)

        XCTAssertEqual(KeychainHelper.password(for: testId, service: service), "second")
    }

    func testKeychainDelete() {
        let service = "com.plaiy.tests.\(UUID().uuidString)"
        let testId = "test-delete-\(UUID().uuidString)"

        _ = KeychainHelper.save(password: "temp", for: testId, service: service)
        XCTAssertNotNil(KeychainHelper.password(for: testId, service: service))

        KeychainHelper.delete(for: testId, service: service)
        XCTAssertNil(KeychainHelper.password(for: testId, service: service))
    }

    func testKeychainNonexistentReturnsNil() {
        let service = "com.plaiy.tests.\(UUID().uuidString)"
        XCTAssertNil(KeychainHelper.password(for: "nonexistent-\(UUID().uuidString)", service: service))
    }
}
