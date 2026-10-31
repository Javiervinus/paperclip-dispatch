import Foundation
import Security

/// Secretos de la app (p. ej. el token del bot de Telegram) en el llavero de la Mac, nunca en archivos ni
/// en UserDefaults. Solo esta app, firmada con la misma identidad, los puede leer sin pedir permiso.
enum Keychain {
    static func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for account: String) -> Bool {
        delete(account)
        var query = base(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrLabel as String] = "\(AppConfig.appName) (\(account))"
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? AppConfig.appName,
            kSecAttrAccount as String: account,
        ]
    }
}
