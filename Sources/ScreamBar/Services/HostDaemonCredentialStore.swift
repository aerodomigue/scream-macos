import Foundation

protocol HostDaemonCredentialPersisting: Sendable {
    func token(for endpoint: HostDaemonEndpoint) throws -> String?
    func save(_ token: String, for endpoint: HostDaemonEndpoint) throws
    func remove(for endpoint: HostDaemonEndpoint) throws
}

/// Serializes Keychain access and remembers each result for this process lifetime.
actor HostDaemonCredentialStore {
    static let shared = HostDaemonCredentialStore()
    private static let TOKEN_LENGTH = 43
    private let persistence: any HostDaemonCredentialPersisting
    private var cachedTokens: [String: Result<String?, Error>] = [:]

    init(persistence: any HostDaemonCredentialPersisting = HostDaemonKeychain()) {
        self.persistence = persistence
    }

    static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == TOKEN_LENGTH && token.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    func token(for endpoint: HostDaemonEndpoint) throws -> String? {
        try Task.checkCancellation()
        let account = endpoint.credentialAccount
        if let cached = cachedTokens[account] { return try cached.get() }
        // This synchronous call cannot interleave with another actor request, including
        // while the user answers a Keychain prompt. Denials and missing items are cached too.
        let loaded = Result { try persistence.token(for: endpoint) }
        cachedTokens[account] = loaded
        try Task.checkCancellation()
        return try loaded.get()
    }

    func save(_ token: String, for endpoint: HostDaemonEndpoint) throws {
        guard Self.isValidToken(token) else { throw HostDaemonClientError.invalidResponse }
        do {
            try persistence.save(token, for: endpoint)
            cachedTokens[endpoint.credentialAccount] = .success(token)
        } catch {
            cachedTokens[endpoint.credentialAccount] = .failure(error)
            throw error
        }
    }

    func remove(for endpoint: HostDaemonEndpoint) throws {
        do {
            try persistence.remove(for: endpoint)
            cachedTokens[endpoint.credentialAccount] = .success(nil)
        } catch {
            cachedTokens[endpoint.credentialAccount] = .failure(error)
            throw error
        }
    }

    /// Only an explicit user action may retry a failed access during this session.
    func allowRetry(for endpoint: HostDaemonEndpoint) {
        if case .failure = cachedTokens[endpoint.credentialAccount] {
            cachedTokens[endpoint.credentialAccount] = nil
        }
    }
}
