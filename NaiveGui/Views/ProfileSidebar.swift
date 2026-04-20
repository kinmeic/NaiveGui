import SwiftUI

struct ProfilesTabView: View {
    @EnvironmentObject var appState: AppState

    private var selectedIndex: Int? {
        guard let id = appState.selectedProfileId else { return nil }
        return appState.profiles.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        HStack(spacing: 0) {
            List(appState.profiles, selection: $appState.selectedProfileId) { profile in
                ProfileRow(profile: profile, isActive: appState.activeProfileId == profile.id)
                    .tag(profile.id)
                    .contextMenu {
                        Button("Duplicate") {
                            appState.duplicateProfile(profile)
                        }
                        Divider()
                        Button("Delete", role: .destructive) {
                            appState.deleteProfile(profile.id)
                        }
                    }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
            .overlay(alignment: .bottom) {
                HStack {
                    Button { appState.addProfile() } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button { appState.moveSelectedProfileUp() } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedIndex == nil || selectedIndex! == 0)

                    Button { appState.moveSelectedProfileDown() } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedIndex == nil || selectedIndex! == appState.profiles.count - 1)
                }
                .padding(8)
                .background(.bar)
            }

            Divider()

            Group {
                if let profile = appState.selectedProfile {
                    ProfileEditor(profile: profile)
                        .id(profile.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Profile Selected")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Add a server profile to get started")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
    }
}

// MARK: - Profile Editor

private struct ProfileEditor: View {
    let profile: ServerProfile
    @EnvironmentObject var appState: AppState

    @State private var name: String = ""
    @State private var serverAddress: String = ""
    @State private var serverPort: Int = 443
    @State private var proxyProtocol: ProxyProtocol = .https
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var hasChanges = false
    @State private var isLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(name.isEmpty ? "New Profile" : name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Form {
                    Section("Profile Name") {
                        LabeledContent("Name") {
                            TextField("", text: $name)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Section("Proxy Server") {
                        Picker("Protocol", selection: $proxyProtocol) {
                            ForEach(ProxyProtocol.allCases, id: \.self) { p in
                                Text(p.rawValue.uppercased()).tag(p)
                            }
                        }
                        .pickerStyle(.segmented)

                        LabeledContent("Server Address") {
                            TextField("", text: $serverAddress)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        LabeledContent("Port") {
                            TextField("", value: $serverPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }

                        LabeledContent("Username") {
                            TextField("", text: $username)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        LabeledContent("Password") {
                            SecureField("", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .formStyle(.grouped)
                }
                .padding(20)
            }

            Divider()

            HStack {
                if hasChanges {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Save") {
                    save()
                    hasChanges = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!hasChanges)
            }
            .padding()
        }
        .onAppear {
            isLoaded = false
            name = profile.name
            serverAddress = profile.serverAddress
            serverPort = profile.serverPort
            proxyProtocol = profile.proxyProtocol
            username = profile.username
            password = profile.password
            DispatchQueue.main.async { isLoaded = true }
        }
        .onChange(of: name) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: serverAddress) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: serverPort) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: proxyProtocol) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: username) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: password) { _ in if isLoaded { hasChanges = true } }
    }

    private func save() {
        guard let idx = appState.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        appState.profiles[idx].name = name
        appState.profiles[idx].serverAddress = serverAddress
        appState.profiles[idx].serverPort = serverPort
        appState.profiles[idx].proxyProtocol = proxyProtocol
        appState.profiles[idx].username = username
        appState.profiles[idx].password = password
        var p = appState.profiles[idx]
        appState.saveProfile(&p)
    }
}

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: ServerProfile
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body)
                    .lineLimit(1)
                Text(profile.serverAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
