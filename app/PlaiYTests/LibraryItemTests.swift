import XCTest
@testable import PlaiY

private typealias AppLibraryItem = PlaiY.LibraryItem

private final class MockLibraryBridge: LibraryBridgeProtocol, @unchecked Sendable {
    var folderPaths: [String] = []
    var items: [AppLibraryItem] = []
    var addResults: [String: Result<Void, LibraryBridgeError>] = [:]
    var onNextFolderCountRead: (() -> Void)?

    var itemCount: Int32 { Int32(items.count) }
    var folderCount: Int32 {
        if let hook = onNextFolderCountRead {
            onNextFolderCountRead = nil
            hook()
        }
        return Int32(folderPaths.count)
    }

    func addFolder(_ path: String) -> Result<Void, LibraryBridgeError> {
        let result = addResults[path] ?? .success(())
        if case .success = result, !folderPaths.contains(path) {
            folderPaths.append(path)
        }
        return result
    }

    func removeFolder(at index: Int32) -> Bool {
        guard index >= 0, index < Int32(folderPaths.count) else { return false }
        folderPaths.remove(at: Int(index))
        return true
    }

    func itemJSON(at index: Int32) -> String {
        guard index >= 0, index < Int32(items.count),
              let data = try? JSONEncoder().encode(items[Int(index)]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    func allItemsJSON() -> String {
        guard let data = try? JSONEncoder().encode(items),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    func folder(at index: Int32) -> String {
        guard index >= 0, index < Int32(folderPaths.count) else { return "" }
        return folderPaths[Int(index)]
    }
}

private final class InMemoryLibraryFolderStore: LibraryFolderStore, @unchecked Sendable {
    var storedFolders: [SavedLibraryFolder]

    init(storedFolders: [SavedLibraryFolder] = []) {
        self.storedFolders = storedFolders
    }

    convenience init(storedPaths: [String]) {
        self.init(storedFolders: storedPaths.map {
            SavedLibraryFolder(path: $0, bookmarkData: nil)
        })
    }

    var storedPaths: [String] {
        storedFolders.map(\.path)
    }

    func load() -> [SavedLibraryFolder] {
        storedFolders
    }

    func save(_ folders: [SavedLibraryFolder]) {
        storedFolders = folders
    }
}

final class LibraryItemTests: XCTestCase {

    private func makeItem(
        width: Int = 1920, height: Int = 1080,
        hdrType: Int = 0, fileSize: Int64 = 0,
        durationUs: Int64 = 0
    ) -> AppLibraryItem {
        AppLibraryItem(
            filePath: "/test/video.mkv",
            title: "Test",
            durationUs: durationUs,
            videoWidth: width,
            videoHeight: height,
            videoCodec: "hevc",
            audioCodec: "aac",
            hdrType: hdrType,
            fileSize: fileSize
        )
    }

    // MARK: - resolutionText

    func testResolution4K() {
        XCTAssertEqual(makeItem(width: 3840, height: 2160).resolutionText, "4K")
    }

    func testResolution1080p() {
        XCTAssertEqual(makeItem(width: 1920, height: 1080).resolutionText, "1080p")
    }

    func testResolution720p() {
        XCTAssertEqual(makeItem(width: 1280, height: 720).resolutionText, "720p")
    }

    func testResolutionCustom() {
        XCTAssertEqual(makeItem(width: 640, height: 480).resolutionText, "640x480")
    }

    func testResolutionZero() {
        XCTAssertEqual(makeItem(width: 0, height: 0).resolutionText, "")
    }

    // MARK: - hdrText

    func testHdrSDR() {
        XCTAssertEqual(makeItem(hdrType: 0).hdrText, "")
    }

    func testHdrHDR10() {
        XCTAssertEqual(makeItem(hdrType: 1).hdrText, "HDR10")
    }

    func testHdrHDR10Plus() {
        XCTAssertEqual(makeItem(hdrType: 2).hdrText, "HDR10+")
    }

    func testHdrHLG() {
        XCTAssertEqual(makeItem(hdrType: 3).hdrText, "HLG")
    }

    func testHdrDV() {
        XCTAssertEqual(makeItem(hdrType: 4).hdrText, "DV")
    }

    // MARK: - fileSizeText

    func testFileSizeGB() {
        // 2.5 GB
        let size: Int64 = 2_684_354_560
        XCTAssertEqual(makeItem(fileSize: size).fileSizeText, "2.5 GB")
    }

    func testFileSizeMB() {
        // 500 MB
        let size: Int64 = 524_288_000
        XCTAssertEqual(makeItem(fileSize: size).fileSizeText, "500 MB")
    }

    func testFileSizeExactlyOneGB() {
        let size: Int64 = 1_073_741_824
        XCTAssertEqual(makeItem(fileSize: size).fileSizeText, "1.0 GB")
    }

    // MARK: - durationText

    func testDurationText() {
        // 1 hour 30 minutes
        let item = makeItem(durationUs: 5_400_000_000)
        XCTAssertEqual(item.durationText, "1:30:00")
    }

    // MARK: - JSON decoding

    func testJSONDecoding() throws {
        let json = """
        {
            "file_path": "/test/movie.mkv",
            "title": "Movie",
            "duration_us": 7200000000,
            "video_width": 3840,
            "video_height": 2160,
            "video_codec": "hevc",
            "audio_codec": "eac3",
            "hdr_type": 4,
            "file_size": 5368709120
        }
        """
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(AppLibraryItem.self, from: data)
        XCTAssertEqual(item.filePath, "/test/movie.mkv")
        XCTAssertEqual(item.title, "Movie")
        XCTAssertEqual(item.videoWidth, 3840)
        XCTAssertEqual(item.hdrType, 4)
        XCTAssertEqual(item.resolutionText, "4K")
        XCTAssertEqual(item.hdrText, "DV")
    }
}

@MainActor
final class LibraryViewModelPersistenceTests: XCTestCase {
    private func makeItem(path: String = "/test/video.mkv") -> AppLibraryItem {
        AppLibraryItem(
            filePath: path,
            title: "Test",
            durationUs: 0,
            videoWidth: 1920,
            videoHeight: 1080,
            videoCodec: "hevc",
            audioCodec: "aac",
            hdrType: 0,
            fileSize: 0
        )
    }

    private func waitForCondition(
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) {
        let exp = expectation(description: "condition met")

        func poll(deadline: Date) {
            Task { @MainActor in
                if condition() {
                    exp.fulfill()
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                        poll(deadline: deadline)
                    }
                }
            }
        }

        poll(deadline: Date().addingTimeInterval(timeout))
        wait(for: [exp], timeout: timeout + 0.1)
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testRestoreSavedFoldersLoadsPersistedFoldersOnLaunch() {
        let bridge = MockLibraryBridge()
        bridge.items = [makeItem(path: "/movies/feature.mkv")]
        let store = InMemoryLibraryFolderStore(storedPaths: ["/movies", "/shows"])
        let viewModel = LibraryViewModel(bridge: bridge, folderStore: store)

        viewModel.restoreSavedFolders()

        waitForCondition {
            viewModel.folders == ["/movies", "/shows"] && !viewModel.isScanning
        }

        XCTAssertEqual(store.storedPaths, ["/movies", "/shows"])
        XCTAssertEqual(viewModel.items.count, 1)
        XCTAssertEqual(bridge.folderPaths, ["/movies", "/shows"])
    }

    func testRestoreSavedFoldersDropsMissingFoldersFromPersistence() {
        let bridge = MockLibraryBridge()
        bridge.addResults["/missing"] = .failure(
            LibraryBridgeError(
                operation: "addFolder",
                code: Int32(PY_ERROR_FILE_NOT_FOUND.rawValue),
                message: ""
            )
        )
        let store = InMemoryLibraryFolderStore(storedPaths: ["/missing", "/movies"])
        let viewModel = LibraryViewModel(bridge: bridge, folderStore: store)

        viewModel.restoreSavedFolders()

        waitForCondition {
            viewModel.folders == ["/movies"] && !viewModel.isScanning
        }

        XCTAssertEqual(store.storedPaths, ["/movies"])
        XCTAssertEqual(bridge.folderPaths, ["/movies"])
    }

    func testRestoreSavedFoldersKeepsNonMissingFailuresPersisted() {
        let bridge = MockLibraryBridge()
        bridge.addResults["/denied"] = .failure(
            LibraryBridgeError(
                operation: "addFolder",
                code: Int32(PY_ERROR_INVALID_ARG.rawValue),
                message: "Permission denied"
            )
        )
        let store = InMemoryLibraryFolderStore(storedPaths: ["/denied", "/movies"])
        let viewModel = LibraryViewModel(bridge: bridge, folderStore: store)

        viewModel.restoreSavedFolders()

        waitForCondition {
            viewModel.folders == ["/movies"] && !viewModel.isScanning
        }

        XCTAssertEqual(store.storedPaths, ["/denied", "/movies"])
    }

    func testAddAndRemoveFolderUpdatePersistedRoots() {
        let bridge = MockLibraryBridge()
        let store = InMemoryLibraryFolderStore()
        let viewModel = LibraryViewModel(bridge: bridge, folderStore: store)

        viewModel.addFolder("/movies")
        waitForCondition {
            viewModel.folders == ["/movies"] && !viewModel.isScanning
        }
        XCTAssertEqual(store.storedPaths, ["/movies"])

        viewModel.removeFolder(at: 0)
        waitForCondition {
            viewModel.folders.isEmpty && !viewModel.isScanning
        }
        XCTAssertEqual(store.storedPaths, [])
    }

    func testRemoveFolderUsesCurrentPathWhenBridgeOrderChangesBeforeDeleteRuns() {
        let bridge = MockLibraryBridge()
        bridge.folderPaths = ["/movies", "/shows"]
        bridge.onNextFolderCountRead = {
            bridge.folderPaths.removeFirst()
        }

        let store = InMemoryLibraryFolderStore(storedPaths: ["/movies", "/shows"])
        let viewModel = LibraryViewModel(bridge: bridge, folderStore: store)
        viewModel.folders = ["/movies", "/shows"]

        viewModel.removeFolder(at: 1)

        waitForCondition {
            viewModel.folders.isEmpty && !viewModel.isScanning
        }

        XCTAssertEqual(bridge.folderPaths, [])
        XCTAssertEqual(store.storedPaths, [])
    }

    func testUserDefaultsLibraryFolderStoreMigratesLegacyPaths() {
        let suiteName = "com.plaiy.tests.library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let key = "savedLibraryFolders"
        defaults.set(["/movies", "/shows"], forKey: key)

        let store = UserDefaultsLibraryFolderStore(defaults: defaults, key: key)
        XCTAssertEqual(
            store.load(),
            [
                SavedLibraryFolder(path: "/movies", bookmarkData: nil),
                SavedLibraryFolder(path: "/shows", bookmarkData: nil)
            ]
        )

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUserDefaultsLibraryFolderStoreRoundTripsBookmarks() throws {
        let suiteName = "com.plaiy.tests.library.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let key = "savedLibraryFolders"
        let store = UserDefaultsLibraryFolderStore(defaults: defaults, key: key)
        let folders = [
            SavedLibraryFolder(path: "/movies", bookmarkData: Data([0x01, 0x02, 0x03]))
        ]

        store.save(folders)

        XCTAssertEqual(store.load(), folders)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
