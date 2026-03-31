import Foundation
import Security

enum KeychainHelper {
    private static let defaultService = "com.plaiy.sources"

    static func save(password: String, for sourceId: String, service: String? = nil) -> Bool {
        // Delete existing entry first
        delete(for: sourceId, service: service)

        guard let data = password.data(using: .utf8) else { return false }
        let serviceName = service ?? defaultService

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: sourceId,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func password(for sourceId: String, service: String? = nil) -> String? {
        let serviceName = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: sourceId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for sourceId: String, service: String? = nil) {
        let serviceName = service ?? defaultService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: sourceId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
