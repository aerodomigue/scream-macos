import Foundation
import os

private let logger = Logger(subsystem: "com.screambar.app", category: "ProcessManager")

enum ProcessTerminationFailure: LocalizedError {
    case timedOut(pid: Int32)
    case signalFailed(pid: Int32, signal: Int32, errorCode: Int32)

    var errorDescription: String? {
        switch self {
        case .timedOut(let pid):
            return "Process \(pid) did not terminate within the bounded shutdown interval"
        case .signalFailed(let pid, let signal, let errorCode):
            return "Failed to send signal \(signal) to process \(pid) (errno \(errorCode))"
        }
    }
}

final class ProcessManager: @unchecked Sendable {
    private static let gracefulTerminationTimeoutSeconds = 3.0
    private static let forcedTerminationTimeoutSeconds = 2.0
    private static let terminationPollNanoseconds: UInt64 = 20_000_000
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
            guard self.process === process else {
                self.lock.unlock()
                return
            }
            self.isRunning = false
            self.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
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
        let pid = proc.processIdentifier
        lock.unlock()

        logger.info("Sending SIGINT to PID=\(pid)")
        proc.interrupt()

        DispatchQueue.global().asyncAfter(
            deadline: .now() + Self.gracefulTerminationTimeoutSeconds
        ) { [weak self, weak proc] in
            guard let self, let proc else { return }
            let shouldForceTerminate: Bool
            self.lock.lock()
            shouldForceTerminate = self.process === proc && self.isRunning
            self.lock.unlock()

            guard shouldForceTerminate else { return }
            logger.warning("Process did not exit after SIGINT, sending SIGKILL to PID=\(pid)")
            if kill(pid, SIGKILL) != 0, errno != ESRCH {
                logger.error("Failed to send SIGKILL to PID=\(pid), errno=\(errno)")
            }
        }
    }

    func stopAndWait() async throws -> Int32? {
        guard let process = currentRunningProcess() else { return nil }
        let pid = process.processIdentifier
        logger.info("Sending SIGINT to PID=\(pid)")
        process.interrupt()
        if let status = try await waitForTermination(
            process,
            timeoutSeconds: Self.gracefulTerminationTimeoutSeconds
        ) {
            return status
        }

        logger.warning("Process did not exit after SIGINT; sending SIGKILL to PID=\(pid)")
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else {
            throw ProcessTerminationFailure.signalFailed(
                pid: pid,
                signal: SIGKILL,
                errorCode: errno
            )
        }
        if let status = try await waitForTermination(
            process,
            timeoutSeconds: Self.forcedTerminationTimeoutSeconds
        ) {
            return status
        }
        throw ProcessTerminationFailure.timedOut(pid: pid)
    }

    func forceTerminateAndWait() async throws -> Int32? {
        guard let process = currentRunningProcess() else { return nil }
        let pid = process.processIdentifier
        guard kill(pid, SIGKILL) == 0 || errno == ESRCH else {
            throw ProcessTerminationFailure.signalFailed(
                pid: pid,
                signal: SIGKILL,
                errorCode: errno
            )
        }
        guard let status = try await waitForTermination(
            process,
            timeoutSeconds: Self.forcedTerminationTimeoutSeconds
        ) else {
            throw ProcessTerminationFailure.timedOut(pid: pid)
        }
        return status
    }

    func forceTerminate() {
        lock.lock()
        let runningProcess = process
        let shouldTerminate = isRunning
        lock.unlock()
        if let runningProcess, shouldTerminate {
            let pid = runningProcess.processIdentifier
            if kill(pid, SIGKILL) != 0, errno != ESRCH {
                logger.error("Failed to force-terminate PID=\(pid), errno=\(errno)")
            }
        }
    }

    private func currentRunningProcess() -> Process? {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return nil }
        return process
    }

    private func waitForTermination(
        _ expectedProcess: Process,
        timeoutSeconds: Double
    ) async throws -> Int32? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while clock.now < deadline {
            try Task.checkCancellation()
            if hasTerminated(expectedProcess) {
                return expectedProcess.terminationStatus
            }
            try await Task.sleep(nanoseconds: Self.terminationPollNanoseconds)
        }
        return nil
    }

    private func hasTerminated(_ expectedProcess: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return process !== expectedProcess || !isRunning
    }

    private func setupOutputHandler(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.onOutput?(text)
        }
    }
}
