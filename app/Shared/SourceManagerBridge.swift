import Foundation

/// Swift wrapper around the C bridge for the SourceManager (plaiy_c.h py_source_* functions)
final class SourceManagerBridge {
    private let handle: OpaquePointer

    private static func stringFromCString(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    init() {
        handle = py_source_manager_create()
    }

    deinit {
        py_source_manager_destroy(handle)
    }

    func lastError() -> String {
        Self.stringFromCString(py_source_get_last_error(handle))
    }

    // MARK: - Source CRUD

    func addSource(_ config: SourceConfig) -> Result<Void, BridgeOperationError> {
        guard let jsonData = try? JSONEncoder().encode(config),
              let jsonStr = String(data: jsonData, encoding: .utf8) else {
            return .failure(
                BridgeOperationError(
                    operation: "addSource",
                    code: Int32(PY_ERROR_INVALID_ARG.rawValue),
                    message: "Failed to encode source config"
                )
            )
        }

        let code = py_source_add(handle, jsonStr)
        if code == Int32(PY_OK.rawValue) {
            return .success(())
        }

        return .failure(
            BridgeOperationError(
                operation: "addSource",
                code: code,
                message: lastError()
            )
        )
    }

    func removeSource(id: String) {
        py_source_remove(handle, id)
    }

    var sourceCount: Int32 {
        py_source_count(handle)
    }

    func configJSON(at index: Int32) -> String {
        guard let cStr = py_source_get_config_json(handle, index) else { return "{}" }
        return String(cString: cStr)
    }

    func allConfigsJSON() -> String {
        guard let cStr = py_source_all_configs_json(handle) else { return "[]" }
        return String(cString: cStr)
    }

    static func isSourceTypeSupported(_ type: SourceType) -> Bool {
        py_source_type_supported(type.jsonString)
    }

    func loadConfigsJSON(_ json: String) -> Bool {
        py_source_load_configs_json(handle, json) == Int32(PY_OK.rawValue)
    }

    // MARK: - Connection

    func connect(sourceId: String, password: String) -> Result<Void, BridgeOperationError> {
        let code = py_source_connect(handle, sourceId, password)
        if code == Int32(PY_OK.rawValue) {
            return .success(())
        }

        return .failure(
            BridgeOperationError(
                operation: "connect",
                code: code,
                message: lastError()
            )
        )
    }

    func disconnect(sourceId: String) {
        py_source_disconnect(handle, sourceId)
    }

    func isConnected(sourceId: String) -> Bool {
        py_source_is_connected(handle, sourceId)
    }

    // MARK: - Browsing

    func listDirectory(sourceId: String, relativePath: String) -> [SourceEntry] {
        guard let cStr = py_source_list_directory(handle, sourceId, relativePath) else { return [] }
        let jsonStr = String(cString: cStr)
        guard let data = jsonStr.data(using: .utf8) else { return [] }

        struct RawEntry: Decodable {
            let name: String
            let uri: String
            let is_directory: Bool
            let size: Int64
        }

        guard let raw = try? JSONDecoder().decode([RawEntry].self, from: data) else { return [] }
        return raw.map { SourceEntry(name: $0.name, uri: $0.uri, isDirectory: $0.is_directory, size: $0.size) }
    }

    func playablePath(sourceId: String, entryURI: String) -> String {
        guard let cStr = py_source_playable_path(handle, sourceId, entryURI) else { return "" }
        return String(cString: cStr)
    }
}
