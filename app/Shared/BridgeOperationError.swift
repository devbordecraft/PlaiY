import Foundation

struct BridgeOperationError: Error, Equatable, Sendable {
    let operation: String
    let code: Int32
    let message: String

    var localizedDescription: String {
        if message.isEmpty {
            return "\(operation) failed (code \(code))"
        }
        return message
    }
}
