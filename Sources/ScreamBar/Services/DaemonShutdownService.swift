import Foundation
import os

private let daemonShutdownLogger = Logger(subsystem: "com.screambar.app", category: "DaemonShutdownService")

/// Coordinates shutdown admission and recovery separately from ICMP/Wake on LAN.
@MainActor
final class DaemonShutdownService: ObservableObject {
    static let SHUTDOWN_DELAY_SECONDS = 3
    private static let MILLISECONDS_PER_SECOND = 1_000
    private static let MAX_SHUTDOWN_DELAY_MILLISECONDS = 300_000
    private static let VISIBLE_POLL_NANOSECONDS: UInt64 = 5_000_000_000
    private static let ACTIVE_POLL_NANOSECONDS: UInt64 = 1_000_000_000
    private static let UNKNOWN_POLL_NANOSECONDS: UInt64 = 5_000_000_000

    @Published private(set) var isConfigured = false
    @Published private(set) var configuredHost: String?
    @Published private(set) var isReachable = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusDescription: String?
    @Published private(set) var lastError: String?
    @Published private var pendingAction: DaemonPendingAction?
    @Published private var currentOperation: HostDaemonOperation?
    @Published private var recoveryBlocked = false
    @Published private var shutdownAvailable = false

    private let api: any HostDaemonAPI
    private let pendingStore: any DaemonPendingActionStoring
    private weak var logStore: RollingLogStore?
    private var configuredEndpoint: HostDaemonEndpoint?
    private var verifiedStatus: HostDaemonStatus?
    private var configurationRevision: UInt64 = 0
    private var isInterfaceVisible = false
    private var monitorTask: Task<Void, Never>?
    private var monitorID: UUID?
    private var refreshInProgress = false
    private var actionResultIsDisplayed = false
    private var pendingAcceptanceNeedsPersistence = false

    init(api: any HostDaemonAPI = HostDaemonAPIClient(),
         logStore: RollingLogStore? = nil,
         pendingStore: any DaemonPendingActionStoring = DaemonPendingActionStore()) {
        self.api = api
        self.logStore = logStore
        self.pendingStore = pendingStore
        do {
            pendingAction = try pendingStore.load()
            if let pendingAction {
                statusDescription = pendingAction.osShutdownAccepted == true
                    ? "Shutdown accepted on \(pendingAction.host); waiting for the agent to return."
                    : "Recovering shutdown status on \(pendingAction.host)…"
            }
        } catch {
            recoveryBlocked = true
            let message = "The saved shutdown result could not be restored. Its outcome is unknown. \(error.localizedDescription)"
            lastError = message
            publishLog(message)
        }
        restartMonitoring()
    }

    deinit { monitorTask?.cancel() }

    var hasPendingAction: Bool { pendingAction != nil || recoveryBlocked }
    var isAwaitingHostRestart: Bool { pendingAction?.osShutdownAccepted == true }
    var isCheckingAgent: Bool { isConfigured && verifiedStatus == nil && lastError == nil }
    var canShutdown: Bool {
        isConfigured && isReachable && shutdownAvailable && verifiedStatus != nil
            && !isBusy && !hasPendingAction
    }
    var canCancel: Bool {
        !isAwaitingHostRestart && pendingAction?.operationID != nil && currentOperation?.cancellable == true && !isBusy
    }
    var canAcknowledgeUnknownOutcome: Bool {
        !isBusy && !isAwaitingHostRestart && (recoveryBlocked || pendingAction?.outcomeUnknown == true)
    }

    func configurationDidChange(host: String?, trust: HostDaemonTrust?) {
        let previousHost = configuredHost
        let normalizedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        configuredHost = normalizedHost?.isEmpty == false ? normalizedHost : nil
        let endpoint: HostDaemonEndpoint?
        do {
            if let configuredHost, let trust { endpoint = try HostDaemonEndpoint(host: configuredHost, trust: trust) }
            else { endpoint = nil }
        } catch {
            endpoint = nil
            report(error.localizedDescription)
        }
        guard endpoint != configuredEndpoint || configuredHost != previousHost else { return }
        configuredEndpoint = endpoint
        configurationRevision &+= 1
        isConfigured = endpoint != nil
        isReachable = false
        shutdownAvailable = false
        verifiedStatus = nil
        if !hasPendingAction { statusDescription = nil; lastError = nil; actionResultIsDisplayed = false }
        restartMonitoring()
    }

    /// Excludes mutations while an imported identity or client credential is being changed.
    func beginConfigurationChange() -> Bool {
        guard !isBusy, !hasPendingAction else { return false }
        isBusy = true
        configurationRevision &+= 1
        verifiedStatus = nil
        shutdownAvailable = false
        isReachable = false
        return true
    }

