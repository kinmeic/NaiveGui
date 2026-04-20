import SwiftUI

struct ConnectionStatusView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            // Status indicator
            VStack(spacing: 8) {
                Image(systemName: appState.isRunning ? "shield.fill" : "shield")
                    .font(.system(size: 56))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(appState.isRunning ? .green : .secondary)

                Text(appState.isRunning ? "Connected" : "Disconnected")
                    .font(.title2)
                    .fontWeight(.medium)

                if appState.isRunning, let profile = appState.profiles.first(where: { $0.id == appState.activeProfileId }) {
                    Text(profile.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Connect/Disconnect button
                Button {
                    appState.toggleProxy()
                } label: {
                    Label(
                        appState.isRunning ? "Disconnect" : "Connect",
                        systemImage: appState.isRunning ? "stop.fill" : "play.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.isRunning ? .red : .green)
                .disabled(appState.selectedProfile == nil && !appState.isRunning)
                .padding(.top, 4)

                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            // Listening info
            if appState.isRunning {
                Divider()
                    .padding(.horizontal, 40)

                VStack(spacing: 4) {
                    Text("Listening on")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(appState.globalSettings.listenURLs, id: \.self) { url in
                        Text(url)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Start the proxy to see proxy addresses")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
