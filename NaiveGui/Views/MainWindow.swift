import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            ProfileSidebar()
                .environmentObject(appState)
                .frame(minWidth: 200)
        } detail: {
            DetailView()
                .environmentObject(appState)
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
