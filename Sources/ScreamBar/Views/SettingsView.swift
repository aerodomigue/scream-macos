import SwiftUI

struct SettingsView: View {
    @Binding var configuration: ScreamConfiguration

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
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
