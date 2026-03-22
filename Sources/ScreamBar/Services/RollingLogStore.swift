import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let source: LogSource
    let message: String

    enum LogSource: String {
        case jack = "JACK"
        case scream = "Scream"
        case app = "App"
    }
}

@MainActor
final class RollingLogStore: ObservableObject {
    private static let maxSizeBytes = 500_000

    @Published private(set) var entries: [LogEntry] = []
    private var currentSizeBytes = 0

    func append(source: LogEntry.LogSource, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        for line in trimmed.components(separatedBy: .newlines) {
            let entry = LogEntry(timestamp: Date(), source: source, message: line)
            entries.append(entry)
            currentSizeBytes += line.utf8.count
        }

        trimIfNeeded()
    }

    func clear() {
        entries.removeAll()
        currentSizeBytes = 0
    }

    private func trimIfNeeded() {
        while currentSizeBytes > Self.maxSizeBytes && !entries.isEmpty {
            let removed = entries.removeFirst()
            currentSizeBytes -= removed.message.utf8.count
        }
    }
}
