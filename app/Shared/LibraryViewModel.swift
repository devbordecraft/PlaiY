import Foundation

struct SavedLibraryFolder: Codable, Equatable, Sendable {
    let path: String
    let bookmarkData: Data?
}

protocol LibraryFolderStore: Sendable {
    func load() -> [SavedLibraryFolder]
    func save(_ folders: [SavedLibraryFolder])
}

struct UserDefaultsLibraryFolderStore: LibraryFolderStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    private static func defaultDefaults() -> UserDefaults {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return UserDefaults(suiteName: "com.plaiy.tests.library") ?? .standard
        }
        return .standard
    }

    init(defaults: UserDefaults = defaultDefaults(), key: String = "savedLibraryFolders") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> [SavedLibraryFolder] {
        if let data = defaults.data(forKey: key) {
            do {
                return try JSONDecoder().decode([SavedLibraryFolder].self, from: data)
            } catch {
                PYLog.warning("Failed to decode saved library folders: \(error)", tag: "Library")
                return []
            }
        }

        return (defaults.stringArray(forKey: key) ?? []).map {
            SavedLibraryFolder(path: $0, bookmarkData: nil)
        }
    }

    func save(_ folders: [SavedLibraryFolder]) {
        do {
            let data = try JSONEncoder().encode(folders)
            defaults.set(data, forKey: key)
        } catch {
            PYLog.warning("Failed to encode saved library folders: \(error)", tag: "Library")
        }
    }
}

struct LibraryItem: Identifiable, Codable, Sendable {
    var id: String { filePath }

