/*
 * Atoll_Paco (fork personal de Atoll)
 * Copyright (C) 2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import Security
import Defaults

/// Guarda las API keys del Screen Assistant en el Keychain en lugar de UserDefaults.
///
/// Antes vivían en texto plano en `~/Library/Preferences/<bundle>.plist`, que
/// cualquier proceso de tu usuario puede leer. La primera vez que se lee una key
/// se migra sola: se copia al Keychain y se borra de UserDefaults.
///
/// Ojo: con firma ad-hoc, cada vez que recompilas cambia la firma de la app y
/// macOS te pregunta si Atoll puede usar el ítem del Keychain. Dale "Permitir siempre".
enum APIKeyStore {
    enum Provider: String, CaseIterable {
        case gemini
        case openai
        case claude
        case groq

        fileprivate var legacyDefaultsKey: Defaults.Key<String> {
            switch self {
            case .gemini: return .geminiApiKey
            case .openai: return .openaiApiKey
            case .claude: return .claudeApiKey
            case .groq: return .groqApiKey
            }
        }

        fileprivate var account: String { "\(rawValue)-api-key" }
    }

    private static let service = "\(Bundle.main.bundleIdentifier ?? "com.pacocerv08.AtollPaco").api-keys"

    static subscript(_ provider: Provider) -> String {
        get {
            if let stored = read(account: provider.account) {
                return stored
            }
            // Migración desde UserDefaults (solo pasa una vez por key).
            let legacy = Defaults[provider.legacyDefaultsKey]
            guard !legacy.isEmpty else { return "" }
            if write(legacy, account: provider.account) {
                Defaults[provider.legacyDefaultsKey] = ""
            }
            return legacy
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                delete(account: provider.account)
            } else {
                _ = write(trimmed, account: provider.account)
            }
            // Nunca dejar copia en texto plano.
            Defaults[provider.legacyDefaultsKey] = ""
        }
    }

    // MARK: - Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    private static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
