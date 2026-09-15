import Foundation

/// Public daemon identity only; client and enrollment secrets never belong in configuration.
struct HostDaemonTrust: Codable, Equatable, Sendable {
    let daemonID: UUID
    let port: Int
    let spkiSHA256: String
    let certificatePEM: String
}

/// A locally exported administrator bundle. Enrollment secrets are transient import input.
struct HostDaemonTrustBundle: Sendable {
    static let MAX_BUNDLE_BYTES = 65_536
    let trust: HostDaemonTrust
    let addresses: [String]
    let enrollmentToken: String?
    let scopes: [String]?

    init(jsonData: Data) throws {
        guard jsonData.count <= Self.MAX_BUNDLE_BYTES else {
            throw HostDaemonClientError.invalidTrustBundle("the file is too large.")
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: jsonData)
        } catch {
            throw HostDaemonClientError.invalidTrustBundle("the JSON fields are invalid.")
        }
        guard payload.schemaVersion == 1, (1...65_535).contains(payload.port),
              payload.addresses.count <= 256, payload.addresses.allSatisfy({ $0.utf8.count <= 255 }),
              payload.spkiSHA256.count == 64,
              payload.spkiSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              payload.enrollmentToken.map(HostDaemonCredentialStore.isValidToken) ?? true else {
            throw HostDaemonClientError.invalidTrustBundle("the identity, port or enrollment fields are invalid.")
        }
        let identity = HostDaemonTrust(daemonID: payload.daemonID, port: payload.port,
                                      spkiSHA256: payload.spkiSHA256, certificatePEM: payload.certificatePEM)
        try HostDaemonTrustValidator.validateImportedIdentity(identity)
        trust = identity
        addresses = payload.addresses
        enrollmentToken = payload.enrollmentToken
        scopes = payload.scopes
    }

    private struct Payload: Decodable {
        let schemaVersion: Int
        let daemonID: UUID
        let port: Int
        let spkiSHA256: String
        let certificatePEM: String
        let addresses: [String]
        let enrollmentToken: String?
        let scopes: [String]?

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", daemonID = "daemon_id", port, addresses
            case spkiSHA256 = "spki_sha256", certificatePEM = "certificate_pem"
            case enrollmentToken = "enrollment_token", scopes
        }
    }
}

struct HostDaemonEndpoint: Equatable, Sendable {
    let host: String
    let trust: HostDaemonTrust
    var port: Int { trust.port }
    var credentialAccount: String {
        "\(trust.daemonID.uuidString.lowercased())|\(host)|\(port)|\(trust.spkiSHA256)"
    }

    init(host: String, trust: HostDaemonTrust) throws {
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedHost.hasPrefix("["), normalizedHost.hasSuffix("]") {
            normalizedHost.removeFirst()
            normalizedHost.removeLast()
        }
        guard !normalizedHost.isEmpty, normalizedHost.utf8.count <= 255,
              !normalizedHost.contains(where: { $0.isWhitespace }),
              !normalizedHost.contains(where: { "/?#@\\".contains($0) }),
              (1...65_535).contains(trust.port) else {
            throw HostDaemonClientError.invalidEndpoint
        }
        self.host = normalizedHost
        self.trust = trust
        _ = try url(path: "/api/v1/status")
    }

    func url(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard path.hasPrefix("/api/v1/"), !path.contains("?"), !path.contains("#") else {
            throw HostDaemonClientError.invalidEndpoint
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = port
        components.path = path
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let endpointURL = components.url, endpointURL.scheme == "https", endpointURL.user == nil,
              endpointURL.password == nil else { throw HostDaemonClientError.invalidEndpoint }
        return endpointURL
    }
}
