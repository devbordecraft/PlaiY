import Foundation
import os.log
#if DEBUG
import os.signpost
#endif

@c
private func pyLogCallback(
    _ level: Int32,
    _ tag: UnsafePointer<CChar>?,
    _ message: UnsafePointer<CChar>?,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard let tag, let message else { return }
    let tagStr = String(cString: tag)
    let msgStr = String(cString: message)

    switch level {
    case Int32(PY_LOG_LEVEL_DEBUG.rawValue):
        PYLog.logger.debug("[\(tagStr)] \(msgStr)")
    case Int32(PY_LOG_LEVEL_INFO.rawValue):
        PYLog.logger.info("[\(tagStr)] \(msgStr)")
    case Int32(PY_LOG_LEVEL_WARNING.rawValue):
        PYLog.logger.warning("[\(tagStr)] \(msgStr)")
    case Int32(PY_LOG_LEVEL_ERROR.rawValue):
        PYLog.logger.error("[\(tagStr)] \(msgStr)")
    default:
        PYLog.logger.info("[\(tagStr)] \(msgStr)")
    }
}

enum PYLog {
    fileprivate static let logger = os.Logger(subsystem: "com.plaiy.app", category: "core")
    private static let swiftLogger = os.Logger(subsystem: "com.plaiy.app", category: "swift")

    static func setup() {
        #if DEBUG
        py_log_set_level(Int32(PY_LOG_LEVEL_DEBUG.rawValue))
        #else
        py_log_set_level(Int32(PY_LOG_LEVEL_INFO.rawValue))
        #endif

        py_log_set_callback(pyLogCallback, nil)
    }

    static func debug(_ message: String, tag: String = "App") {
        #if DEBUG
        swiftLogger.debug("[\(tag)] \(message)")
        #endif
    }

    static func info(_ message: String, tag: String = "App") {
        swiftLogger.info("[\(tag)] \(message)")
    }

    static func warning(_ message: String, tag: String = "App") {
        swiftLogger.warning("[\(tag)] \(message)")
    }

    static func error(_ message: String, tag: String = "App") {
        swiftLogger.error("[\(tag)] \(message)")
    }
}

enum PYSignpostCategory {
    case browse
    case player
    case render
    case artwork
}

struct PYSignpostInterval {
    #if DEBUG
    fileprivate let log: OSLog
    fileprivate let name: StaticString
    fileprivate let id: OSSignpostID

    func end() {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
    #else
    func end() {}
    #endif
}

enum PYSignpost {
    static func begin(_ name: StaticString, category: PYSignpostCategory) -> PYSignpostInterval {
        #if DEBUG
        let log = log(for: category)
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return PYSignpostInterval(log: log, name: name, id: id)
        #else
        return PYSignpostInterval()
        #endif
    }

    #if DEBUG
    private static func log(for category: PYSignpostCategory) -> OSLog {
        let categoryName: String
        switch category {
        case .browse:
            categoryName = "browse.perf"
        case .player:
            categoryName = "player.perf"
        case .render:
            categoryName = "render.perf"
        case .artwork:
            categoryName = "artwork.perf"
        }
        return OSLog(subsystem: "com.plaiy.app", category: categoryName)
    }
    #endif
}
