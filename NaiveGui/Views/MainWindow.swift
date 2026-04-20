import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState
    @State private var pendingToggle = false

    var body: some View {
        NavigationSplitView {
            ProfileSidebar()
                .environmentObject(appState)
                .frame(minWidth: 200)
        } detail: {
            if appState.selectedProfile != nil {
                if let profile = appState.selectedProfile {
                    DetailView(profile: profile)
                        .environmentObject(appState)
                        .id(profile.id)
                }
            } else {
                EmptyStateView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    pendingToggle = true
                } label: {
                    Label(
                        appState.isRunning ? "Stop" : "Start",
                        systemImage: appState.isRunning ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isRunning ? .red : .green)
                .disabled(appState.selectedProfile == nil)

                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: pendingToggle) { val in
            if val {
                pendingToggle = false
                appState.toggleProxy()
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "shield")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No Server Selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Add a server profile to get started")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
