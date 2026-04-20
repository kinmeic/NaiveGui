import SwiftUI

struct ProfileSidebar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
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
        .overlay(alignment: .bottom) {
            HStack {
                Button {
                    appState.addProfile()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(8)
            .background(.bar)
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
