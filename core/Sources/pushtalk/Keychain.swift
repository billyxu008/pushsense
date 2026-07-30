import Foundation
import Security

/// Minimal Keychain wrapper for storing cloud API keys. Keys are secrets, so they
/// must NOT live in UserDefaults (a plaintext plist any process can read). Each
/// provider stores its own key under a distinct account, so the user can keep an
/// OpenAI key and an Ollama Cloud key at the same time. set(nil/"") deletes it.
enum Keychain {
    private static let service = "com.billy.pushtalk"

    static func setAPIKey(_ value: String?, account: String) {
        // Always delete first so we never accumulate duplicate items.
        let delQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(delQuery as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Readable only while the Mac is unlocked; never syncs to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func apiKey(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return "" }
        return str
    }
}
