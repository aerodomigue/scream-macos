import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Binding var applicationMode: ApplicationMode
    @Binding var configuration: ScreamConfiguration
    @Binding var directRoutingConfiguration: DirectRoutingConfiguration
    @Binding var menuBarDisplayConfiguration: MenuBarDisplayConfiguration
    @Binding var wakeOnLANConfiguration: WakeOnLANConfiguration
    @ObservedObject var hotkeyService: HotkeyService
    @ObservedObject var usbWatcherService: USBWatcherService
    @ObservedObject var directRoutingService: DirectAudioRoutingService
    @ObservedObject var wakeOnLANService: WakeOnLANService
    @State private var showingDevicePicker = false

    var body: some View {
        Form {
            Section("Application Mode") {
                Picker("Application Mode", selection: $applicationMode) {
                    ForEach(ApplicationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if applicationMode == .scream {
                screamSettings
            } else {
                DirectRoutingSettingsView(
                    configuration: $directRoutingConfiguration,
                    deviceService: directRoutingService.deviceService,
                    routingService: directRoutingService
                )
            }

            commonSettings
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(isPresented: $showingDevicePicker) {
            USBDevicePickerView(usbWatcherService: usbWatcherService)
        }
    }

    @ViewBuilder
    private var screamSettings: some View {
        Section("Scream Network Mode") {
                Picker("Network Mode", selection: $configuration.useUnicast) {
                    Text("Multicast").tag(false)
                    Text("Unicast").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if configuration.useUnicast {
                Section("Network") {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", value: $configuration.port, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            }

            Section("JACK Audio") {
                Picker("Sample rate", selection: $configuration.jackSampleRate) {
                    Text("---").tag(Int?.none)
                    ForEach(ScreamConfiguration.sampleRateOptions, id: \.self) { rate in
                        Text("\(rate) Hz").tag(Int?.some(rate))
                    }
                }
                Picker("Buffer size", selection: $configuration.jackBufferFrames) {
                    Text("---").tag(Int?.none)
                    ForEach(ScreamConfiguration.bufferFramesOptions, id: \.self) { frames in
                        Text("\(frames) frames").tag(Int?.some(frames))
                    }
                }
                Text("--- = use jackd default. Applied on next JACK start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Trigger Scope") {
                Picker("Toggle", selection: $configuration.toggleScope) {
                    ForEach(ToggleScope.allCases, id: \.self) { scope in
                        Text(scope.label).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
    }

    @ViewBuilder
    private var commonSettings: some View {
            Section("Wake on LAN") {
                Toggle("Enable Wake on LAN", isOn: $wakeOnLANConfiguration.isEnabled)

                if wakeOnLANConfiguration.isEnabled {
                    TextField(
                        "MAC address",
                        text: $wakeOnLANConfiguration.macAddress
                    )
                    TextField(
                        "Machine IPv4 or subnet",
                        text: $wakeOnLANConfiguration.destination
                    )

                    if let errorDescription =
                        wakeOnLANService.configurationErrorDescription {
                        Text(errorDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else if let packetDestination =
                        wakeOnLANService.resolvedPacketDestinationDescription {
                        Text("Magic packets will be sent over UDP/9 to \(packetDestination). Machine reachability is monitored only when a host IPv4 address is configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Menu Bar") {
                Toggle(
                    "Show frames",
                    isOn: $menuBarDisplayConfiguration.showFrames
                )
                Toggle(
                    "Show app latency",
                    isOn: $menuBarDisplayConfiguration.showApplicationLatency
                )
                Text("Selected values appear beside the menu bar icon while Direct Routing is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Global Shortcut") {
                Toggle("Enable shortcut", isOn: $hotkeyService.isEnabled)

                if hotkeyService.isEnabled {
                    Picker("Shortcut mode", selection: $hotkeyService.layout) {
                        ForEach(GlobalShortcutLayout.allCases, id: \.self) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text(hotkeyService.layout == .combined ? "Audio + WOL" : "Audio")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleScream)
                    }

                    if hotkeyService.layout == .separate {
                        HStack {
                            Text("Wake on LAN")
                            Spacer()
                            KeyboardShortcuts.Recorder(for: .sendWakeOnLAN)
                        }
                    }

                    Text(shortcutDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("USB Device Trigger") {
                Toggle("Enable USB trigger", isOn: $usbWatcherService.isEnabled)

                if usbWatcherService.isEnabled {
                    Picker("Actions", selection: $usbWatcherService.actionTarget) {
                        ForEach(AutomationActionTarget.allCases, id: \.self) { target in
                            Text(target.label).tag(target)
                        }
                    }

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

                    if usbWatcherService.actionTarget.includesWakeOnLAN
                        && !wakeOnLANConfiguration.isEnabled {
                        Text("Enable and configure Wake on LAN to send a magic packet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("USB Trigger Commands") {
                TextField("Start command", text: $usbWatcherService.startCommand, axis: .vertical)
                    .lineLimit(1...3)

                Text("Runs with Bash before the selected USB start actions. A non-zero exit status prevents them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Stop command", text: $usbWatcherService.stopCommand, axis: .vertical)
                    .lineLimit(1...3)
                    .disabled(!usbWatcherService.actionTarget.includesAudio)

                Text("Runs with Bash when USB stops audio. Wake-on-LAN-only triggers have no stop action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }

    private var shortcutDescription: String {
        switch hotkeyService.layout {
        case .combined:
            return "Starts audio and sends Wake on LAN when it is enabled. Press again to stop audio without sending another packet."
        case .separate:
            return "The Audio shortcut toggles the selected audio mode. The Wake on LAN shortcut only sends a magic packet."
        }
    }
}
