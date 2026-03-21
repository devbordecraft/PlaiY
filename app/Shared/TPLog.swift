import Foundation
import os.log

enum TPLog {
    private static let logger = os.Logger(subsystem: "com.testplayer.app", category: "core")
    private static let swiftLogger = os.Logger(subsystem: "com.testplayer.app", category: "swift")

    static func setup() {
        #if DEBUG
        tp_log_set_level(Int32(TP_LOG_LEVEL_DEBUG.rawValue))
        #else
        tp_log_set_level(Int32(TP_LOG_LEVEL_INFO.rawValue))
        #endif

        tp_log_set_callback({ level, tag, message, _ in
            guard let tag = tag, let message = message else { return }
            let tagStr = String(cString: tag)
            let msgStr = String(cString: message)

            switch level {
            case Int32(TP_LOG_LEVEL_DEBUG.rawValue):
                TPLog.logger.debug("[\(tagStr)] \(msgStr)")
            case Int32(TP_LOG_LEVEL_INFO.rawValue):
                TPLog.logger.info("[\(tagStr)] \(msgStr)")
            case Int32(TP_LOG_LEVEL_WARNING.rawValue):
                TPLog.logger.warning("[\(tagStr)] \(msgStr)")
            case Int32(TP_LOG_LEVEL_ERROR.rawValue):
                TPLog.logger.error("[\(tagStr)] \(msgStr)")
            default:
                TPLog.logger.info("[\(tagStr)] \(msgStr)")
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
