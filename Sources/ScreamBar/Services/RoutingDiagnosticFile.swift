import Foundation
import os

/// Writes bounded routing diagnostics on a serial queue, never on an audio thread.
final class RoutingDiagnosticFile: @unchecked Sendable {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreamBar", isDirectory: true)
    private static let maximumFileBytes = 1_000_000
    private static let maximumEntryBytes = 8_192
    private static let maximumPendingEntries = 16
    private static let archiveCount = 2
    private static let logger = Logger(subsystem: "com.screambar.app", category: "RoutingDiagnosticFile")

    let fileURL: URL
    private let fileByteLimit: Int
    private let queue = DispatchQueue(label: "com.screambar.routing-diagnostics", qos: .utility)
    private let pendingSlots = DispatchSemaphore(value: maximumPendingEntries)
    private let droppedLock = NSLock()
    private var droppedEntries = 0
    // Accessed only on the writer queue.
    private var disabled = false
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .autoupdatingCurrent
        return formatter
    }()

    init(directory: URL = defaultDirectory, maximumFileBytes: Int = maximumFileBytes) {
        precondition(maximumFileBytes >= 256)
        fileURL = directory.appendingPathComponent("routing-diagnostics.log")
        fileByteLimit = maximumFileBytes
    }

    func append(_ message: String) {
        guard pendingSlots.wait(timeout: .now()) == .success else {
            droppedLock.lock()
            droppedEntries = min(droppedEntries, Int.max - 1) + 1
            droppedLock.unlock()
            return
        }
        let timestamp = Date()
        let boundedMessage = String(message.prefix(Self.maximumEntryBytes))
        queue.async { [self] in
            defer { pendingSlots.signal() }
            guard !disabled else { return }
            droppedLock.lock()
            let skippedCount = droppedEntries
            droppedEntries = 0
            droppedLock.unlock()
            let prefix = "[\(formatter.string(from: timestamp))] [Routing] "
            let skippedNotice = skippedCount > 0
                ? "\(prefix)Diagnostic backlog: skipped \(skippedCount) entries\n" : ""
            let text = skippedNotice + boundedMessage.components(separatedBy: .newlines)
                .map { prefix + $0 }.joined(separator: "\n") + "\n"
            let entryLimit = min(Self.maximumEntryBytes, fileByteLimit)
            let encoded = Data(text.utf8)
            let payload: Data
            if encoded.count > entryLimit {
                let suffix = " [truncated]\n"
                let prefixBytes = encoded.prefix(entryLimit - suffix.utf8.count - 3)
                payload = Data((String(decoding: prefixBytes, as: UTF8.self) + suffix).utf8)
            } else {
                payload = encoded
            }
            do {
                try write(payload)
            } catch {
                disabled = true
                Self.logger.error("Routing diagnostic file disabled after write failure: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits for already enqueued writes without blocking the caller's thread.
    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func write(_ payload: Data) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: fileURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            let currentBytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
            if currentBytes > fileByteLimit - payload.count {
                for index in stride(from: Self.archiveCount, through: 1, by: -1) {
                    let destination = fileURL.appendingPathExtension(String(index))
                    if fileManager.fileExists(atPath: destination.path) {
                        try fileManager.removeItem(at: destination)
                    }
                    let source = index == 1 ? fileURL
                        : fileURL.appendingPathExtension(String(index - 1))
                    if fileManager.fileExists(atPath: source.path) {
                        try fileManager.moveItem(at: source, to: destination)
                    }
                }
            }
        }
        if !fileManager.fileExists(atPath: fileURL.path) {
            try payload.write(to: fileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
            } catch {
                do {
                    try handle.close()
                } catch let closeError {
                    Self.logger.error("Routing diagnostic file close failed: \(closeError.localizedDescription, privacy: .public)")
                }
                throw error
            }
            try handle.close()
        }
    }
}
