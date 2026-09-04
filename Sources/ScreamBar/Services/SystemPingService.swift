import Foundation

protocol WakeOnLANHostPinging: Sendable {
    func ping(host: IPv4Address) async throws -> Bool
}

struct SystemPingService: WakeOnLANHostPinging {
    private static let executableURL = URL(fileURLWithPath: "/sbin/ping")
    private static let timeoutMilliseconds = 1_000

    func ping(host: IPv4Address) async throws -> Bool {
        let process = Process()
        process.executableURL = Self.executableURL
        process.arguments = [
            "-n",
            "-q",
            "-c", "1",
            "-W", String(Self.timeoutMilliseconds),
            host.description,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let terminationStatus: Int32
        do {
            terminationStatus = try await runAndWait(process)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WakeOnLANError.pingLaunchFailed(error.localizedDescription)
        }
        return terminationStatus == 0
    }

    private func runAndWait(_ process: Process) async throws -> Int32 {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { terminatedProcess in
                    continuation.resume(
                        returning: terminatedProcess.terminationStatus
                    )
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
