import Foundation

struct HostDaemonStatus: Decodable, Sendable {
    let daemonID: UUID
    let instanceID: UUID
    let daemonVersion: String
    let apiMajor: Int
    let readiness: String
    let requirePairing: Bool
    let principalID: String
    let platform: String

    enum CodingKeys: String, CodingKey {
        case daemonID = "daemon_id", instanceID = "instance_id"
        case daemonVersion = "daemon_version", apiMajor = "api_major"
        case readiness, requirePairing = "require_pairing", principalID = "principal_id", platform
    }
}

struct HostDaemonModule: Decodable, Sendable {
    let id: String
    let version: String
    let enabled: Bool
    let availability: String
    let unavailableReason: String?
    let actions: [HostDaemonAction]

    var supportsShutdown: Bool {
        id == "power" && enabled && availability == "available" && actions.contains {
            $0.id == "shutdown" && $0.method == "POST"
                && $0.path == HostDaemonAPIClient.shutdownPath && $0.execution == "operation"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, version, enabled, availability, actions
        case unavailableReason = "unavailable_reason"
    }
}

struct HostDaemonAction: Decodable, Sendable {
    let id: String
    let method: String
    let path: String
    let execution: String
    let cancellable: Bool
    let allowAnonymous: Bool
    let requiredScopes: [String]
    let cancellationScopes: [String]

    enum CodingKeys: String, CodingKey {
        case id, method, path, execution, cancellable
        case allowAnonymous = "allow_anonymous", requiredScopes = "required_scopes"
        case cancellationScopes = "cancellation_scopes"
    }
}

struct HostDaemonProblem: Decodable, Sendable {
    let status: Int
    let code: String
    let detail: String
    let requestID: UUID

    enum CodingKeys: String, CodingKey {
        case status, code, detail, requestID = "request_id"
    }
}

struct HostDaemonOperation: Decodable, Sendable {
    let id: UUID
    let instanceID: UUID
    let requestID: UUID
    let moduleID: String
    let principalID: String
    let action: String
    let state: String
    let cancellable: Bool
    let remainingDelayMilliseconds: Int?
    let reasonCode: String?
    let error: HostDaemonProblem?
    let result: HostDaemonShutdownResult?

    var isTerminal: Bool {
        ["succeeded", "cancelled", "failed", "outcome_unknown"].contains(state)
    }

    enum CodingKeys: String, CodingKey {
        case id, instanceID = "instance_id", requestID = "request_id"
        case moduleID = "module_id", principalID = "principal_id", action, state, cancellable
        case remainingDelayMilliseconds = "remaining_delay_ms"
        case reasonCode = "reason_code", error, result
    }
}

struct HostDaemonShutdownResult: Decodable, Sendable {
    let outcome: String
    let acceptedAt: String

    enum CodingKeys: String, CodingKey {
        case outcome, acceptedAt = "accepted_at"
    }
}

struct HostDaemonPairing: Decodable, Sendable {
    let daemonID: UUID
    let instanceID: UUID
    let clientID: UUID
    let accessToken: String
    let tokenType: String
    let scopes: [String]

    enum CodingKeys: String, CodingKey {
        case daemonID = "daemon_id", instanceID = "instance_id", clientID = "client_id"
        case accessToken = "access_token", tokenType = "token_type", scopes
    }
}

/// Typed failures deliberately exclude response bodies and credentials from diagnostics.
enum HostDaemonClientError: LocalizedError, Sendable {
    case invalidTrustBundle(String)
    case invalidEndpoint
    case certificateRejected
    case responseTooLarge
    case redirectRejected
    case invalidResponse
    case incompatibleDaemon
    case identityMismatch
    case invalidRequest
    case keychainFailure(Int32)
    case network(Int)
    case api(HostDaemonProblem)

    var errorDescription: String? {
        switch self {
        case .invalidTrustBundle(let explanation): return "Invalid agent trust bundle: \(explanation)"
        case .invalidEndpoint: return "The agent host or port is invalid."
        case .certificateRejected: return "The agent certificate does not match the imported identity or is not currently valid."
        case .responseTooLarge: return "The agent response exceeds the allowed size."
        case .redirectRejected: return "The agent attempted an HTTP redirect; the request was stopped."
        case .invalidResponse: return "The agent returned an invalid API response."
        case .incompatibleDaemon: return "This agent API version is not supported."
        case .identityMismatch: return "The agent identity differs from the imported trust bundle."
        case .invalidRequest: return "The agent request parameters are invalid."
        case .keychainFailure(let status): return "The agent credential could not be accessed in Keychain (\(status))."
        case .network(let code) where code == URLError.timedOut.rawValue:
            return "The agent did not respond in time (network error \(code))."
        case .network(let code): return "The agent request could not be completed (network error \(code))."
        case .api(let problem): return "Agent: \(problem.detail) (\(problem.code))"
        }
    }
}

protocol HostDaemonAPI: Sendable {
    func status(endpoint: HostDaemonEndpoint) async throws -> HostDaemonStatus
    func modules(endpoint: HostDaemonEndpoint) async throws -> [HostDaemonModule]
    func scheduleShutdown(endpoint: HostDaemonEndpoint, requestID: UUID, instanceID: UUID,
                          delaySeconds: Int) async throws -> HostDaemonOperation
    func operation(endpoint: HostDaemonEndpoint, id: UUID, instanceID: UUID) async throws -> HostDaemonOperation
    func cancel(endpoint: HostDaemonEndpoint, id: UUID, instanceID: UUID) async throws -> HostDaemonOperation
    func pair(endpoint: HostDaemonEndpoint, enrollmentToken: String,
              clientName: String) async throws -> HostDaemonPairing
}
