import Foundation

/// Native HTTPS adapter for the daemon's versioned API. Mutations are never retried here.
struct HostDaemonAPIClient: HostDaemonAPI {
    static let shutdownPath = "/api/v1/modules/power/shutdown"
    private static let MAX_REQUEST_BYTES = 16_384
    private static let MAX_SHUTDOWN_DELAY_SECONDS = 300
    private static let MILLISECONDS_PER_SECOND = 1_000
    private static let OPERATION_STATES: Set<String> = ["scheduled", "running", "succeeded", "cancelled", "failed", "outcome_unknown"]
    private let credentials = HostDaemonCredentialStore()

    func status(endpoint: HostDaemonEndpoint) async throws -> HostDaemonStatus {
        let status: HostDaemonStatus = try await request(endpoint, path: "/api/v1/status", expectedStatus: 200)
        guard status.daemonID == endpoint.trust.daemonID else { throw HostDaemonClientError.identityMismatch }
        guard status.apiMajor == 1 else { throw HostDaemonClientError.incompatibleDaemon }
        return status
    }

    func modules(endpoint: HostDaemonEndpoint) async throws -> [HostDaemonModule] {
        let catalog: ModuleCatalog = try await request(endpoint, path: "/api/v1/modules", expectedStatus: 200)
        return catalog.modules
    }

    func scheduleShutdown(endpoint: HostDaemonEndpoint, requestID: UUID, instanceID: UUID,
                          delaySeconds: Int = 20) async throws -> HostDaemonOperation {
        guard (0...Self.MAX_SHUTDOWN_DELAY_SECONDS).contains(delaySeconds) else { throw HostDaemonClientError.invalidRequest }
        let body = try JSONEncoder().encode(ShutdownRequest(requestID: requestID, instanceID: instanceID,
                                                           delaySeconds: delaySeconds))
        let operation: HostDaemonOperation = try await request(endpoint, path: Self.shutdownPath,
                                                               method: "POST", body: body, expectedStatus: 202, additionalStatus: 200)
        try validate(operation, instanceID: instanceID)
        guard operation.requestID == requestID else { throw HostDaemonClientError.invalidResponse }
        return operation
    }

    func operation(endpoint: HostDaemonEndpoint, id: UUID,
                   instanceID: UUID) async throws -> HostDaemonOperation {
        let operation: HostDaemonOperation = try await request(endpoint,
            path: "/api/v1/operations/\(id.uuidString.lowercased())", expectedStatus: 200,
            queryItems: [URLQueryItem(name: "instance_id", value: instanceID.uuidString.lowercased())])
        try validate(operation, instanceID: instanceID)
        guard operation.id == id else { throw HostDaemonClientError.invalidResponse }
        return operation
    }

    func cancel(endpoint: HostDaemonEndpoint, id: UUID,
                instanceID: UUID) async throws -> HostDaemonOperation {
        let body = try JSONEncoder().encode(CancelRequest(instanceID: instanceID))
        let operation: HostDaemonOperation = try await request(endpoint,
            path: "/api/v1/operations/\(id.uuidString.lowercased())/cancel", method: "POST",
            body: body, expectedStatus: 200)
        try validate(operation, instanceID: instanceID)
        guard operation.id == id, operation.state == "cancelled" else {
            throw HostDaemonClientError.invalidResponse
        }
        return operation
    }

