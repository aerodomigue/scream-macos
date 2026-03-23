import SwiftUI

/// Presents a list of connected USB devices for selection.
struct USBDevicePickerView: View {
    @ObservedObject var usbWatcherService: USBWatcherService
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [USBDeviceIdentifier] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select USB Device")
                    .font(.headline)
                Spacer()
                Button("Refresh") {
                    devices = USBWatcherService.listConnectedDevices()
                }
            }
            .padding()

            if devices.isEmpty {
                VStack(spacing: 8) {
                    Text("No USB devices found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                List(devices) { device in
                    Button {
                        usbWatcherService.monitoredDevice = device
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.body)
                                HStack(spacing: 8) {
                                    if !device.vendorName.isEmpty {
                                        Text(device.vendorName)
                                    }
                                    Text(device.hexDescription)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if usbWatcherService.monitoredDevice == device {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
            }
            .padding()
        }
        .frame(width: 400, height: 350)
        .onAppear {
            devices = USBWatcherService.listConnectedDevices()
        }
    }
}
