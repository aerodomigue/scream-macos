import Foundation
import Security

/// Per-daemon, per-endpoint bearer credentials stored only in the macOS Keychain.
struct HostDaemonKeychain: HostDaemonCredentialPersisting {
    private static let SERVICE = "com.screambar.host-daemon.client-token"

    func token(for endpoint: HostDaemonEndpoint) throws -> String? {
        var query = baseQuery(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var storedValue: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &storedValue)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw HostDaemonClientError.keychainFailure(status) }
        guard let encoded = storedValue as? Data, let token = String(data: encoded, encoding: .utf8),
              HostDaemonCredentialStore.isValidToken(token) else { throw HostDaemonClientError.invalidResponse }
        return token
    }

    func save(_ token: String, for endpoint: HostDaemonEndpoint) throws {
        guard HostDaemonCredentialStore.isValidToken(token) else { throw HostDaemonClientError.invalidResponse }
        let query = baseQuery(endpoint)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw HostDaemonClientError.keychainFailure(updateStatus) }
        var creation = query.merging(attributes) { _, replacement in replacement }
        creation[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(creation as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw HostDaemonClientError.keychainFailure(addStatus) }
    }

    func remove(for endpoint: HostDaemonEndpoint) throws {
        let status = SecItemDelete(baseQuery(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HostDaemonClientError.keychainFailure(status)
        }
    }

    private func baseQuery(_ endpoint: HostDaemonEndpoint) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.SERVICE,
         kSecAttrAccount as String: endpoint.credentialAccount,
         kSecAttrSynchronizable as String: false]
    }
}
