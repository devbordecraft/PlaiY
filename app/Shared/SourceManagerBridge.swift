import Foundation

protocol SourceManagerBridgeProtocol: AnyObject, Sendable {
    func lastError() -> String

    func addSource(_ config: SourceConfig) -> Result<Void, BridgeOperationError>
    func removeSource(id: String)
    var sourceCount: Int32 { get }
    func configJSON(at index: Int32) -> String
    func allConfigsJSON() -> String
    func loadConfigsJSON(_ json: String) -> Bool

    func connect(sourceId: String, password: String) -> Result<Void, BridgeOperationError>
    func disconnect(sourceId: String)
    func isConnected(sourceId: String) -> Bool

    func listDirectory(sourceId: String, relativePath: String) -> [SourceEntry]
    func playablePath(sourceId: String, entryURI: String) -> String
}

/// Swift wrapper around the C bridge for the SourceManager (plaiy_c.h py_source_* functions)
final class SourceManagerBridge: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.plaiy.source-manager-bridge")

    private static func stringFromCString(_ ptr: UnsafePointer<CChar>?) -> String {
        guard let ptr else { return "" }
        return String(cString: ptr)
    }

    private func lastErrorLocked() -> String {
        Self.stringFromCString(py_source_get_last_error(handle))
    }

    init() {
        handle = py_source_manager_create()
    }

    deinit {
        queue.sync {
            py_source_manager_destroy(handle)
        }
    }

    func lastError() -> String {
        queue.sync {
            lastErrorLocked()
        }
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

        return queue.sync {
            let code = py_source_add(handle, jsonStr)
            if code == Int32(PY_OK.rawValue) {
                return .success(())
            }

            return .failure(
                BridgeOperationError(
                    operation: "addSource",
                    code: code,
                    message: lastErrorLocked()
                )
            )
        }
    }

    func removeSource(id: String) {
        _ = queue.sync {
            py_source_remove(handle, id)
        }
    }

    var sourceCount: Int32 {
        queue.sync {
            py_source_count(handle)
        }
    }

    func configJSON(at index: Int32) -> String {
        queue.sync {
            guard let cStr = py_source_get_config_json(handle, index) else { return "{}" }
            return String(cString: cStr)
        }
    }

    func allConfigsJSON() -> String {
        queue.sync {
            guard let cStr = py_source_all_configs_json(handle) else { return "[]" }
            return String(cString: cStr)
        }
    }

    static func isSourceTypeSupported(_ type: SourceType) -> Bool {
        py_source_type_supported(type.jsonString)
    }

    func loadConfigsJSON(_ json: String) -> Bool {
        queue.sync {
            py_source_load_configs_json(handle, json) == Int32(PY_OK.rawValue)
        }
    }

    // MARK: - Connection

    func connect(sourceId: String, password: String) -> Result<Void, BridgeOperationError> {
        queue.sync {
            let code = py_source_connect(handle, sourceId, password)
            if code == Int32(PY_OK.rawValue) {
                return .success(())
            }

            return .failure(
                BridgeOperationError(
                    operation: "connect",
                    code: code,
                    message: lastErrorLocked()
                )
            )
        }
    }

    func disconnect(sourceId: String) {
        queue.sync {
            py_source_disconnect(handle, sourceId)
        }
    }

    func isConnected(sourceId: String) -> Bool {
        queue.sync {
            py_source_is_connected(handle, sourceId)
        }
    }

    // MARK: - Browsing

    func listDirectory(sourceId: String, relativePath: String) -> [SourceEntry] {
        let jsonStr = queue.sync {
            guard let cStr = py_source_list_directory(handle, sourceId, relativePath) else { return "[]" }
            return String(cString: cStr)
        }
        guard let data = jsonStr.data(using: .utf8) else { return [] }

        struct RawEntry: Decodable {
            let name: String
            let uri: String
            let is_directory: Bool
            let size: Int64
            let plex: PlexEntryMetadata?
        }

        guard let raw = try? JSONDecoder().decode([RawEntry].self, from: data) else { return [] }
        return raw.map {
            SourceEntry(
                name: $0.name,
                uri: $0.uri,
                isDirectory: $0.is_directory,
                size: $0.size,
                plex: $0.plex
            )
        }
    }

    func playablePath(sourceId: String, entryURI: String) -> String {
        queue.sync {
            guard let cStr = py_source_playable_path(handle, sourceId, entryURI) else { return "" }
            return String(cString: cStr)
        }
    }
}

extension SourceManagerBridge: SourceManagerBridgeProtocol {}
