import Foundation
import os

private let logger = Logger(subsystem: "com.screambar.app", category: "ScreamService")

@MainActor
final class ScreamService: ObservableObject {
    @Published private(set) var status: ProcessStatus = .stopped

    private let processManager = ProcessManager()
    private weak var logStore: RollingLogStore?

    init(logStore: RollingLogStore) {
        self.logStore = logStore

        processManager.onOutput = { [weak self] text in
            Task { @MainActor in
                self?.logStore?.append(source: .scream, message: text)
            }
        }

        processManager.onTermination = { [weak self] exitStatus in
            Task { @MainActor in
                guard let self else { return }
                if case .stopping = self.status {
                    self.status = .stopped
                } else {
                    self.status = .error("scream exited with code \(exitStatus)")
                    self.logStore?.append(source: .scream, message: "scream exited unexpectedly with code \(exitStatus)")
                }
            }
        }
    }

    func start(configuration: ScreamConfiguration) {
        status = .starting

        let screamPath = resolveScreamPath()
        let arguments = configuration.buildArguments()

        logStore?.append(source: .scream, message: "Starting \(screamPath) \(arguments.joined(separator: " "))")

        guard FileManager.default.fileExists(atPath: screamPath) else {
            status = .error("scream binary not found at \(screamPath)")
            logStore?.append(source: .scream, message: "Binary not found at \(screamPath)")
            return
        }

        do {
            var environment: [String: String]?

            // When running from .app bundle, set DYLD_LIBRARY_PATH to Frameworks dir
            if let frameworksURL = Bundle.main.privateFrameworksURL {
                environment = ["DYLD_LIBRARY_PATH": frameworksURL.path]
            }

            try processManager.start(
                executablePath: screamPath,
                arguments: arguments,
                environment: environment
            )
            status = .running
        } catch {
            status = .error(error.localizedDescription)
            logStore?.append(source: .scream, message: "Failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        status = .stopping
        logStore?.append(source: .scream, message: "Stopping scream")
        processManager.stop()
    }

    var isProcessRunning: Bool {
        processManager.isRunning
    }

    private func resolveScreamPath() -> String {
        // 1. App bundle Resources (production .app)
        if let resourceURL = Bundle.main.resourceURL {
            let bundledPath = resourceURL.appendingPathComponent("scream").path
            if FileManager.default.fileExists(atPath: bundledPath) {
                logger.info("Using bundled scream at \(bundledPath)")
                return bundledPath
            }
        }

        // 2. Dev mode: directory of the running executable (swift run puts binary in .build/)
        let executablePath = ProcessInfo.processInfo.arguments[0]
        let executableDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        let devPath = (executableDir as NSString).appendingPathComponent("scream")
        if FileManager.default.fileExists(atPath: devPath) {
            logger.info("Using dev scream at \(devPath)")
            return devPath
        }

        // 3. Try project root (working directory)
        let cwdPath = FileManager.default.currentDirectoryPath + "/scream"
        if FileManager.default.fileExists(atPath: cwdPath) {
            logger.info("Using cwd scream at \(cwdPath)")
            return cwdPath
        }

        // 4. Fallback
        logger.warning("No scream binary found, using ./scream as fallback")
        return "./scream"
    }
}
