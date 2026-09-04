import SwiftUI

@main
struct ScreamBarApp: App {
    @NSApplicationDelegateAdaptor(ScreamBarApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
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
