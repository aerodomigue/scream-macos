import Foundation

/// Durable public context for an action that may already have reached the agent.
struct DaemonPendingAction: Codable, Equatable, Sendable {
    static let SCHEMA_VERSION = 1
    let schemaVersion: Int
    let host: String
    let trust: HostDaemonTrust
    let requestID: UUID
    let instanceID: UUID
    let principalID: String
    var operationID: UUID?
    var outcomeUnknown: Bool
    // Optional for compatibility with recovery records written before this phase existed.
    var osShutdownAccepted: Bool?

    init(endpoint: HostDaemonEndpoint, requestID: UUID, instanceID: UUID, principalID: String) {
        schemaVersion = Self.SCHEMA_VERSION
        host = endpoint.host
        trust = endpoint.trust
        self.requestID = requestID
        self.instanceID = instanceID
        self.principalID = principalID
        operationID = nil
        outcomeUnknown = true
        osShutdownAccepted = false
    }

    func endpoint() throws -> HostDaemonEndpoint {
        try HostDaemonEndpoint(host: host, trust: trust)
    }
}

protocol DaemonPendingActionStoring {
    func load() throws -> DaemonPendingAction?
    func save(_ action: DaemonPendingAction) throws
    func remove() throws
}

/// Stores no credentials; recovery never resubmits a mutation automatically.
final class DaemonPendingActionStore: DaemonPendingActionStoring {
    private static let MAX_RECORD_BYTES = 65_536
    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
    }

    func load() throws -> DaemonPendingAction? {
        let storageURL = try resolvedFileURL()
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: storageURL.path)
        guard let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= Self.MAX_RECORD_BYTES else {
            throw HostDaemonClientError.invalidResponse
        }
        let encodedAction = try Data(contentsOf: storageURL)
        guard encodedAction.count <= Self.MAX_RECORD_BYTES else {
            throw HostDaemonClientError.invalidResponse
        }
        let action = try JSONDecoder().decode(DaemonPendingAction.self, from: encodedAction)
        guard action.schemaVersion == DaemonPendingAction.SCHEMA_VERSION,
              action.principalID == "anonymous" || UUID(uuidString: action.principalID) != nil else {
            throw HostDaemonClientError.invalidResponse
        }
        _ = try action.endpoint()
        return action
    }

    func save(_ action: DaemonPendingAction) throws {
        let encodedAction = try JSONEncoder().encode(action)
        guard encodedAction.count <= Self.MAX_RECORD_BYTES else {
            throw HostDaemonClientError.invalidResponse
        }
        let storageURL = try resolvedFileURL()
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encodedAction.write(to: storageURL, options: .atomic)
        let handle = try FileHandle(forWritingTo: storageURL)
        // FileHandle owns its descriptor and releases it if synchronization throws.
        try handle.synchronize()
        try handle.close()
    }

    func remove() throws {
        let storageURL = try resolvedFileURL()
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        try FileManager.default.removeItem(at: storageURL)
    }

    private func resolvedFileURL() throws -> URL {
        if let fileURL { return fileURL }
        let supportDirectory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
        return supportDirectory.appendingPathComponent("ScreamBar", isDirectory: true)
            .appendingPathComponent("daemon-pending-action.json")
    }
}
