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
                } else {
                    self.status = .error("jackd exited with code \(exitStatus)")
                    self.logStore?.append(source: .jack, message: "jackd exited unexpectedly with code \(exitStatus)")
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

    func start() {
        guard isInstalled else {
            status = .error("jackd not found at \(Self.jackdPath)")
            return
        }

        if checkExternalJack() {
            logger.info("External JACK server detected, attaching")
            logStore?.append(source: .jack, message: "External JACK server detected — not managing lifecycle")
            weStartedJack = false
            status = .running
            return
        }

        status = .starting
        logStore?.append(source: .jack, message: "Starting jackd -d coreaudio")

        do {
            try processManager.start(
                executablePath: Self.jackdPath,
                arguments: ["-d", "coreaudio"]
            )
            status = .running
            weStartedJack = true
        } catch {
            status = .error(error.localizedDescription)
            logStore?.append(source: .jack, message: "Failed to start jackd: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard weStartedJack else {
            logStore?.append(source: .jack, message: "JACK was not started by us, skipping stop")
            status = .stopped
            return
        }

        status = .stopping
        logStore?.append(source: .jack, message: "Stopping jackd")
        processManager.stop()
    }

    var isProcessRunning: Bool {
        processManager.isRunning
    }
}
