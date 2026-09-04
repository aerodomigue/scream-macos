import Combine
import Foundation
import SwiftUI
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.screambar.app", category: "AppViewModel")

private struct TerminalAudioCleanupFailure: LocalizedError {
    let failures: [String]

    var errorDescription: String? {
        failures.joined(separator: "; ")
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    let logStore = RollingLogStore()
    let jackService: JackService
    let screamService: ScreamService
    let directRoutingService: DirectAudioRoutingService
    let audioModeCoordinator = AudioModeCoordinator()
    let hotkeyService = HotkeyService()
    let usbWatcherService = USBWatcherService()
    private let configurationStore: ConfigurationStore
    private let usbTriggerCommandRunner = USBTriggerCommandRunner()
    private var cancellables = Set<AnyCancellable>()
    private var jackShouldBeRunning = false
    private var crashRecoveryGaveUp = false
    private var isSleeping = false
    private var jackRestartAttempts = 0
    private var pendingRestartTask: Task<Void, Never>?
    private var serviceStartupTask: Task<Void, Never>?
    private var sleepStopTask: Task<Void, Never>?
    private var directRoutingShouldResumeAfterSleep = false
    private var usbTriggerActionRevision: UInt64 = 0
    private var usbStartCommandTask: Task<Void, Never>?
    private(set) var terminalShutdownFailures: [String] = []
    private static let maxJackRestartAttempts = 3
    private static let baseRestartDelaySeconds: UInt64 = 2
    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000
    private static let serviceStopDelayNanoseconds: UInt64 = 500_000_000
    private static let jackInitializationDelayNanoseconds: UInt64 = 1_000_000_000
    private static let wakeSettleDelayNanoseconds: UInt64 = 2_000_000_000

    @Published var configuration: ScreamConfiguration {
        didSet {
            saveConfiguration()
        }
    }

    @Published var applicationMode: ApplicationMode {
        didSet {
            saveConfiguration()
            switchApplicationMode(from: oldValue)
        }
    }

    @Published var directRoutingConfiguration: DirectRoutingConfiguration {
        didSet {
            saveConfiguration()
            directRoutingService.configurationDidChange(directRoutingConfiguration)
        }
    }

    @Published var menuBarDisplayConfiguration: MenuBarDisplayConfiguration {
        didSet {
            saveConfiguration()
        }
    }

    @Published var autoStart: Bool {
        didSet {
            UserDefaults.standard.set(autoStart, forKey: "autoStart")
        }
    }

    @Published var launchAtLogin: Bool = false {
        didSet {
            updateLoginItem()
        }
    }

    @Published private(set) var usbStartCommandError: String?
    @Published private(set) var isUSBStartCommandRunning = false

    var menuBarIcon: String {
        if applicationMode == .directRouting {
            switch directRoutingService.state {
            case .running:
                return "speaker.wave.2.fill"
            case .starting, .reconfiguring, .stopping:
                return "speaker.wave.1.fill"
            case .failed:
                return "speaker.slash.fill"
            case .stopped, .waitingForInput, .waitingForOutput:
                return "speaker.fill"
            }
        }

        let jackActive = jackService.status == .running
        let screamActive = screamService.status == .running

        if jackActive && screamActive {
            return "speaker.wave.2.fill"
        } else if jackActive || screamActive {
            return "speaker.wave.1.fill"
        }

        let hasError: Bool
        if case .error = jackService.status {
            hasError = true
        } else if case .error = screamService.status {
            hasError = true
        } else {
            hasError = false
        }

        if hasError {
            return "speaker.slash.fill"
        }

        return "speaker.fill"
    }

    var menuBarStatusText: String? {
        guard applicationMode == .directRouting else { return nil }
        return MenuBarStatusDescription.make(
            configuration: menuBarDisplayConfiguration,
            routingState: directRoutingService.state
        )
    }

    init() {
        let store = logStore
        let settingsStore = ConfigurationStore(logStore: store)
        let appConfiguration = settingsStore.load()

        self.configurationStore = settingsStore
        self.configuration = appConfiguration.scream
        self.applicationMode = appConfiguration.mode
        self.directRoutingConfiguration = appConfiguration.directRouting
        self.menuBarDisplayConfiguration = appConfiguration.menuBarDisplay
        self.autoStart = UserDefaults.standard.bool(forKey: "autoStart")
        self.jackService = JackService(logStore: store)
        self.screamService = ScreamService(logStore: store)
        self.directRoutingService = DirectAudioRoutingService(logStore: store)

        launchAtLogin = SMAppService.mainApp.status == .enabled

        jackService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        jackService.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newStatus in
                guard let self else { return }
                if case .error(let message) = newStatus {
                    logger.error("JACK entered error state: \(message)")
                    self.handleJackCrash()
                }
            }
            .store(in: &cancellables)

        screamService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        directRoutingService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        directRoutingService.deviceService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        audioModeCoordinator.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        hotkeyService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        usbWatcherService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        hotkeyService.onToggle = { [weak self] in
            guard let self else { return }
            self.logStore.append(source: .app, message: "Hotkey triggered toggle")
            self.toggleActiveMode()
        }

        usbWatcherService.onStart = { [weak self] in
            guard let self else { return }
            self.logStore.append(source: .app, message: "USB trigger — starting")
            self.handleUSBStart()
        }

        usbWatcherService.onStop = { [weak self] in
            guard let self else { return }
            self.logStore.append(source: .app, message: "USB trigger — stopping")
            self.handleUSBStop()
        }

        setupSleepWakeObserver()
        setupApplicationActivationObserver()
        ApplicationTerminationController.shared.viewModel = self

        if autoStart {
            startActiveMode()
        }
    }

