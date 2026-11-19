// Per-device storage: JSON values in UserDefaults (the web app's localStorage), and the
// login token in the Keychain.
import Foundation
import Security

enum Store {
    private static let defaults = UserDefaults.standard
    private static func k(_ key: String) -> String { "talkloop.\(key)" }

    static func get<T: Decodable>(_ key: String, _ fallback: T) -> T {
        guard let data = defaults.data(forKey: k(key)),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    static func set<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: k(key)) }
    }

    static func remove(_ key: String) {
        defaults.removeObject(forKey: k(key))
    }
}

enum Keychain {
    private static let service = "Talkloop"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Milliseconds since 1970, as the web app and the trainer store times.
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

/// "2026-11-20" in the device's time zone.
func localDay(_ ms: Double = nowMs()) -> String {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

/// A string as a JSON string literal, as the prompts quote things (JSON.stringify).
func q(_ s: String) -> String {
    if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]),
       let text = String(data: data, encoding: .utf8) {
        return String(text.dropFirst().dropLast())
    }
    return "\"\(s)\""
}
