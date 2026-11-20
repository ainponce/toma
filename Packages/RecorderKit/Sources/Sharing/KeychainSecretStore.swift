// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

/// The secret access key in the login Keychain (design §8.4, plan 5a decision 2): a generic password of the service
/// `dev.toma.Toma.share` whose account is the Access Key ID (`SharePreferences.secretAccount`). The app saves it from
/// Settings ▸ Share and both the app and `toma` read it; the first time `toma` reads it, macOS asks whether to allow it.
///
/// It is the file-based login Keychain, not the data protection one (that one needs an access group, which needs a
/// provisioning profile), so `kSecAttrAccessible` is not set: `SecItem.h` documents it on macOS only for the data
/// protection keychain or a synchronizable item, and the login Keychain is readable while it is unlocked anyway.
///
/// No test uses it: they use `InMemorySecretStore`.
public struct KeychainSecretStore: SecretStore {
    public static let service = "dev.toma.Toma.share"

    public init() {}

    public func secret(for account: String) throws -> String? {
        var query = Self.query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw SecretStoreError.notText
            }
            return secret
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func setSecret(_ secret: String?, for account: String) throws {
        let query = Self.query(account)
        guard let secret else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
            return
        }
        let data = Data(secret.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = data
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecretStoreError.keychain(added) }
        default:
            throw SecretStoreError.keychain(updated)
        }
    }

    /// The item of `account`: a generic password of `service`.
    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
