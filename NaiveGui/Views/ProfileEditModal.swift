import SwiftUI

struct ProfileEditModal: View {
    @EnvironmentObject var appState: AppState
    @Binding var profile: ServerProfile
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var hasChanges = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isNew ? "New Profile" : "Edit Profile")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(.bar)

            Divider()

            // Form
            Form {
                Section("Profile Name") {
                    TextField("Name", text: $profile.name)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            }
            .formStyle(.grouped)

            Divider()

            // Footer buttons
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if hasChanges {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Button("Save") {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges && !isNew)
            }
            .padding()
        }
        .frame(width: 500, height: 520)
    }

    private func save() {
        if isNew {
            var p = profile
            appState.saveProfile(&p)
            appState.profiles.append(p)
            appState.selectedProfileId = p.id
            profile = p
        } else {
            var p = profile
            appState.saveProfile(&p)
            profile = p
        }
        hasChanges = false
    }
}
