import Combine
import Foundation
import SwiftUI
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.screambar.app", category: "AppViewModel")

private let configurationUserDefaultsKey = "screamConfiguration"

@MainActor
final class AppViewModel: ObservableObject {
    let logStore = RollingLogStore()
    let jackService: JackService
    let screamService: ScreamService
    let hotkeyService = HotkeyService()
    let usbWatcherService = USBWatcherService()
    private var cancellables = Set<AnyCancellable>()
    private var wasRunningBeforeSleep = false

    @Published var configuration: ScreamConfiguration {
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

    var menuBarIcon: String {
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

    init() {
        let store = logStore
        let config = Self.loadConfiguration()

        self.configuration = config
        self.autoStart = UserDefaults.standard.bool(forKey: "autoStart")
        self.jackService = JackService(logStore: store)
        self.screamService = ScreamService(logStore: store)

        launchAtLogin = SMAppService.mainApp.status == .enabled

        jackService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        screamService.objectWillChange
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
            self.toggleScream()
        }

        usbWatcherService.onStart = { [weak self] in
            guard let self else { return }
            self.logStore.append(source: .app, message: "USB trigger — starting Scream")
            self.startScream()
        }

        usbWatcherService.onStop = { [weak self] in
            guard let self else { return }
            self.logStore.append(source: .app, message: "USB trigger — stopping Scream")
            self.stopScream()
        }

        setupTerminationObserver()
        setupSleepWakeObserver()

        if autoStart {
            startAll()
        }
    }

    func toggleScream() {
        if screamService.status == .running {
            stopScream()
        } else {
            startScream()
        }
    }

    func startScream() {
        guard jackService.status == .running else {
            logStore.append(source: .app, message: "JACK not running, cannot start Scream")
            return
        }
        logStore.append(source: .app, message: "Starting Scream")
        screamService.start(configuration: configuration)
    }

    func stopScream() {
        logStore.append(source: .app, message: "Stopping Scream")
        screamService.stop()
    }

    func startAll() {
        logStore.append(source: .app, message: "Starting all services")

        jackService.start()

        guard jackService.status == .running else {
            logStore.append(source: .app, message: "JACK failed to start, aborting")
            return
        }

        // Give JACK time to initialize, then verify it's still running
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s

            guard jackService.isProcessRunning || jackService.status == .running else {
                logStore.append(source: .app, message: "JACK crashed during startup, aborting")
                return
            }

            // Extra settle time for JACK server initialization
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s

            guard jackService.isProcessRunning || jackService.status == .running else {
                logStore.append(source: .app, message: "JACK crashed during initialization, aborting")
                return
            }

            screamService.start(configuration: configuration)
        }
    }

    func stopAll() {
        logStore.append(source: .app, message: "Stopping all services")
        screamService.stop()

        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            jackService.stop()
        }
    }

    private func setupTerminationObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.screamService.stop()
                self.jackService.stop()
            }
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
                logger.info("System going to sleep")
                self.logStore.append(source: .app, message: "System going to sleep")
                if self.jackService.status == .running {
                    self.wasRunningBeforeSleep = true
                    self.stopAll()
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
                logger.info("System woke up")
                self.logStore.append(source: .app, message: "System woke up")
                if self.wasRunningBeforeSleep {
                    self.wasRunningBeforeSleep = false
                    // Wait for CoreAudio to reinitialize
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.logStore.append(source: .app, message: "Restarting services after wake")
                    self.startAll()
                }
            }
        }
    }

    private func saveConfiguration() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: configurationUserDefaultsKey)
    }

    private static func loadConfiguration() -> ScreamConfiguration {
        guard let data = UserDefaults.standard.data(forKey: configurationUserDefaultsKey),
              let config = try? JSONDecoder().decode(ScreamConfiguration.self, from: data) else {
            return ScreamConfiguration()
        }
        return config
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
