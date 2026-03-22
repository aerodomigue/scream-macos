import SwiftUI

struct JackInstallGuideView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.yellow)

            Text("JACK is not installed")
                .font(.headline)

            Text("ScreamBar requires JACK Audio Connection Kit to function. Install it using Homebrew:")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text("brew install jack")
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .textSelection(.enabled)

            Text("After installation, restart ScreamBar.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(24)
    }
}
