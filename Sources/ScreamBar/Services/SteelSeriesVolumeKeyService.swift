import Combine
import Foundation

@MainActor
final class SteelSeriesVolumeKeyService: ObservableObject {
    enum VolumeDisplay: Hashable { case mainStatus, headsetPopover }
    private static let DISPLAY_REFRESH_INTERVAL: TimeInterval = 1
    private static let BURST_QUIET_INTERVAL: TimeInterval = 0.15
    private static let MINIMUM_LOG_INTERVAL: TimeInterval = 30
    private static let TRANSPORT_RETRY_INTERVAL: TimeInterval = 1
    private static let FEEDBACK_RETRY_INTERVAL: TimeInterval = 1
    private static let OMNI_DEVICE_NAME = "Arctis Nova Pro Omni"

    @Published private(set) var statusText = "Volume keys inactive"
    @Published private(set) var needsPermission = false
    @Published private(set) var volume: SteelSeriesVolume?
    @Published private(set) var isMuted = false
    // Key presses show feedback; ordinary USB polls only update an already visible HUD.
    let keyFeedback = PassthroughSubject<Bool, Never>()
    var volumeText: String { volume.map { isMuted ? "Muted · \($0.percentage)%" : "\($0.percentage)%" } ?? "—" }
    private let transport: SteelSeriesVolumeAdjusting
    private let monitor: VolumeKeyMonitoring
    private let feedback: VolumeFeedbackPlaying
    private weak var logStore: RollingLogStore?
    private var enabled = false
    private var connected = false
    private var outputUID: String?
    private var ready = false
    private var pendingActions = SteelSeriesVolumeActions()
    private var confirmedState: SteelSeriesPlaybackState?
    private var displayState: SteelSeriesPlaybackState?
    private var canHandleKeys: Bool { enabled && connected && ready && outputUID != nil }
    private var volumeRevision: UInt64 = 0
    private var isRefreshingVolume = false
    private var readRequest: SteelSeriesVolumeRequest?
    private var operation: Task<Void, Never>?
    private var activeRequest: SteelSeriesVolumeRequest?
    private var burstVolume: SteelSeriesVolume?
    private var readbackTask: Task<Void, Never>?
    private var lastKeyTime: TimeInterval = 0
    private var generation: UInt64 = 0
    private var lastFailureLog: Date = .distantPast
    private var retryAfter: TimeInterval = 0
    private var feedbackRetryAfter: TimeInterval = 0
    private var feedbackRevision: UInt64 = 0
    private var lastFeedbackFailureLog: Date = .distantPast
    private var visibleDisplays = Set<VolumeDisplay>()
    private var displayPolling: Task<Void, Never>?
    private var lastReadTime: TimeInterval = -.infinity
    private let refreshInterval: TimeInterval

    init(transport: SteelSeriesVolumeAdjusting, logStore: RollingLogStore,
         monitor: VolumeKeyMonitoring? = nil,
         feedback: VolumeFeedbackPlaying? = nil,
         refreshInterval: TimeInterval? = nil) {
        self.transport = transport
        self.logStore = logStore
        self.monitor = monitor ?? VolumeKeyMonitor()
        self.feedback = feedback ?? VolumeFeedbackSoundService()
        self.refreshInterval = refreshInterval ?? Self.DISPLAY_REFRESH_INTERVAL
        precondition(self.refreshInterval.isFinite && self.refreshInterval > 0)
        self.monitor.onStep = { [weak self] steps in self?.enqueue(steps) ?? false }
        self.monitor.onMute = { [weak self] in self?.enqueueMute() ?? false }
        self.monitor.canHandleMute = { [weak self] in self?.canHandleKeys ?? false }
    }

    deinit {
        readRequest?.cancel()
        activeRequest?.cancel()
        operation?.cancel()
        readbackTask?.cancel()
        displayPolling?.cancel()
    }

    func update(enabled: Bool, connected: Bool) {
        self.enabled = enabled
        self.connected = connected
        if !enabled || !connected {
            volumeRevision &+= 1
            readRequest?.cancel()
            publishVolume(nil)
        }
        refresh()
        updateDisplayPolling()
    }

    func setDisplayVisible(_ display: VolumeDisplay, visible: Bool) {
        if visible { visibleDisplays.insert(display) } else { visibleDisplays.remove(display) }
        updateDisplayPolling()
    }

