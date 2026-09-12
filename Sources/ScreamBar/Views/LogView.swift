import AppKit
import SwiftUI

struct LogView: View {
    @ObservedObject var logStore: RollingLogStore
    @State private var selectedSources = Set(LogEntry.LogSource.allCases)

    private var filteredEntries: [LogEntry] {
        logStore.entries(matching: selectedSources)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterControls

            if filteredEntries.isEmpty {
                Spacer()
                Text(logStore.entries.isEmpty ? "No logs yet" : "No logs match the selected filters")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredEntries) { entry in
                                logEntryRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: logStore.entries.count) { _ in
                        if let lastEntry = filteredEntries.last {
                            proxy.scrollTo(lastEntry.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("\(filteredEntries.count) / \(logStore.entries.count) entries")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Copy") {
                    copyDisplayedLogs()
                }
                .font(.caption)
                .disabled(filteredEntries.isEmpty)
                .help("Copy all displayed logs")
                Button("Clear") {
                    logStore.clear()
                }
                .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func copyDisplayedLogs() {
        let displayedText = logStore.text(matching: selectedSources)
        guard !displayedText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(displayedText, forType: .string) {
            NSSound.beep()
        }
    }

    private var filterControls: some View {
        HStack {
            Menu {
                Button("All sources") {
                    selectedSources = Set(LogEntry.LogSource.allCases)
                }

                Divider()

                ForEach(LogEntry.LogSource.allCases, id: \.self) { source in
                    Toggle(source.rawValue, isOn: filterBinding(for: source))
                }
            } label: {
                Label(filterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var filterLabel: String {
        if selectedSources.count == LogEntry.LogSource.allCases.count {
            return "All sources"
        }
        if selectedSources.isEmpty {
            return "No sources"
        }
        return "\(selectedSources.count) sources"
    }

    private func filterBinding(for source: LogEntry.LogSource) -> Binding<Bool> {
        Binding(
            get: { selectedSources.contains(source) },
            set: { isSelected in
                if isSelected {
                    selectedSources.insert(source)
                } else {
                    selectedSources.remove(source)
                }
            }
        )
    }

    private func logEntryRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("[\(entry.formattedTimestamp)]")
                    .foregroundColor(.secondary)
                Text("[\(entry.source.rawValue)]")
                    .foregroundColor(sourceColor(entry.source))
            }
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)

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
        case .routing: return .purple
        case .wol: return .orange
        case .app: return .secondary
        }
    }
}
