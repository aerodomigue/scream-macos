import SwiftUI

@main
struct ScreamBarApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Image(systemName: viewModel.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
