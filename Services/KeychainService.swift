import Foundation
import Security

final class KeychainService {
    func saveToken(_ token: String, key: String) {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
        AppLog.auth.debug("keychain save key=\(key, privacy: .public)")
    }

    func readToken(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status != errSecSuccess {
            AppLog.auth.debug("keychain read miss key=\(key, privacy: .public)")
            return nil
        }
        guard let data = item as? Data else { return nil }
        AppLog.auth.debug("keychain read hit key=\(key, privacy: .public)")
        return String(data: data, encoding: .utf8)
    }

    func deleteToken(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        AppLog.auth.debug("keychain delete key=\(key, privacy: .public)")
    }
}
