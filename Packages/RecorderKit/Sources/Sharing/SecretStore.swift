// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Synchronization

/// Where the secret access key of Settings ▸ Share is kept, by the Access Key ID it belongs to (design §8.4): the
/// Keychain for the app and `toma` (`KeychainSecretStore`), memory for the tests (`InMemorySecretStore`), never a file,
/// a log, an environment variable or a URL.
public protocol SecretStore: Sendable {
    /// The secret saved for `account`; `nil` when there is none.
    func secret(for account: String) throws -> String?
    /// Whether a secret is saved for `account`, without reading it: what Share's little window and Settings ▸ Share ask
    /// to say whether sharing is set up. The Keychain answers it from the item's attributes and never asks the person;
    /// the secret itself is read only to share or to test the connection.
    func hasSecret(for account: String) throws -> Bool
    /// Saves `secret` for `account`, replacing the one there was; `nil` removes it (none there is not an error).
    func setSecret(_ secret: String?, for account: String) throws
}

/// Why a secret could not be read or saved. Never carries the secret.
public enum SecretStoreError: Error, Equatable, Sendable {
    /// What the Keychain answered (`errSecAuthFailed`, `errSecInteractionNotAllowed`…).
    case keychain(OSStatus)
    /// What is saved is not UTF-8 text.
    case notText
}

/// The secrets in memory, for the tests: no test ever reads or writes the Keychain.
public final class InMemorySecretStore: SecretStore {
    private let secrets: Mutex<[String: String]>

    public init(_ secrets: [String: String] = [:]) {
        self.secrets = Mutex(secrets)
    }

    public func secret(for account: String) throws -> String? {
        secrets.withLock { $0[account] }
    }

    public func hasSecret(for account: String) throws -> Bool {
        secrets.withLock { $0[account] != nil }
    }

    public func setSecret(_ secret: String?, for account: String) throws {
        secrets.withLock { $0[account] = secret }
    }
}

extension SharePreferences {
    /// The account the secret of these preferences is saved under: the Access Key ID without spaces at its ends, as
    /// `ShareConfiguration` signs with it. Settings ▸ Share saves under it and the share job reads under it.
    public var secretAccount: String {
        accessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
