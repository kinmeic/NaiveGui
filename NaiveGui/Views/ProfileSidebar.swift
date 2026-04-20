import SwiftUI

struct ProfileSidebar: View {
    @EnvironmentObject var appState: AppState
    @State private var editingProfile: ServerProfile?
    @State private var newProfile = ServerProfile(
        name: "New Server",
        serverAddress: "",
        serverPort: 443,
        username: "",
        password: ""
    )
    @State private var isAddingNew = false

    private var selectedIndex: Int? {
        guard let id = appState.selectedProfileId else { return nil }
        return appState.profiles.firstIndex(where: { $0.id == id })
    }

    var body: some View {
        List(appState.profiles, selection: $appState.selectedProfileId) { profile in
            ProfileRow(profile: profile, isActive: appState.activeProfileId == profile.id)
                .tag(profile.id)
                .contextMenu {
                    Button("Edit") {
                        editingProfile = profile
                    }
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
        .overlay(alignment: .bottom) {
            HStack {
                Button {
                    newProfile = ServerProfile(
                        name: "New Server",
                        serverAddress: "",
                        serverPort: 443,
                        username: "",
                        password: ""
                    )
                    isAddingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)

                Button {
                    if let profile = appState.selectedProfile {
                        editingProfile = profile
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(appState.selectedProfile == nil)

                Spacer()

                Button {
                    appState.moveSelectedProfileUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(selectedIndex == nil || selectedIndex! == 0)

                Button {
                    appState.moveSelectedProfileDown()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(selectedIndex == nil || selectedIndex! == appState.profiles.count - 1)
            }
            .padding(8)
            .background(.bar)
        }
        .sheet(isPresented: $isAddingNew) {
            ProfileEditModal(profile: $newProfile, isNew: true)
                .environmentObject(appState)
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditModal(profile: Binding(
                get: { profile },
                set: { newValue in
                    if let idx = appState.profiles.firstIndex(where: { $0.id == newValue.id }) {
                        appState.profiles[idx] = newValue
                    }
                }
            ), isNew: false)
            .environmentObject(appState)
        }
    }
}

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
