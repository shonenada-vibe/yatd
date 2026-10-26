import Foundation
import Security

/// Stores the Notion integration token as a generic password in the login keychain.
enum Keychain {
    private static let service = "com.shonenada.yatd"
    private static let account = "notion-token"

    static var token: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves `token`, or deletes it when `nil` or empty.
    static func setToken(_ token: String?) throws {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var item = baseQuery
        item[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't save the token to Keychain (\(status))."])
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