    func startActiveMode() {
        guard !audioModeCoordinator.isTransitioning,
              audioModeCoordinator.transitionError == nil,
              !audioModeCoordinator.isShuttingDown else { return }
        startActiveModeUnchecked()
    }

    private func startActiveModeUnchecked() {
        switch applicationMode {
        case .scream:
            startAllUnchecked()
        case .directRouting:
            directRoutingService.start(configuration: directRoutingConfiguration)
        }
    }

    func stopActiveMode(force: Bool = false) {
        switch applicationMode {
        case .scream:
            stopAll(force: force)
        case .directRouting:
            directRoutingService.stop()
        }
    }

    private func handleUSBStart() {
        usbTriggerActionRevision &+= 1
        let revision = usbTriggerActionRevision
        usbStartCommandTask?.cancel()
        isUSBStartCommandRunning = true
        usbStartCommandError = nil

        let command = usbWatcherService.startCommand
        usbStartCommandTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.usbTriggerCommandRunner.run(command)
                self.logUSBCommandOutput(output, phase: "start")
            } catch {
                if let commandError = error as? USBTriggerCommandError {
                    self.logUSBCommandOutput(commandError.output ?? "", phase: "start")
                }
                guard revision == self.usbTriggerActionRevision else { return }
                self.isUSBStartCommandRunning = false
                let message = error.localizedDescription
                self.usbStartCommandError = message
                self.logStore.append(
                    source: .app,
                    message: "USB start command failed: \(message)"
                )
                return
            }