    let filePath: String
    let title: String
    let durationUs: Int64
    let videoWidth: Int
    let videoHeight: Int
    let videoCodec: String
    let audioCodec: String
    let hdrType: Int
    let fileSize: Int64

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case title
        case durationUs = "duration_us"
        case videoWidth = "video_width"
        case videoHeight = "video_height"
        case videoCodec = "video_codec"
        case audioCodec = "audio_codec"
        case hdrType = "hdr_type"
        case fileSize = "file_size"
    }

    var durationText: String {
        TimeFormatting.display(durationUs)
    }

    var resolutionText: String {
        guard videoWidth > 0, videoHeight > 0 else { return "" }
        if videoHeight >= 2160 { return "4K" }
        if videoHeight >= 1080 { return "1080p" }
        if videoHeight >= 720 { return "720p" }
        return "\(videoWidth)x\(videoHeight)"
    }

    var hdrText: String {
        switch hdrType {
        case 1: return "HDR10"
        case 2: return "HDR10+"
        case 3: return "HLG"
        case 4: return "DV"
        default: return ""
        }
    }

    var fileSizeText: String {
        let gb = Double(fileSize) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(fileSize) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }
}

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var items: [LibraryItem] = []
    @Published var folders: [String] = []
    @Published var isScanning = false
    @Published private(set) var contentRevision: UInt64 = 0

    let bridge: any LibraryBridgeProtocol
    private let folderStore: any LibraryFolderStore
    private let operationQueue = DispatchQueue(label: "com.plaiy.library.operations",
                                               qos: .userInitiated)
    private var didRestoreSavedFolders = false

    init(
        bridge: any LibraryBridgeProtocol = LibraryBridge(),
        folderStore: any LibraryFolderStore = UserDefaultsLibraryFolderStore()
    ) {
        self.bridge = bridge
        self.folderStore = folderStore
    }

    private func applySnapshot(folders: [String], items: [LibraryItem]) {
        self.folders = folders
        self.items = items
        contentRevision &+= 1
    }

    func addFolder(_ url: URL) {
        addSavedFolder(Self.savedFolder(from: url))
    }

    func addFolder(_ path: String) {
        addSavedFolder(SavedLibraryFolder(path: path, bookmarkData: nil))
    }

    private func addSavedFolder(_ folder: SavedLibraryFolder) {
        let normalizedFolder = Self.normalizedFolderRecord(folder)
        guard !normalizedFolder.path.isEmpty else { return }

        let bridge = self.bridge
        let folderStore = self.folderStore
        isScanning = true
        operationQueue.async { [weak self] in
            let existingFolders = Self.readFolders(using: bridge)
            let storedFolders = Self.deduplicatedFolderRecords(folderStore.load())

            guard !existingFolders.contains(normalizedFolder.path) else {
                let currentItems = Self.decodeItems(using: bridge)
                let persistedFolders = Self.records(
                    matching: existingFolders,
                    storedRecords: storedFolders,
                    preferredRecords: [normalizedFolder]
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applySnapshot(folders: existingFolders, items: currentItems)
                    folderStore.save(persistedFolders)
                    self.isScanning = false
                }
                return
            }

            let result = bridge.addFolder(normalizedFolder.path)

            switch result {
            case .success:
                let currentFolders = Self.readFolders(using: bridge)
                let currentItems = Self.decodeItems(using: bridge)
                let persistedFolders = Self.records(
                    matching: currentFolders,
                    storedRecords: storedFolders,
                    preferredRecords: [normalizedFolder]
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applySnapshot(folders: currentFolders, items: currentItems)
                    folderStore.save(persistedFolders)
                    self.isScanning = false
                }
            case .failure(let err):
                PYLog.warning("Failed to add library folder: \(err.localizedDescription)", tag: "Library")
                DispatchQueue.main.async { [weak self] in
                    self?.isScanning = false
                }
            }
        }
    }

    func restoreSavedFolders() {
        guard !didRestoreSavedFolders else { return }
        didRestoreSavedFolders = true

        let storedFolders = Self.deduplicatedFolderRecords(folderStore.load())
        guard !storedFolders.isEmpty else { return }

        let bridge = self.bridge
        let folderStore = self.folderStore
        isScanning = true

        operationQueue.async { [weak self] in
            var persistedFolders: [SavedLibraryFolder] = []

            for storedFolder in storedFolders {
                let resolvedFolder = Self.resolveSavedFolder(storedFolder)
                defer {
                    resolvedFolder.releaseAccess()
                }

                switch bridge.addFolder(resolvedFolder.record.path) {
                case .success:
                    persistedFolders.append(resolvedFolder.record)
                case .failure(let err):
                    if err.code == Int32(PY_ERROR_FILE_NOT_FOUND.rawValue)
                        && !resolvedFolder.keepOnFileNotFound {
                        PYLog.warning("Dropping missing library folder: \(resolvedFolder.record.path)",
                                      tag: "Library")
                    } else {
                        persistedFolders.append(resolvedFolder.record)
                        PYLog.warning(
                            "Failed to restore library folder: \(resolvedFolder.record.path) (\(err.localizedDescription))",
                            tag: "Library"
                        )
                    }
                }
            }

            let restoredFolders = Self.readFolders(using: bridge)
            let restoredItems = Self.decodeItems(using: bridge)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applySnapshot(folders: restoredFolders, items: restoredItems)
                folderStore.save(Self.deduplicatedFolderRecords(persistedFolders))
                self.isScanning = false
            }
        }
    }

    func removeFolder(at index: Int) {
        guard index >= 0, index < folders.count else { return }

        let folderPath = folders[index]
        let bridge = self.bridge
        let folderStore = self.folderStore
        isScanning = true

        operationQueue.async { [weak self] in
            let currentFolders = Self.readFolders(using: bridge)
            if let currentIndex = currentFolders.firstIndex(of: folderPath) {
                let _ = bridge.removeFolder(at: Int32(currentIndex))
            }

            let updatedFolders = Self.readFolders(using: bridge)
            let currentItems = Self.decodeItems(using: bridge)
            let persistedFolders = Self.records(
                matching: updatedFolders,
                storedRecords: folderStore.load()
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applySnapshot(folders: updatedFolders, items: currentItems)
                folderStore.save(persistedFolders)
                self.isScanning = false
            }
        }
    }

    func refreshFolders() {
        let result = Self.readFolders(using: bridge)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.folders = result
            self.contentRevision &+= 1
        }
    }

    func refreshItems() {
        let decoded = Self.decodeItems(using: bridge)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.items = decoded
            self.contentRevision &+= 1
        }
    }

    private nonisolated static func readFolders(using bridge: any LibraryBridgeProtocol) -> [String] {
        let count = bridge.folderCount
        var result: [String] = []
        for i in 0..<count {
            result.append(bridge.folder(at: i))
        }
        return deduplicatedFolders(result)
    }

    private nonisolated static func decodeItems(using bridge: any LibraryBridgeProtocol) -> [LibraryItem] {
        let jsonStr = bridge.allItemsJSON()
        guard let data = jsonStr.data(using: .utf8) else { return [] }

        do {
            return try JSONDecoder().decode([LibraryItem].self, from: data)
        } catch {
            PYLog.error("Library decode error: \(error)", tag: "Library")
            return []
        }
    }

    private nonisolated static func deduplicatedFolders(_ folders: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []

        for folder in folders {
            let trimmed = normalizedFolderPath(folder)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                unique.append(trimmed)
            }
        }

        return unique
    }

    private nonisolated static func deduplicatedFolderRecords(_ folders: [SavedLibraryFolder])
        -> [SavedLibraryFolder] {
        var indicesByPath: [String: Int] = [:]
        var unique: [SavedLibraryFolder] = []

        for folder in folders {
            let normalized = normalizedFolderRecord(folder)
            guard !normalized.path.isEmpty else { continue }

            if let existingIndex = indicesByPath[normalized.path] {
                if normalized.bookmarkData != nil {
                    unique[existingIndex] = normalized
                }
                continue
            }

            indicesByPath[normalized.path] = unique.count
            unique.append(normalized)
        }

        return unique
    }

    private nonisolated static func normalizedFolderPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func normalizedFolderRecord(_ folder: SavedLibraryFolder)
        -> SavedLibraryFolder {
        SavedLibraryFolder(
            path: normalizedFolderPath(folder.path),
            bookmarkData: folder.bookmarkData
        )
    }

    private nonisolated static func savedFolder(
        from url: URL,
        fallbackBookmarkData: Data? = nil
    ) -> SavedLibraryFolder {
        let path = normalizedFolderPath(url.path)

        #if os(iOS) || os(macOS)
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return SavedLibraryFolder(path: path, bookmarkData: bookmarkData)
        } catch {
            PYLog.warning("Failed to create library folder bookmark: \(path) (\(error))",
                          tag: "Library")
        }
        #endif

        return SavedLibraryFolder(path: path, bookmarkData: fallbackBookmarkData)
    }

    private nonisolated static func records(
        matching folders: [String],
        storedRecords: [SavedLibraryFolder],
        preferredRecords: [SavedLibraryFolder] = []
    ) -> [SavedLibraryFolder] {
        let merged = deduplicatedFolderRecords(storedRecords + preferredRecords)
        let recordMap = Dictionary(uniqueKeysWithValues: merged.map { ($0.path, $0) })

        return deduplicatedFolders(folders).map { folder in
            recordMap[folder] ?? SavedLibraryFolder(path: folder, bookmarkData: nil)
        }
    }

    private struct ResolvedSavedFolder {
        let record: SavedLibraryFolder
        let keepOnFileNotFound: Bool
        let releaseAccess: @Sendable () -> Void
    }

    private nonisolated static func resolveSavedFolder(_ folder: SavedLibraryFolder)
        -> ResolvedSavedFolder {
        let normalized = normalizedFolderRecord(folder)

        #if os(iOS) || os(macOS)
        if let bookmarkData = normalized.bookmarkData {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let refreshedRecord = savedFolder(from: url, fallbackBookmarkData: bookmarkData)
                let startedAccess = url.startAccessingSecurityScopedResource()
                return ResolvedSavedFolder(
                    record: refreshedRecord,
                    keepOnFileNotFound: false,
                    releaseAccess: {
                        if startedAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                )
            } catch {
                PYLog.warning("Failed to resolve library folder bookmark: \(normalized.path) (\(error))",
                              tag: "Library")
                return ResolvedSavedFolder(
                    record: normalized,
                    keepOnFileNotFound: true,
                    releaseAccess: {}
                )
            }
        }
        #endif

        return ResolvedSavedFolder(
            record: normalized,
            keepOnFileNotFound: false,
            releaseAccess: {}
        )
    }
}
