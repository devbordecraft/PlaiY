import Foundation
import os.log

enum PYLog {
    private static let logger = os.Logger(subsystem: "com.plaiy.app", category: "core")
    private static let swiftLogger = os.Logger(subsystem: "com.plaiy.app", category: "swift")

    static func setup() {
        #if DEBUG
        py_log_set_level(Int32(PY_LOG_LEVEL_DEBUG.rawValue))
        #else
        py_log_set_level(Int32(PY_LOG_LEVEL_INFO.rawValue))
        #endif

        py_log_set_callback({ level, tag, message, _ in
            guard let tag = tag, let message = message else { return }
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
        }, nil)
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