            guard revision == self.usbTriggerActionRevision else { return }
            self.isUSBStartCommandRunning = false
            self.usbStartCommandError = nil
            self.performUSBStartAction()
        }
    }

    private func performUSBStartAction() {
        switch USBTriggerRoutingDecision.startAction(
            mode: applicationMode,
            screamToggleScope: configuration.toggleScope
        ) {
        case .screamOnly:
            startScream()
        case .screamAndJack:
            startAll()
        case .directRouting:
            startActiveMode()
        }
    }

    private func handleUSBStop() {
        usbTriggerActionRevision &+= 1
        usbStartCommandTask?.cancel()
        isUSBStartCommandRunning = false
        performUSBStopAction()

        let command = usbWatcherService.stopCommand
        Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await self.usbTriggerCommandRunner.run(command)
                self.logUSBCommandOutput(output, phase: "stop")
            } catch {
                if let commandError = error as? USBTriggerCommandError {
                    self.logUSBCommandOutput(commandError.output ?? "", phase: "stop")
                }
                self.logStore.append(
                    source: .app,
                    message: "USB stop command failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func logUSBCommandOutput(_ output: String, phase: String) {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        logStore.append(source: .app, message: "USB \(phase) command output:\n\(output)")
    }

    private func performUSBStopAction() {
        switch USBTriggerRoutingDecision.stopAction(
            mode: applicationMode,
            screamToggleScope: configuration.toggleScope
        ) {
        case .screamOnly:
            stopScream()
        case .screamAndJack:
            stopAll()
        case .directRouting:
            stopActiveMode()
        }
    }

    func toggleActiveMode() {
        switch applicationMode {
        case .scream:
            if configuration.toggleScope == .all {
                toggleAll()
            } else {
                toggleScream()
            }
        case .directRouting:
            if directRoutingService.desiredRunning {
                directRoutingService.stop()
            } else {
                startActiveMode()
            }
        }
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    func toggleScream() {
        if screamService.status == .running {
            stopScream()
        } else {
            startScream()
        }
    }

    func toggleAll() {
        if screamService.status == .running || jackService.status == .running {
            stopAll()
        } else {
            startAll()
        }
    }

    func startScream() {
        guard canStartScreamRuntime else { return }
        guard jackService.status == .running else {
            logStore.append(source: .app, message: "JACK not running, cannot start Scream")
            return
        }
        logStore.append(source: .app, message: "Starting Scream")
        screamService.start(configuration: configuration)
    }

    func startJack() {
        guard canStartScreamRuntime else { return }
        jackService.start(configuration: configuration)
    }

    func stopScream() {
        logStore.append(source: .app, message: "Stopping Scream")
        screamService.stop()
    }

    func startAll(resetCrashCounter: Bool = true) {
        guard canStartScreamRuntime else { return }
        startAllUnchecked(resetCrashCounter: resetCrashCounter)
    }

    private func startAllUnchecked(resetCrashCounter: Bool = true) {
        jackShouldBeRunning = true
        crashRecoveryGaveUp = false
        if resetCrashCounter { jackRestartAttempts = 0 }
        logStore.append(source: .app, message: "Starting all services")

        jackService.start(configuration: configuration)

        guard jackService.status == .running else {
            logStore.append(source: .app, message: "JACK failed to start, aborting")
            return
        }

        // Give JACK time to initialize, then verify it's still running
        serviceStartupTask?.cancel()
        serviceStartupTask = Task {
            guard await wait(
                nanoseconds: Self.serviceStopDelayNanoseconds,
                operation: "JACK startup probe"
            ) else { return }

            guard applicationMode == .scream,
                  jackShouldBeRunning,
                  !audioModeCoordinator.isTransitioning else { return }

            guard jackService.isProcessRunning || jackService.status == .running else {
                logStore.append(source: .app, message: "JACK crashed during startup, aborting")
                return
            }

            // Extra settle time for JACK server initialization
            guard await wait(
                nanoseconds: Self.jackInitializationDelayNanoseconds,
                operation: "JACK initialization"
            ) else { return }

            guard applicationMode == .scream,
                  jackShouldBeRunning,
                  !audioModeCoordinator.isTransitioning else { return }

            guard jackService.isProcessRunning || jackService.status == .running else {
                logStore.append(source: .app, message: "JACK crashed during initialization, aborting")
                return
            }

            screamService.start(configuration: configuration)
        }
    }

    private var canStartScreamRuntime: Bool {
        applicationMode == .scream
            && !audioModeCoordinator.isTransitioning
            && audioModeCoordinator.transitionError == nil
            && !audioModeCoordinator.isShuttingDown
    }

    func stopAll(force: Bool = false) {
        jackShouldBeRunning = false
        crashRecoveryGaveUp = false
        pendingRestartTask?.cancel()
        pendingRestartTask = nil
        serviceStartupTask?.cancel()
        serviceStartupTask = nil
        sleepStopTask?.cancel()
        sleepStopTask = nil
        jackRestartAttempts = 0
        logStore.append(source: .app, message: force ? "Stopping all services (force)" : "Stopping all services")
        screamService.stop()

        Task {
            guard await wait(
                nanoseconds: Self.serviceStopDelayNanoseconds,
                operation: "Scream shutdown"
            ) else { return }
            if force {
                jackService.forceStop()
            } else {
                jackService.stop()
            }
        }
    }

    private func setupApplicationActivationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.directRoutingService.revalidatePermissionIfRunning()
            }
        }
    }

    func performTerminalShutdown() async {
        pendingRestartTask?.cancel()
        pendingRestartTask = nil
        serviceStartupTask?.cancel()
        serviceStartupTask = nil
        sleepStopTask?.cancel()
        sleepStopTask = nil
        jackShouldBeRunning = false

        terminalShutdownFailures = await audioModeCoordinator.beginShutdown {
            var failures: [String] = []
            do {
                try await self.screamService.stopAndWait()
            } catch {
                failures.append("Scream: \(error.localizedDescription)")
            }
            do {
                try await self.jackService.stopAndWait()
            } catch {
                failures.append("JACK: \(error.localizedDescription)")
            }
            failures.append(contentsOf: await self.directRoutingService.shutdownAndWait())
            guard failures.isEmpty else {
                throw TerminalAudioCleanupFailure(failures: failures)
            }
        }
        terminalShutdownFailures.forEach {
            logStore.append(source: .app, message: "Terminal cleanup failed: \($0)")
        }
    }

    private func setupSleepWakeObserver() {
        let center = NSWorkspace.shared.notificationCenter

        center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.audioModeCoordinator.isShuttingDown else { return }
                logger.info("System going to sleep")
                self.logStore.append(source: .app, message: "System going to sleep")
                self.isSleeping = true
                if self.applicationMode == .directRouting {
                    self.directRoutingShouldResumeAfterSleep = self.directRoutingService.desiredRunning
                    if self.directRoutingShouldResumeAfterSleep {
                        self.directRoutingService.stop()
                    }
                } else if self.jackShouldBeRunning {
                    self.stopServicesForSleep()
                }
            }
        }

        center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.audioModeCoordinator.isShuttingDown else { return }
                logger.info("System woke up")
                self.logStore.append(source: .app, message: "System woke up")
                self.sleepStopTask?.cancel()
                self.sleepStopTask = nil
                // Keep isSleeping = true during the settle period to prevent handleJackCrash
                // from triggering premature restarts while we prepare the wake sequence
                self.jackRestartAttempts = 0
                self.crashRecoveryGaveUp = false
                if self.applicationMode == .directRouting {
                    self.isSleeping = false
                    if self.directRoutingShouldResumeAfterSleep {
                        self.directRoutingShouldResumeAfterSleep = false
                        self.directRoutingService.start(
                            configuration: self.directRoutingConfiguration
                        )
                    }
                } else if self.jackShouldBeRunning {
                    // Wait for CoreAudio to reinitialize after wake
                    guard await self.wait(
                        nanoseconds: Self.wakeSettleDelayNanoseconds,
                        operation: "CoreAudio wake settle"
                    ) else { return }
                    self.logStore.append(source: .app, message: "Restarting services after wake")
                    // Force-clean state before restart to handle lingering processes
                    self.screamService.prepareForWakeRestart()
                    self.jackService.prepareForWakeRestart()
                    guard await self.wait(
                        nanoseconds: Self.serviceStopDelayNanoseconds,
                        operation: "JACK wake cleanup"
                    ) else { return }
                    self.isSleeping = false
                    self.startAll()
                } else {
                    self.isSleeping = false
                }
            }
        }
    }

    private func handleJackCrash() {
        guard jackShouldBeRunning,
              !isSleeping,
              !crashRecoveryGaveUp,
              !audioModeCoordinator.isShuttingDown else { return }
        guard jackRestartAttempts < Self.maxJackRestartAttempts else {
            logStore.append(source: .app, message: "JACK restart limit reached (\(Self.maxJackRestartAttempts) attempts), giving up until next wake")
            crashRecoveryGaveUp = true
            return
        }
        jackRestartAttempts += 1
        let delaySeconds = Self.baseRestartDelaySeconds * UInt64(jackRestartAttempts)
        logStore.append(source: .app, message: "JACK crashed, restarting in \(delaySeconds)s (attempt \(jackRestartAttempts)/\(Self.maxJackRestartAttempts))")
        pendingRestartTask?.cancel()
        pendingRestartTask = Task {
            guard await wait(
                nanoseconds: delaySeconds * Self.nanosecondsPerSecond,
                operation: "JACK crash recovery"
            ) else { return }
            guard !Task.isCancelled, jackShouldBeRunning, !isSleeping, !crashRecoveryGaveUp else { return }
            startAll(resetCrashCounter: false)
        }
    }

    private func stopServicesForSleep() {
        pendingRestartTask?.cancel()
        pendingRestartTask = nil
        logStore.append(source: .app, message: "Stopping services for sleep")
        screamService.stop()
        sleepStopTask = Task {
            guard await wait(
                nanoseconds: Self.serviceStopDelayNanoseconds,
                operation: "sleep shutdown"
            ) else { return }
            guard !Task.isCancelled else { return }
            jackService.stop()
        }
    }

    private func saveConfiguration() {
        configurationStore.save(
            AppConfiguration(
                mode: applicationMode,
                scream: configuration,
                directRouting: directRoutingConfiguration,
                menuBarDisplay: menuBarDisplayConfiguration
            )
        )
    }

    private func wait(nanoseconds: UInt64, operation: String) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.error("\(operation, privacy: .public) wait failed: \(error.localizedDescription, privacy: .public)")
            logStore.append(
                source: .app,
                message: "\(operation) wait failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func switchApplicationMode(from previousMode: ApplicationMode) {
        guard previousMode != applicationMode else { return }

        let shouldContinueRunning: Bool
        let stopPreviousMode: AudioModeCoordinator.CleanupOperation
        switch previousMode {
        case .scream:
            shouldContinueRunning = jackShouldBeRunning
                || jackService.status.isActive
                || screamService.status.isActive
            pendingRestartTask?.cancel()
            sleepStopTask?.cancel()
            serviceStartupTask?.cancel()
            serviceStartupTask = nil
            jackShouldBeRunning = false
            stopPreviousMode = { [weak self] in
                guard let self else { return }
                try await self.screamService.stopAndWait()
                try await self.jackService.stopAndWait()
            }
        case .directRouting:
            shouldContinueRunning = directRoutingService.desiredRunning
            stopPreviousMode = { [weak self] in
                guard let self else { return }
                try await self.directRoutingService.stopAndWait()
            }
        }

        logStore.append(
            source: .app,
            message: "Switched mode from \(previousMode.label) to \(applicationMode.label)"
        )
        let targetMode = applicationMode
        audioModeCoordinator.transition(
            from: previousMode,
            to: targetMode,
            shouldStartTarget: shouldContinueRunning,
            stopSource: stopPreviousMode,
            startTarget: { [weak self] in
                guard let self, self.applicationMode == targetMode else { return }
                self.startActiveModeUnchecked()
            }
        )
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Failed to update login item: \(error.localizedDescription)")
            logStore.append(source: .app, message: "Failed to update login item: \(error.localizedDescription)")
        }
    }
}
