import Foundation
import os

private let logger = Logger(subsystem: "com.screambar.app", category: "JackService")

@MainActor
final class JackService: ObservableObject {
    static let jackdPath = "/opt/homebrew/bin/jackd"

    @Published private(set) var status: ProcessStatus = .stopped
    @Published private(set) var isInstalled: Bool = false

    private let processManager = ProcessManager()
    private weak var logStore: RollingLogStore?
    private var weStartedJack = false

    init(logStore: RollingLogStore) {
        self.logStore = logStore
        isInstalled = FileManager.default.fileExists(atPath: Self.jackdPath)

        processManager.onOutput = { [weak self] text in
            Task { @MainActor in
                self?.logStore?.append(source: .jack, message: text)
            }
        }

        processManager.onTermination = { [weak self] exitStatus in
            Task { @MainActor in
                guard let self else { return }
                if case .stopping = self.status {
                    self.status = .stopped
                } else if self.weStartedJack {
                    self.status = .error("jackd exited with code \(exitStatus)")
                    self.logStore?.append(source: .jack, message: "jackd exited unexpectedly with code \(exitStatus)")
                } else {
                    self.status = .stopped
                }
            }
        }
    }

    /// Check if an external jackd is already running (only called at app launch).
    func checkExternalJack() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "jackd"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    func start(configuration: ScreamConfiguration) {
        guard isInstalled else {
            status = .error("jackd not found at \(Self.jackdPath)")
            return
        }

        if checkExternalJack() {
            logger.info("External JACK server detected, attaching")
            logStore?.append(source: .jack, message: "External JACK server detected — attaching (will stop on request)")
            weStartedJack = false
            status = .running
            return
        }

        status = .starting
        cleanStaleMetadata()
        let arguments = configuration.buildJackArguments()
        logStore?.append(source: .jack, message: "Starting jackd \(arguments.joined(separator: " "))")

        do {
            try processManager.start(
                executablePath: Self.jackdPath,
                arguments: arguments
            )
            status = .running
            weStartedJack = true
        } catch {
            status = .error(error.localizedDescription)
            logStore?.append(source: .jack, message: "Failed to start jackd: \(error.localizedDescription)")
        }
    }

    func stop() {
        status = .stopping
        logStore?.append(source: .jack, message: "Stopping jackd")
        if weStartedJack {
            processManager.stop()
        } else {
            pkill(signal: "-TERM")
            weStartedJack = false
            status = .stopped
        }
    }

    /// Force-kill any running jackd immediately (shift-click or urgent stop).
    func forceStop() {
        logStore?.append(source: .jack, message: "Force-stopping jackd")
        status = .stopping
        if weStartedJack {
            processManager.forceTerminate()
        } else {
            pkill(signal: "-9")
        }
        weStartedJack = false
        status = .stopped
    }

    func terminateNow() {
        status = .stopping
        if weStartedJack {
            processManager.forceTerminate()
        } else {
            pkill(signal: "-9")
        }
        weStartedJack = false
        status = .stopped
    }

    func prepareForWakeRestart() {
        status = .stopping
        processManager.forceTerminate()
        pkill(signal: "-9")
        weStartedJack = false
        status = .stopped
        logStore?.append(source: .jack, message: "Force-killed lingering jackd for wake restart")
    }

    var isProcessRunning: Bool {
        processManager.isRunning
    }

    private func pkill(signal: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = [signal, "-f", "jackd"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
    }

    private func cleanStaleMetadata() {
        let dbDir = "/tmp/jack_db-\(getuid())"
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: dbDir) else { return }
        do {
            try fileManager.removeItem(atPath: dbDir)
            logger.info("Removed stale JACK metadata at \(dbDir)")
            logStore?.append(source: .jack, message: "Cleaned stale metadata DB")
        } catch {
            logger.warning("Failed to remove JACK metadata: \(error.localizedDescription)")
        }
    }
}
