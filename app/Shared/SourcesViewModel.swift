import Foundation

@MainActor
class SourcesViewModel: ObservableObject {
    @Published var sources: [SourceConfig] = []
    @Published var currentEntries: [SourceEntry] = []
    @Published var navigationPath: [String] = []
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
        }
    }

    // MARK: - Connection

    func connect(sourceId: String) {
        isConnecting = true
        error = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let password = KeychainHelper.password(for: sourceId) ?? ""
            let success = self.bridge.connect(sourceId: sourceId, password: password)

            DispatchQueue.main.async {
                self.isConnecting = false
                if success {
                    self.currentSourceId = sourceId
                    self.navigationPath = []
                    self.browse(sourceId: sourceId, relativePath: "")
                } else {
                    self.error = "Connection failed — check address and credentials"
                }
            }
        }
    }

    func disconnect(sourceId: String) {
        bridge.disconnect(sourceId: sourceId)
        if currentSourceId == sourceId {
            currentSourceId = nil
            currentEntries = []
            navigationPath = []
        }
    }

    func isConnected(sourceId: String) -> Bool {
        bridge.isConnected(sourceId: sourceId)
    }

    // MARK: - Browsing

    func browse(sourceId: String, relativePath: String) {
        isLoading = true
        error = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let entries = self.bridge.listDirectory(sourceId: sourceId, relativePath: relativePath)

            DispatchQueue.main.async {
                self.isLoading = false
                self.currentEntries = entries
                if entries.isEmpty && !relativePath.isEmpty {
                    // Folder might be empty or an error occurred
                }
            }
        }
    }

    func navigateInto(_ entry: SourceEntry) {
        guard let sourceId = currentSourceId, entry.isDirectory else { return }

        // Compute relative path from the mount point
        // The entry.uri is an absolute path; we need the relative part
        if let config = sources.first(where: { $0.id == sourceId }) {
            // For mounted sources, the base is the mount path, which may differ
            // from the config URI. We track navigation by appending to the path stack.
            let currentPath = navigationPath.joined(separator: "/")
            let nextComponent = entry.name
            navigationPath.append(nextComponent)
            let newPath = navigationPath.joined(separator: "/")
            browse(sourceId: sourceId, relativePath: newPath)
            _ = currentPath  // suppress unused
            _ = config
        }
    }

    func navigateUp() {
        guard let sourceId = currentSourceId, !navigationPath.isEmpty else { return }
        navigationPath.removeLast()
        let path = navigationPath.joined(separator: "/")
        browse(sourceId: sourceId, relativePath: path)
    }

    func navigateToRoot() {
        guard let sourceId = currentSourceId else { return }
        navigationPath = []
        browse(sourceId: sourceId, relativePath: "")
    }

    func playablePath(for entry: SourceEntry) -> String {
        guard let sourceId = currentSourceId else { return entry.uri }
        let path = bridge.playablePath(sourceId: sourceId, entryURI: entry.uri)
        return path.isEmpty ? entry.uri : path
    }
}
