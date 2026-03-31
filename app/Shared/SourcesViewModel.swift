import Foundation

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

    let bridge = SourceManagerBridge()

    private static let configsKey = "savedSourceConfigs"

    // MARK: - Lifecycle

    func loadSavedSources() {
        guard let jsonStr = UserDefaults.standard.string(forKey: Self.configsKey),
              !jsonStr.isEmpty else { return }

        if bridge.loadConfigsJSON(jsonStr) {
            refreshSourceList()
        }
    }

    private func saveSources() {
        let json = bridge.allConfigsJSON()
        UserDefaults.standard.set(json, forKey: Self.configsKey)
    }

    private func refreshSourceList() {
        let json = bridge.allConfigsJSON()
        guard let data = json.data(using: .utf8) else { return }
        sources = (try? JSONDecoder().decode([SourceConfig].self, from: data)) ?? []
    }

    // MARK: - Source CRUD

    func addSource(_ config: SourceConfig, password: String) {
        guard bridge.addSource(config) else {
            error = "Failed to add source"
            return
        }
        if !password.isEmpty {
            _ = KeychainHelper.save(password: password, for: config.id)
        }
        refreshSourceList()
        saveSources()
    }

    func addSourceAndConnect(_ config: SourceConfig, password: String) {
        let sourceId = config.id
        addSource(config, password: password)
        connect(sourceId: sourceId)
    }

    func removeSource(id: String) {
        bridge.disconnect(sourceId: id)
        bridge.removeSource(id: id)
        KeychainHelper.delete(for: id)
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

        let password = KeychainHelper.password(for: sourceId) ?? ""
        let success = bridge.connect(sourceId: sourceId, password: password)

        isConnecting = false
        if success {
            currentSourceId = sourceId
            navigationPath = []
            navigationDisplayNames = []
            browse(sourceId: sourceId, relativePath: "")
        } else {
            error = "Connection failed — check address and credentials"
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
        if entries.isEmpty && !relativePath.isEmpty {
            // Folder might be empty or an error occurred
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