    func endConfigurationChange() {
        configurationRevision &+= 1
        verifiedStatus = nil
        shutdownAvailable = false
        isReachable = false
        isBusy = false
        restartMonitoring()
    }

    func setInterfaceVisible(_ isVisible: Bool) {
        guard isVisible != isInterfaceVisible else { return }
        isInterfaceVisible = isVisible
        if !isVisible {
            configurationRevision &+= 1
            isReachable = false
            shutdownAvailable = false
            verifiedStatus = nil
        }
        restartMonitoring()
    }

    func refresh() async {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        defer { refreshInProgress = false }
        if let pendingAction, !isBusy {
            await refreshPending(pendingAction)
        }
        guard !isBusy, !isAwaitingHostRestart, isInterfaceVisible, let endpoint = configuredEndpoint else { return }
        let revision = configurationRevision
        do {
            let status = try await api.status(endpoint: endpoint)
            try validate(status: status, endpoint: endpoint)
            let modules = try await api.modules(endpoint: endpoint)
            guard !isBusy, revision == configurationRevision, configuredEndpoint == endpoint else { return }
            verifiedStatus = status
            isReachable = true
            let power = modules.first(where: { $0.supportsShutdown })
            let anonymousAllowed = power?.actions.contains {
                $0.id == "shutdown" && $0.allowAnonymous
            } ?? false
            shutdownAvailable = status.readiness != "stopping" && power != nil
                && (status.principalID != "anonymous" || anonymousAllowed)
            if !hasPendingAction && !isBusy && !actionResultIsDisplayed {
                lastError = nil
                statusDescription = shutdownAvailable ? "Agent ready" : "The agent shutdown module is unavailable."
            }
        } catch {
            guard revision == configurationRevision, configuredEndpoint == endpoint else { return }
            isReachable = false
            shutdownAvailable = false
            verifiedStatus = nil
            if !hasPendingAction && !isBusy { report(error.localizedDescription) }
        }
    }

    func shutdown() async {
        guard canShutdown, let endpoint = configuredEndpoint, let status = verifiedStatus else { return }
        isBusy = true
        defer { isBusy = false; restartMonitoring() }
        actionResultIsDisplayed = false
        lastError = nil
        let action = DaemonPendingAction(endpoint: endpoint, requestID: UUID(),
                                         instanceID: status.instanceID, principalID: status.principalID)
        do {
            // Save before sending: a crash or a lost response must not create a fresh action on restart.
            try pendingStore.save(action)
        } catch {
            report("Could not save the shutdown recovery record; no request was sent. \(error.localizedDescription)")
            return
        }
        pendingAction = action
        currentOperation = nil
        statusDescription = "Requesting shutdown on \(endpoint.host)…"
        do {
            let operation = try await api.scheduleShutdown(endpoint: endpoint, requestID: action.requestID,
                instanceID: action.instanceID, delaySeconds: Self.SHUTDOWN_DELAY_SECONDS)
            guard pendingAction?.requestID == action.requestID else { return }
            try accept(operation, for: action)
        } catch {
            guard pendingAction?.requestID == action.requestID else { return }
            if case HostDaemonClientError.api(let problem) = error,
               (400..<500).contains(problem.status) {
                clearRejectedAction(message: error.localizedDescription)
            } else {
                markUnknown("The shutdown response was not confirmed. The computer may still shut down. \(error.localizedDescription)")
            }
        }
    }

    func cancelShutdown() async {
        guard canCancel, let action = pendingAction, let operationID = action.operationID else { return }
        isBusy = true
        defer { isBusy = false; restartMonitoring() }
        lastError = nil
        do {
            let operation = try await api.cancel(endpoint: action.endpoint(), id: operationID,
                                                  instanceID: action.instanceID)
            guard pendingAction?.requestID == action.requestID else { return }
            try accept(operation, for: action)
            if operation.state != "cancelled" {
                markUnknown("The agent did not confirm cancellation. The computer may still shut down.")
            }
        } catch {
            guard pendingAction?.requestID == action.requestID else { return }
            markUnknown("Cancellation was not confirmed. The computer may still shut down. \(error.localizedDescription)")
        }
    }

    /// Explicitly forgets uncertainty; it never cancels or resubmits an OS action.
    func acknowledgeUnknownOutcome() {
        guard canAcknowledgeUnknownOutcome else { return }
        do {
            try pendingStore.remove()
            pendingAction = nil
            currentOperation = nil
            recoveryBlocked = false
            statusDescription = "Unknown result cleared; this does not cancel shutdown."
            actionResultIsDisplayed = true
            lastError = nil
            restartMonitoring()
        } catch { report("Could not clear the saved shutdown result. \(error.localizedDescription)") }
    }

