import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Binding var configuration: ScreamConfiguration
    @ObservedObject var hotkeyService: HotkeyService
    @ObservedObject var usbWatcherService: USBWatcherService
    @State private var showingDevicePicker = false

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Mode", selection: $configuration.useUnicast) {
                    Text("Multicast").tag(false)
                    Text("Unicast").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("Network") {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", value: $configuration.port, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }

            Section("Global Shortcut") {
                Toggle("Enable shortcut", isOn: $hotkeyService.isEnabled)

                if hotkeyService.isEnabled {
                    HStack {
                        Text("Shortcut")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleScream)
                    }
                }
            }

            Section("USB Device Trigger") {
                Toggle("Enable USB trigger", isOn: $usbWatcherService.isEnabled)

                if usbWatcherService.isEnabled {
                    Picker("Trigger mode", selection: $usbWatcherService.triggerMode) {
                        ForEach(USBTriggerMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let device = usbWatcherService.monitoredDevice {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                    .font(.body)
                                Text(device.hexDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(usbWatcherService.isDeviceConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(usbWatcherService.isDeviceConnected ? "Connected" : "Disconnected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Select Device...") {
                        showingDevicePicker = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingDevicePicker) {
            USBDevicePickerView(usbWatcherService: usbWatcherService)
        }
    }
}
