import SwiftUI

enum MenuTab: String, CaseIterable {
    case status = "Status"
    case settings = "Settings"
    case logs = "Logs"
}

struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedTab: MenuTab = .status

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(MenuTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch selectedTab {
                case .status:
                    if viewModel.jackService.isInstalled {
                        StatusSectionView(viewModel: viewModel)
                    } else {
                        JackInstallGuideView()
                    }
                case .settings:
                    SettingsView(configuration: $viewModel.configuration)
                case .logs:
                    LogView(logStore: viewModel.logStore)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            VStack(spacing: 6) {
                HStack {
                    Toggle("Auto-start", isOn: $viewModel.autoStart)
                        .toggleStyle(.checkbox)
                        .font(.caption)

                    Toggle("Launch at login", isOn: $viewModel.launchAtLogin)
                        .toggleStyle(.checkbox)
                        .font(.caption)

                    Spacer()

                    Button("Quit") {
                        viewModel.stopAll()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 380, height: 420)
    }
}