    /// Exchanges only an explicitly imported enrollment and saves its key before returning.
    func pair(endpoint: HostDaemonEndpoint, enrollmentToken: String,
              clientName: String) async throws -> HostDaemonPairing {
        guard HostDaemonCredentialStore.isValidToken(enrollmentToken),
              !clientName.isEmpty, clientName.count <= 64,
              !clientName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HostDaemonClientError.invalidRequest
        }
        let body = try JSONEncoder().encode(PairingRequest(clientName: clientName, enrollmentToken: enrollmentToken))
        // Enrollment is its own local authorization, so importing a replacement pairing
        // does not send a previously revoked bearer token to this endpoint.
        let pairing: HostDaemonPairing = try await request(endpoint, path: "/api/v1/pairings",
            method: "POST", body: body, expectedStatus: 201, useClientToken: false)
        guard pairing.daemonID == endpoint.trust.daemonID else { throw HostDaemonClientError.identityMismatch }
        guard pairing.tokenType == "Bearer", HostDaemonCredentialStore.isValidToken(pairing.accessToken) else {
            throw HostDaemonClientError.invalidResponse
        }
        try credentials.save(pairing.accessToken, for: endpoint)
        return pairing
    }

    private func validate(_ operation: HostDaemonOperation, instanceID: UUID) throws {
        guard operation.instanceID == instanceID, operation.moduleID == "power", operation.action == "shutdown",
              Self.OPERATION_STATES.contains(operation.state),
              operation.principalID == "anonymous" || UUID(uuidString: operation.principalID) != nil,
              !operation.cancellable || operation.state == "scheduled",
              operation.remainingDelayMilliseconds.map({
                  (0...(Self.MAX_SHUTDOWN_DELAY_SECONDS * Self.MILLISECONDS_PER_SECOND)).contains($0)
              }) ?? true else {
            throw HostDaemonClientError.invalidResponse
        }
        if operation.state == "succeeded", operation.result?.outcome != "os_accepted" {
            throw HostDaemonClientError.invalidResponse
        }
        if ["failed", "outcome_unknown"].contains(operation.state), operation.error == nil {
            throw HostDaemonClientError.invalidResponse
        }
        if operation.state == "cancelled", operation.reasonCode == nil {
            throw HostDaemonClientError.invalidResponse
        }
    }

    private func request<Response: Decodable>(_ endpoint: HostDaemonEndpoint, path: String,
        method: String = "GET", body: Data? = nil, expectedStatus: Int,
        queryItems: [URLQueryItem] = [], useClientToken: Bool = true, additionalStatus: Int? = nil) async throws -> Response {
        try Task.checkCancellation()
        guard body.map({ $0.count <= Self.MAX_REQUEST_BYTES }) ?? true else {
            throw HostDaemonClientError.invalidRequest
        }
        var request = URLRequest(url: try endpoint.url(path: path, queryItems: queryItems))
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, application/problem+json", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if useClientToken, let token = try credentials.token(for: endpoint) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let transport = HostDaemonTrustTransport(endpoint: endpoint)
        let response = try await transport.perform(request)
        let decoder = JSONDecoder()
        if response.status != expectedStatus && response.status != additionalStatus {
            guard (400...599).contains(response.status), response.contentType == "application/problem+json",
                  let problem = try? decoder.decode(HostDaemonProblem.self, from: response.body),
                  problem.status == response.status else { throw HostDaemonClientError.invalidResponse }
            throw HostDaemonClientError.api(problem)
        }
        guard response.contentType == "application/json" else { throw HostDaemonClientError.invalidResponse }
        do { return try decoder.decode(Response.self, from: response.body) }
        catch { throw HostDaemonClientError.invalidResponse }
    }

    private struct ModuleCatalog: Decodable { let modules: [HostDaemonModule] }
    private struct ShutdownRequest: Encodable {
        let requestID: UUID
        let instanceID: UUID
        let delaySeconds: Int
        enum CodingKeys: String, CodingKey {
            case requestID = "request_id", instanceID = "instance_id", delaySeconds = "delay_seconds"
        }
    }
    private struct CancelRequest: Encodable {
        let instanceID: UUID
        enum CodingKeys: String, CodingKey { case instanceID = "instance_id" }
    }
    private struct PairingRequest: Encodable {
        let clientName: String
        let enrollmentToken: String
        enum CodingKeys: String, CodingKey { case clientName = "client_name", enrollmentToken = "enrollment_token" }
    }
}
