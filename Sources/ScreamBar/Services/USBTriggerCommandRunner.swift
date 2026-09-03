import Foundation
import os

private let usbTriggerCommandLogger = Logger(
    subsystem: "com.screambar.app",
    category: "USBTriggerCommandRunner"
)

enum USBTriggerCommandError: LocalizedError, Equatable {
    case nonZeroExitStatus(Int32, output: String)
    case launchFailed(String)
    case outputCaptureFailed(String)

    var errorDescription: String? {
        switch self {
        case .nonZeroExitStatus(let status, _):
            return "Command exited with status \(status)"
        case .launchFailed(let message):
            return "Could not launch command: \(message)"
        case .outputCaptureFailed(let message):
            return "Could not capture command output: \(message)"
        }
    }

    var output: String? {
        switch self {
        case .nonZeroExitStatus(_, let output):
            return output
        case .launchFailed, .outputCaptureFailed:
            return nil
        }
    }
}

/// Runs user-provided USB trigger commands through Bash.
@MainActor
final class USBTriggerCommandRunner {
    private static let bashPath = "/bin/bash"

    /// Runs a Bash command and returns only after it has completed successfully.
    ///
    /// - Parameter command: A complete Bash command. Whitespace-only commands are no-ops.
    /// - Returns: The command's standard output and standard error, if any.
    /// - Throws: ``USBTriggerCommandError`` when Bash cannot be launched or returns non-zero.
    func run(_ command: String) async throws -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return "" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.bashPath)
        process.arguments = ["-c", trimmedCommand]

        let outputFiles: USBTriggerCommandOutputFiles
        do {
            outputFiles = try USBTriggerCommandOutputFiles()
        } catch {
            throw USBTriggerCommandError.outputCaptureFailed(error.localizedDescription)
        }
        defer {
            outputFiles.cleanup()
        }
        process.standardOutput = outputFiles.standardOutputFileHandle
        process.standardError = outputFiles.standardErrorFileHandle

        let exitStatus: Int32
        do {
            exitStatus = try await runAndWait(process)
        } catch {
            let message = error.localizedDescription
            usbTriggerCommandLogger.error("Failed to launch USB trigger command: \(message, privacy: .public)")
            throw USBTriggerCommandError.launchFailed(message)
        }

        let output: String
        do {
            try outputFiles.finishWriting()
            output = try outputFiles.readOutput()
        } catch {
            throw USBTriggerCommandError.outputCaptureFailed(error.localizedDescription)
        }

        guard exitStatus == 0 else {
            throw USBTriggerCommandError.nonZeroExitStatus(exitStatus, output: output)
        }
        return output
    }

    private func runAndWait(_ process: Process) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminatedProcess in
                continuation.resume(returning: terminatedProcess.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class USBTriggerCommandOutputFiles {
    let standardOutputURL: URL
    let standardErrorURL: URL
    let standardOutputFileHandle: FileHandle
    let standardErrorFileHandle: FileHandle
    private var hasCleanedUp = false
    private var hasFinishedWriting = false

    init(fileManager: FileManager = .default) throws {
        let identifier = UUID().uuidString
        let temporaryDirectory = fileManager.temporaryDirectory
        standardOutputURL = temporaryDirectory.appendingPathComponent(
            "screambar-usb-command-\(identifier)-stdout.log"
        )
        standardErrorURL = temporaryDirectory.appendingPathComponent(
            "screambar-usb-command-\(identifier)-stderr.log"
        )

        guard fileManager.createFile(atPath: standardOutputURL.path, contents: nil) else {
            throw USBTriggerCommandOutputFileError.creationFailed(standardOutputURL.path)
        }
        guard fileManager.createFile(atPath: standardErrorURL.path, contents: nil) else {
            try fileManager.removeItem(at: standardOutputURL)
            throw USBTriggerCommandOutputFileError.creationFailed(standardErrorURL.path)
        }

        do {
            standardOutputFileHandle = try FileHandle(forWritingTo: standardOutputURL)
            standardErrorFileHandle = try FileHandle(forWritingTo: standardErrorURL)
        } catch {
            try fileManager.removeItem(at: standardOutputURL)
            try fileManager.removeItem(at: standardErrorURL)
            throw error
        }
    }

    deinit {
        cleanup()
    }

    func readOutput() throws -> String {
        let standardOutput = try String(
            decoding: Data(contentsOf: standardOutputURL),
            as: UTF8.self
        )
        let standardError = try String(
            decoding: Data(contentsOf: standardErrorURL),
            as: UTF8.self
        )

        return [
            formattedOutput(standardOutput, stream: "stdout"),
            formattedOutput(standardError, stream: "stderr"),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
    }

    func finishWriting() throws {
        guard !hasFinishedWriting else { return }
        try standardOutputFileHandle.close()
        try standardErrorFileHandle.close()
        hasFinishedWriting = true
    }

    func cleanup() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true

        do {
            try finishWriting()
        } catch {
            usbTriggerCommandLogger.warning(
                "Failed to close USB command output files: \(error.localizedDescription, privacy: .public)"
            )
        }

        let fileManager = FileManager.default
        for outputURL in [standardOutputURL, standardErrorURL] {
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                usbTriggerCommandLogger.warning(
                    "Failed to remove USB command output file: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func formattedOutput(_ output: String, stream: String) -> String? {
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return "\(stream):\n\(output)"
    }
}

private enum USBTriggerCommandOutputFileError: LocalizedError {
    case creationFailed(String)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let path):
            return "Unable to create temporary output file at \(path)"
        }
    }
}