    private func refreshPending(_ action: DaemonPendingAction) async {
        do {
            if action.osShutdownAccepted == true, pendingAcceptanceNeedsPersistence {
                try pendingStore.save(action)
                pendingAcceptanceNeedsPersistence = false
            }
            let endpoint = try action.endpoint()
            if action.osShutdownAccepted != true,
               let operationID = action.operationID, currentOperation?.state != "outcome_unknown" {
                do {
                    let operation = try await api.operation(endpoint: endpoint, id: operationID,
                                                             instanceID: action.instanceID)
                    guard pendingAction?.requestID == action.requestID, !isBusy else { return }
                    try accept(operation, for: action)
                    return
                } catch HostDaemonClientError.api(let problem) where problem.code == "stale_instance" {
                    // Confirm the new instance with authenticated status before releasing the old block.
                }
            }
            let status = try await api.status(endpoint: endpoint)
            try validate(status: status, endpoint: endpoint)
            guard pendingAction?.requestID == action.requestID, !isBusy else { return }
            if action.osShutdownAccepted == true, configuredEndpoint == endpoint {
                isReachable = true
            }
            if status.instanceID != action.instanceID, status.readiness != "stopping" {
                try pendingStore.remove()
                shutdownAvailable = false
                verifiedStatus = nil
                pendingAction = nil
                currentOperation = nil
                pendingAcceptanceNeedsPersistence = false
                actionResultIsDisplayed = true
                if action.osShutdownAccepted == true {
                    lastError = nil
                    statusDescription = "Agent available again on \(action.host)."
                    publishLog("A new agent instance is available after the accepted shutdown on \(action.host).")
                } else {
                    statusDescription = "Agent restarted on \(action.host); the previous shutdown result is unknown."
                    report("The previous agent instance ended. Its shutdown result is unknown; no request was replayed.")
                }
            } else if action.osShutdownAccepted == true {
                statusDescription = "Shutdown accepted on \(action.host); waiting for the agent to restart."
            } else if action.operationID == nil {
                markUnknown("Shutdown outcome on \(action.host) is unknown. No request will be sent again automatically.")
            }
        } catch {
            guard pendingAction?.requestID == action.requestID, !isBusy else { return }
            if isAwaitingHostRestart {
                if configuredEndpoint?.host == action.host, configuredEndpoint?.trust == action.trust {
                    isReachable = false
                }
                statusDescription = "Shutdown accepted on \(action.host); waiting for the agent to return."
                if case HostDaemonClientError.network = error {
                    // Losing the connection is expected during shutdown; keep the durable block.
                    return
                }
            }
            markUnknown("Shutdown status on \(action.host) could not be confirmed. \(error.localizedDescription)")
        }
    }

    private func validate(status: HostDaemonStatus, endpoint: HostDaemonEndpoint) throws {
        guard status.daemonID == endpoint.trust.daemonID else { throw HostDaemonClientError.identityMismatch }
        guard status.apiMajor == 1 else { throw HostDaemonClientError.incompatibleDaemon }
        guard ["ready", "degraded", "stopping"].contains(status.readiness),
              status.principalID == "anonymous" || UUID(uuidString: status.principalID) != nil else {
            throw HostDaemonClientError.invalidResponse
        }
    }

