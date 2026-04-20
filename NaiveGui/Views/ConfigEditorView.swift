import SwiftUI

struct ConfigEditorView: View {
    @Binding var profile: ServerProfile
    @EnvironmentObject var appState: AppState
    @State private var hasChanges = false

    var body: some View {
        Form {
            Section("Profile Name") {
                TextField("Name", text: $profile.name)
                    .onChange(of: profile.name) { _ in hasChanges = true }
            }

            Section("Proxy Server") {
                Picker("Protocol", selection: $profile.proxyProtocol) {
                    ForEach(ProxyProtocol.allCases, id: \.self) { p in
                        Text(p.rawValue.uppercased()).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: profile.proxyProtocol) { _ in hasChanges = true }

                LabeledContent("Server Address") {
                    TextField("", text: $profile.serverAddress)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: profile.serverAddress) { _ in hasChanges = true }
                }

                LabeledContent("Port") {
                    TextField("", value: $profile.serverPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                .onChange(of: profile.serverPort) { _ in hasChanges = true }

                LabeledContent("Username") {
                    TextField("", text: $profile.username)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: profile.username) { _ in hasChanges = true }
                }

                LabeledContent("Password") {
                    SecureField("", text: $profile.password)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: profile.password) { _ in hasChanges = true }
                }
            }

            Section {
                HStack {
                    Button("Save") {
                        var p = profile
                        appState.saveProfile(&p)
                        profile = p
                        hasChanges = false
                    }
                    .disabled(!hasChanges)

                    if hasChanges {
                        Text("Unsaved changes")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Spacer()

                    Button("Save & Connect") {
                        var p = profile
                        appState.saveProfile(&p)
                        profile = p
                        hasChanges = false
                        appState.selectedProfileId = profile.id
                        appState.startProxy()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }

            Section("Generated Config Preview") {
                let preview = generatePreview()
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func generatePreview() -> String {
        let dict = GlobalSettings.shared.configDict(for: profile)
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "Invalid config"
        }
        return str
    }
}
