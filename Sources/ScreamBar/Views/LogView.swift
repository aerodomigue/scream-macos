import SwiftUI

struct LogView: View {
    @ObservedObject var logStore: RollingLogStore

    var body: some View {
        VStack(spacing: 0) {
            if logStore.entries.isEmpty {
                Spacer()
                Text("No logs yet")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(logStore.entries) { entry in
                                logEntryRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: logStore.entries.count) { _ in
                        if let lastEntry = logStore.entries.last {
                            withAnimation {
                                proxy.scrollTo(lastEntry.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("\(logStore.entries.count) entries")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    logStore.clear()
                }
                .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func logEntryRow(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("[\(entry.source.rawValue)]")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(sourceColor(entry.source))
                .frame(width: 60, alignment: .leading)

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceColor(_ source: LogEntry.LogSource) -> Color {
        switch source {
        case .jack: return .blue
        case .scream: return .green
        case .app: return .secondary
        }
    }
}
