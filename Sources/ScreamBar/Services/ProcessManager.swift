import Foundation
import os

private let logger = Logger(subsystem: "com.screambar.app", category: "ProcessManager")

final class ProcessManager: @unchecked Sendable {
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private let lock = NSLock()

    private(set) var isRunning: Bool = false
    var pid: Int32? { process?.processIdentifier }

    var onOutput: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?

    func start(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else {
            logger.warning("Process already running, ignoring start request")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        if let environment {
            proc.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        setupOutputHandler(pipe: stdout)
        setupOutputHandler(pipe: stderr)

        proc.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            self.isRunning = false
            self.lock.unlock()
            let status = process.terminationStatus
            logger.info("Process terminated with status \(status)")
            self.onTermination?(status)
        }

        try proc.run()
        isRunning = true
        process = proc
        stdoutPipe = stdout
        stderrPipe = stderr

        logger.info("Started process PID=\(proc.processIdentifier) path=\(executablePath)")
    }

    func stop() {
        lock.lock()
        guard let proc = process, isRunning else {
            lock.unlock()
            return
        }
        lock.unlock()

        logger.info("Sending SIGTERM to PID=\(proc.processIdentifier)")
        proc.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = self.isRunning
            self.lock.unlock()

            if stillRunning {
                logger.warning("Process did not terminate after 3s, sending SIGKILL")
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    private func setupOutputHandler(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onOutput?(text)
        }
    }
}
