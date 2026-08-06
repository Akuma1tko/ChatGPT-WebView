import Foundation
import Security

final class ChatGPTProfileCookieVault {
    private let service = "com.deerspotter.ChatGPTWebView.profile-cookies"

    func save(_ cookies: [HTTPCookie], profileID: String) {
        let propertyLists: [[String: Any]] = cookies.compactMap { cookie in
            guard let properties = cookie.properties else { return nil }
            var values: [String: Any] = [:]
            for (key, value) in properties {
                values[key.rawValue] = value
            }
            return values
        }

        guard PropertyListSerialization.propertyList(propertyLists, isValidFor: .binary),
              let data = try? PropertyListSerialization.data(
                fromPropertyList: propertyLists,
                format: .binary,
                options: 0
              ) else {
            return
        }

        saveData(data, profileID: profileID)
    }

    func load(profileID: String) -> [HTTPCookie] {
        guard let data = loadData(profileID: profileID),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let storedCookies = propertyList as? [[String: Any]] else {
            return []
        }

        return storedCookies.compactMap { stored in
            var properties: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in stored {
                properties[HTTPCookiePropertyKey(key)] = value
            }
            return HTTPCookie(properties: properties)
        }
    }

    func migrateLegacyProfileIfNeeded(legacyProfileID: String, profileID: String) {
        guard legacyProfileID != profileID,
              loadData(profileID: profileID) == nil,
              let legacyData = loadData(profileID: legacyProfileID) else {
            return
        }

        saveData(legacyData, profileID: profileID)
    }

    func delete(profileID: String) {
        SecItemDelete(query(profileID: profileID) as CFDictionary)
    }

    private func loadData(profileID: String) -> Data? {
        var query = query(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func saveData(_ data: Data, profileID: String) {
        let query = query(profileID: profileID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            attributes.forEach { newItem[$0.key] = $0.value }
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    private func query(profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID
        ]
    }
}