    private func updateDisplayPolling() {
        guard enabled, connected, !visibleDisplays.isEmpty else {
            displayPolling?.cancel()
            displayPolling = nil
            return
        }
        guard displayPolling == nil else { return }
        let interval = UInt64(refreshInterval * Double(NSEC_PER_SEC))
        displayPolling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshVolume()
                do { try await Task.sleep(nanoseconds: interval) }
                catch { return }
            }
        }
    }

    func updateOutput(_ snapshot: AudioHardwareSnapshot) {
        let output = snapshot.defaultOutputUID.flatMap { snapshot.device(withUID: $0) }
        let selectedUID = output.flatMap {
            $0.isAlive && $0.supportsOutput && $0.name == Self.OMNI_DEVICE_NAME ? $0.id.rawValue : nil
        }
        if selectedUID != outputUID {
            cancelPending()
            outputUID = selectedUID
        }
        refresh()
    }

    func refreshVolume(force: Bool = false) async {
        guard enabled, connected, activeRequest == nil, operation == nil, !isRefreshingVolume, !Task.isCancelled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastReadTime >= refreshInterval else { return }
        lastReadTime = now
        isRefreshingVolume = true
        let revision = volumeRevision
        let request = SteelSeriesVolumeRequest()
        readRequest = request
        defer {
            isRefreshingVolume = false
            readRequest = nil
        }
        do {
            let snapshot = try await transport.readVolume(request: request)
            guard enabled, connected, volumeRevision == revision, !Task.isCancelled else { return }
            let state = confirmedState?.reconciled(with: snapshot) ?? SteelSeriesPlaybackState(volume: snapshot)
            confirmedState = state
            publishState(state)
        } catch is CancellationError {
            return
        } catch {
            guard volumeRevision == revision else { return }
            feedback.silence()
            publishVolume(nil)
            logFailure("SteelSeries volume read: \(error.localizedDescription)")
        }
    }

    func requestPermission() {
        monitor.requestPermission()
        refresh()
    }

    func revalidatePermission() { refresh() }

    private func refresh() {
        ready = false
        publishPermission(enabled && !monitor.hasPermission)
        guard enabled, connected, outputUID != nil else {
            cancelPending()
            monitor.stop()
            publishStatus(!enabled ? "Volume keys inactive"
                : !connected ? "Connect the headset to use volume keys"
                : "Select Omni as the Mac sound output to use volume keys")
            return
        }
        guard monitor.hasPermission else {
            cancelPending()
            monitor.stop()
            publishStatus("Allow Accessibility access to use Volume + / −")
            return
        }
        ready = monitor.start()
        publishPermission(!ready)
        if !ready { cancelPending() }
        publishStatus(ready ? "Volume + / − and Mute control the base" : "Could not enable volume keys; check Accessibility access")
        if ready, let outputUID, ProcessInfo.processInfo.systemUptime >= feedbackRetryAfter {
            do { try feedback.prepare(outputUID: outputUID) }
            catch { logFeedbackFailure(error) }
        }
    }

    @discardableResult
    func enqueue(_ steps: Int) -> Bool {
        guard canHandleKeys, steps == 1 || steps == -1 else { return false }
        guard ProcessInfo.processInfo.systemUptime >= retryAfter else { return true }
        guard pendingActions.append(step: steps) else { return handleOverflow() }
        var change = SteelSeriesVolumeChange()
        change.append(steps)
        beginAction(.adjust(change))
        return true
    }

    @discardableResult
    func enqueueMute() -> Bool {
        guard canHandleKeys else { return false }
        feedbackRevision &+= 1
        feedback.silence()
        guard ProcessInfo.processInfo.systemUptime >= retryAfter else { return true }
        guard pendingActions.appendMute() else { return handleOverflow() }
        beginAction(.toggleMute)
        return true
    }

    private func handleOverflow() -> Bool {
        let message = "Volume input queue is full; excess input ignored"
        publishStatus(message)
        logFailure(message)
        // Never forward an overloaded mute press to CoreAudio.
        return true
    }

    private func beginAction(_ action: SteelSeriesVolumeAction) {
        guard let outputUID else { return }
        volumeRevision &+= 1
        readRequest?.cancel()
        readbackTask?.cancel()
        readbackTask = nil
        lastKeyTime = ProcessInfo.processInfo.systemUptime
        if let displayState { publishState(displayState.applying(action)) }
        keyFeedback.send(true)
        guard operation == nil else { return }
        let request = activeRequest ?? SteelSeriesVolumeRequest(outputUID: outputUID)
        activeRequest = request
        let currentGeneration = generation
        operation = Task { [weak self] in
            while let self, !Task.isCancelled, generation == currentGeneration, !pendingActions.isEmpty {
                do {
                    if burstVolume == nil {
                        let observed = try await transport.readVolume(request: request)
                        guard generation == currentGeneration else { return }
                        let state = confirmedState?.reconciled(with: observed) ?? SteelSeriesPlaybackState(volume: observed)
                        confirmedState = state
                        burstVolume = observed
                        publishState(pendingActions.applying(to: state))
                        continue
                    }
                    guard let current = confirmedState, let action = pendingActions.popFirst() else { break }
                    let currentFeedbackRevision = feedbackRevision
                    let target = current.applying(action)
                    let applied = target.volume == current.volume ? current.volume
                        : try await transport.adjustVolume(SteelSeriesVolumeChange(target: target.volume),
                                                          from: current.volume, request: request)
                    guard generation == currentGeneration else { return }
                    let state = target.reconciled(with: applied)
                    confirmedState = state
                    burstVolume = applied
                    publishState(pendingActions.applying(to: state))
                    if case .adjust = action, applied != current.volume, applied.percentage > 0,
                       currentFeedbackRevision == feedbackRevision, !pendingActions.containsMute,
                       ProcessInfo.processInfo.systemUptime >= feedbackRetryAfter {
                        do { try feedback.play(request: request) }
                        catch is CancellationError { feedback.stop() }
                        catch { logFeedbackFailure(error) }
                    }
                } catch is CancellationError {
                    guard generation == currentGeneration else { return }
                    burstVolume = nil
                    confirmedState = nil
                    feedback.stop()
                    break
                } catch {
                    guard generation == currentGeneration else { return }
                    publishStatus("Volume keys: \(error.localizedDescription)")
                    // Keep consuming mute while eligible, even if USB temporarily fails.
                    retryAfter = ProcessInfo.processInfo.systemUptime + Self.TRANSPORT_RETRY_INTERVAL
                    keyFeedback.send(false)
                    feedback.silence()
                    publishVolume(nil)
                    burstVolume = nil
                    logFailure(statusText)
                    break
                }
            }
            guard let self, generation == currentGeneration else { return }
            pendingActions = SteelSeriesVolumeActions()
            operation = nil
            scheduleReadback(request: request, generation: currentGeneration)
        }
    }

    private func scheduleReadback(request: SteelSeriesVolumeRequest, generation: UInt64) {
        let elapsed = ProcessInfo.processInfo.systemUptime - lastKeyTime
        let remaining = max(0, Self.BURST_QUIET_INTERVAL - elapsed)
        readbackTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * Double(NSEC_PER_SEC))) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == generation,
                  activeRequest === request, operation == nil else { return }
            activeRequest = nil
            burstVolume = nil
            readbackTask = nil
            await refreshVolume(force: true)
        }
    }

    private func publishVolume(_ snapshot: SteelSeriesVolume?) {
        if snapshot == nil {
            displayState = nil
            if isMuted { isMuted = false }
        }
        if volume != snapshot { volume = snapshot }
    }

    private func publishState(_ state: SteelSeriesPlaybackState) {
        displayState = state
        if isMuted != state.isMuted { isMuted = state.isMuted }
        publishVolume(state.volume)
    }

    private func publishStatus(_ message: String) {
        if statusText != message { statusText = message }
    }

    private func publishPermission(_ required: Bool) {
        if needsPermission != required { needsPermission = required }
    }

    private func logFailure(_ message: String) {
        guard Date().timeIntervalSince(lastFailureLog) >= Self.MINIMUM_LOG_INTERVAL else { return }
        lastFailureLog = Date()
        logStore?.append(source: .app, message: message)
    }

    private func logFeedbackFailure(_ error: Error) {
        feedback.stop()
        feedbackRetryAfter = ProcessInfo.processInfo.systemUptime + Self.FEEDBACK_RETRY_INTERVAL
        guard Date().timeIntervalSince(lastFeedbackFailureLog) >= Self.MINIMUM_LOG_INTERVAL else { return }
        lastFeedbackFailureLog = Date()
        logStore?.append(source: .app, message: "Volume feedback: \(error.localizedDescription)")
    }

    private func cancelPending() {
        keyFeedback.send(false)
        feedbackRevision &+= 1
        feedback.stop()
        feedbackRetryAfter = 0
        volumeRevision &+= 1
        generation &+= 1
        ready = false
        pendingActions = SteelSeriesVolumeActions()
        activeRequest?.cancel()
        activeRequest = nil
        operation?.cancel()
        operation = nil
        readbackTask?.cancel()
        readbackTask = nil
        burstVolume = nil
        confirmedState = nil
        retryAfter = 0
        if let volume { publishState(SteelSeriesPlaybackState(volume: volume)) }
    }
}