    private func accept(_ operation: HostDaemonOperation, for action: DaemonPendingAction) throws {
        guard operation.requestID == action.requestID, operation.instanceID == action.instanceID,
              action.operationID == nil || operation.id == action.operationID,
              operation.moduleID == "power", operation.action == "shutdown",
              operation.principalID.lowercased() == action.principalID.lowercased(),
              operation.remainingDelayMilliseconds.map({ (0...Self.MAX_SHUTDOWN_DELAY_MILLISECONDS).contains($0) }) ?? true,
              !operation.cancellable || operation.state == "scheduled" else {
            throw HostDaemonClientError.invalidResponse
        }
        var acceptedAction = action
        let osAccepted = operation.state == "succeeded"
        if osAccepted, operation.result?.outcome != "os_accepted" {
            throw HostDaemonClientError.invalidResponse
        }
        if isAwaitingHostRestart, !osAccepted { throw HostDaemonClientError.invalidResponse }
        acceptedAction.operationID = operation.id
        acceptedAction.outcomeUnknown = operation.state == "outcome_unknown"
        acceptedAction.osShutdownAccepted = osAccepted || isAwaitingHostRestart
        // Preserve known OS acceptance in memory even if persisting the response fails.
        pendingAction = acceptedAction
        currentOperation = operation
        if osAccepted {
            shutdownAvailable = false
            verifiedStatus = nil
        }
        pendingAcceptanceNeedsPersistence = acceptedAction.osShutdownAccepted == true
        try pendingStore.save(acceptedAction)
        pendingAcceptanceNeedsPersistence = false
        lastError = nil
        switch operation.state {
        case "scheduled":
            if let remaining = operation.remainingDelayMilliseconds {
                let seconds = (remaining + Self.MILLISECONDS_PER_SECOND - 1) / Self.MILLISECONDS_PER_SECOND
                statusDescription = "Shutdown on \(action.host) in about \(seconds)s"
            } else {
                statusDescription = "Shutdown scheduled on \(action.host)."
            }
        case "running":
            statusDescription = "The agent is requesting shutdown on \(action.host)…"
        case "succeeded":
            statusDescription = "Shutdown accepted on \(action.host); waiting for the agent to restart."
            publishLog("\(action.host) accepted the OS shutdown request; further shutdowns remain blocked.")
        case "cancelled":
            try finish(message: "Shutdown cancelled on \(action.host).")
        case "failed":
            let message = operation.error.map { HostDaemonClientError.api($0).localizedDescription }
                ?? "The shutdown operation failed."
            try finish(message: "Shutdown failed on \(action.host).")
            report(message)
        case "outcome_unknown":
            markUnknown("The shutdown outcome on \(action.host) is unknown. \(operation.error?.detail ?? "")")
        default: throw HostDaemonClientError.invalidResponse
        }
    }

    private func finish(message: String) throws {
        try pendingStore.remove()
        pendingAction = nil
        currentOperation = nil
        statusDescription = message
        actionResultIsDisplayed = true
        publishLog(message)
    }

    private func clearRejectedAction(message: String) {
        do {
            try pendingStore.remove()
            pendingAction = nil
            currentOperation = nil
            statusDescription = "Shutdown request rejected."
            actionResultIsDisplayed = true
            report(message)
        } catch { markUnknown("Could not clear the shutdown recovery record. \(error.localizedDescription)") }
    }

    private func markUnknown(_ message: String) {
        if isAwaitingHostRestart {
            statusDescription = pendingAction.map { "Shutdown accepted on \($0.host); waiting for the agent to return." }
            report(message)
            return
        }
        var diagnostic = message
        if var action = pendingAction {
            action.outcomeUnknown = true
            pendingAction = action
            do { try pendingStore.save(action) }
            catch { diagnostic += " Could not persist the uncertain shutdown result. \(error.localizedDescription)" }
        }
        statusDescription = pendingAction.map { "Shutdown outcome unknown on \($0.host)." }
            ?? "Shutdown outcome unknown."
        report(diagnostic)
    }

    private func restartMonitoring() {
        // Hiding the menu or editing WOL must not cancel an in-flight operation read.
        if pendingAction != nil, monitorTask != nil { return }
        monitorTask?.cancel()
        monitorTask = nil
        monitorID = nil
        guard pendingAction != nil || (isInterfaceVisible && configuredEndpoint != nil) else { return }
        let identifier = UUID()
        monitorID = identifier
        monitorTask = Task { [weak self] in
            defer { self?.monitorFinished(identifier) }
            while !Task.isCancelled {
                await self?.refresh()
                guard !Task.isCancelled else { return }
                guard let delay = self?.nextPollDelay else { return }
                do { try await Task.sleep(nanoseconds: delay) }
                catch is CancellationError { return }
                catch { self?.report("Agent monitoring failed. \(error.localizedDescription)"); return }
            }
        }
    }

    private func monitorFinished(_ identifier: UUID) {
        guard monitorID == identifier else { return }
        monitorTask = nil
        monitorID = nil
    }

    private var nextPollDelay: UInt64? {
        if let pendingAction {
            return pendingAction.outcomeUnknown || pendingAction.osShutdownAccepted == true
                ? Self.UNKNOWN_POLL_NANOSECONDS : Self.ACTIVE_POLL_NANOSECONDS
        }
        return isInterfaceVisible && configuredEndpoint != nil ? Self.VISIBLE_POLL_NANOSECONDS : nil
    }

    private func report(_ message: String) {
        guard lastError != message else { return }
        lastError = message
        publishLog(message)
    }

    private func publishLog(_ message: String) {
        daemonShutdownLogger.info("\(message, privacy: .public)")
        logStore?.append(source: .wol, message: message)
    }
}
