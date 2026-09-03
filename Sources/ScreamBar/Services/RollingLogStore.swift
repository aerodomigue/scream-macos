import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let source: LogSource
    let message: String

    enum LogSource: String, CaseIterable {
        case jack = "JACK"
        case scream = "Scream"
        case routing = "Routing"
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

        let lines = trimmed.components(separatedBy: .newlines)
        let newEntries = lines.map { LogEntry(timestamp: Date(), source: source, message: $0) }
        entries.append(contentsOf: newEntries)
        currentSizeBytes += newEntries.reduce(0) { $0 + $1.message.utf8.count }

        trimIfNeeded()
    }

    func clear() {
        entries.removeAll()
        currentSizeBytes = 0
    }

    func entries(matching sources: Set<LogEntry.LogSource>) -> [LogEntry] {
        entries.filter { sources.contains($0.source) }
    }

    private func trimIfNeeded() {
        while currentSizeBytes > Self.maxSizeBytes && !entries.isEmpty {
            let removed = entries.removeFirst()
            currentSizeBytes -= removed.message.utf8.count
        }
    }
}
