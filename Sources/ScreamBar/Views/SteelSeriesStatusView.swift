import SwiftUI

struct SteelSeriesStatusView: View {
    @ObservedObject var service: SteelSeriesHeadsetService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "headphones")
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text("SteelSeries Omni").font(.headline)
                    Text(service.state.connectionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SteelSeriesVolumeSection(service: service.volumeKeys)
            batteryRow("Headset battery", percentage: service.state.headsetBatteryText)
            batteryRow("Battery in base", percentage: service.state.baseBatteryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func batteryRow(_ label: String, percentage: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(percentage).monospacedDigit()
        }
    }
}

private struct SteelSeriesVolumeSection: View {
    @ObservedObject var service: SteelSeriesVolumeKeyService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Volume")
                Spacer()
                Text(service.volumeText).monospacedDigit()
            }
            SteelSeriesVolumeKeysView(service: service)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SteelSeriesVolumeKeysView: View {
    @ObservedObject var service: SteelSeriesVolumeKeyService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(service.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if service.needsPermission {
                Button("Allow volume keys…") { service.requestPermission() }
                    .controlSize(.small)
            }
        }
    }
}
