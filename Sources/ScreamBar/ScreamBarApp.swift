import SwiftUI

@main
struct ScreamBarApp: App {
    @NSApplicationDelegateAdaptor(ScreamBarApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var viewModel = AppViewModel()
    @StateObject private var daemonImportWindowController = DaemonTrustImportWindowController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .environmentObject(daemonImportWindowController)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModel.menuBarIcon)
                if let statusText = viewModel.menuBarStatusText {
                    Text(statusText)
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
