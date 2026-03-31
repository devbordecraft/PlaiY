import Foundation

protocol LibraryFolderStore: Sendable {
    func load() -> [String]
    func save(_ folders: [String])
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

    func load() -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    func save(_ folders: [String]) {
        defaults.set(folders, forKey: key)
    }
}

struct LibraryItem: Identifiable, Codable {
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

    let bridge: any LibraryBridgeProtocol
    private let folderStore: any LibraryFolderStore
    private var didRestoreSavedFolders = false

    init(
        bridge: any LibraryBridgeProtocol = LibraryBridge(),
        folderStore: any LibraryFolderStore = UserDefaultsLibraryFolderStore()
    ) {
        self.bridge = bridge
        self.folderStore = folderStore
    }

    func addFolder(_ path: String) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return }

        let bridge = self.bridge
        let folderStore = self.folderStore
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let existingFolders = Self.readFolders(using: bridge)
            guard !existingFolders.contains(normalizedPath) else {
                DispatchQueue.main.async { [weak self] in
                    self?.isScanning = false
                }
                return
            }

            let result = bridge.addFolder(normalizedPath)

            switch result {
            case .success:
                let currentFolders = Self.readFolders(using: bridge)
                let currentItems = Self.decodeItems(using: bridge)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.folders = currentFolders
                    self.items = currentItems
                    folderStore.save(currentFolders)
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

        let storedFolders = Self.deduplicatedFolders(folderStore.load())
        guard !storedFolders.isEmpty else { return }

        let bridge = self.bridge
        let folderStore = self.folderStore
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var restoredFolders: [String] = []
            var persistedFolders: [String] = []

            for path in storedFolders {
                switch bridge.addFolder(path) {
                case .success:
                    restoredFolders.append(path)
                    persistedFolders.append(path)
                case .failure(let err):
                    if err.code == Int32(PY_ERROR_FILE_NOT_FOUND.rawValue) {
                        PYLog.warning("Dropping missing library folder: \(path)", tag: "Library")
                    } else {
                        persistedFolders.append(path)
                        PYLog.warning("Failed to restore library folder: \(path) (\(err.localizedDescription))", tag: "Library")
                    }
                }
            }

            let restoredItems = Self.decodeItems(using: bridge)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.folders = restoredFolders
                self.items = restoredItems
                folderStore.save(persistedFolders)
                self.isScanning = false
            }
        }
    }

    func removeFolder(at index: Int) {
        let bridge = self.bridge
        let folderStore = self.folderStore
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let _ = bridge.removeFolder(at: Int32(index))
            let currentFolders = Self.readFolders(using: bridge)
            let currentItems = Self.decodeItems(using: bridge)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.folders = currentFolders
                self.items = currentItems
                folderStore.save(currentFolders)
                self.isScanning = false
            }
        }
    }

    func refreshFolders() {
        let result = Self.readFolders(using: bridge)
        DispatchQueue.main.async { [weak self] in
            self?.folders = result
        }
    }

    func refreshItems() {
        let decoded = Self.decodeItems(using: bridge)
        DispatchQueue.main.async { [weak self] in
            self?.items = decoded
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
            let trimmed = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                unique.append(trimmed)
            }
        }

        return unique
    }
}
