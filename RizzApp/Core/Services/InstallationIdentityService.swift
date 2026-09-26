import Foundation
import Security

/// Provides the anonymous installation identifier sent with API requests.
///
/// This is ONLY an installation identifier — it is NOT secure device
/// authentication (a determined user can reset it by reinstalling or
/// clearing the keychain entry). App Attest / DeviceCheck plus server-side
/// rate limiting will provide real abuse protection later. This ID may also
/// later align with the anonymous RevenueCat appUserID.
protocol InstallationIdentityProviding: AnyObject {
    var installationID: String { get }
}

/// Keychain-backed implementation (Apple Security framework).
/// - Generated once (random UUID) if absent, reused across launches.
/// - Stored as a generic password with
///   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: device-local,
///   never synced with ordinary preferences or iCloud Keychain.
/// - Contains no personal information.
final class KeychainInstallationIdentityService: InstallationIdentityProviding {
    private let service: String
    private let account = "installation-id"

    init(service: String = "com.zenomedia.greenshot") {
        self.service = service
    }

    lazy var installationID: String = loadOrCreate()

    private func loadOrCreate() -> String {
        if let existing = readFromKeychain() {
            return existing
        }
        let newID = UUID().uuidString
        storeInKeychain(newID)
        // If the keychain write failed (rare), the ID is still stable for
        // this process; a fresh one is generated next launch. Acceptable
        // degradation for an anonymous identifier.
        return newID
    }

    private func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func storeInKeychain(_ value: String) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// Fixed-value provider for tests and previews.
final class StaticInstallationIdentity: InstallationIdentityProviding {
    let installationID: String

    init(installationID: String = "00000000-0000-4000-8000-000000000000") {
        self.installationID = installationID
    }
}
