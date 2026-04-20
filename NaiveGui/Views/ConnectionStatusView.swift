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
            }
            .padding(.top, 24)

            Divider()
                .padding(.horizontal, 40)

            // Stats grid
            if appState.isRunning {
                HStack(spacing: 40) {
                    StatCard(title: "Connections", value: "\(appState.networkMonitor.connectionCount)", icon: "link")

                    StatCard(title: "Download", value: formatSpeed(appState.networkMonitor.downloadSpeed), icon: "arrow.down.circle.fill", color: .blue)

                    StatCard(title: "Upload", value: formatSpeed(appState.networkMonitor.uploadSpeed), icon: "arrow.up.circle.fill", color: .green)
                }

                Divider()
                    .padding(.horizontal, 40)

                // Listening info
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
                Text("Start the proxy to see connection stats")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func formatSpeed(_ bytesPerSec: Int64) -> String {
        if bytesPerSec < 1024 {
            return "\(bytesPerSec) B/s"
        } else if bytesPerSec < 1024 * 1024 {
            return String(format: "%.1f KB/s", Double(bytesPerSec) / 1024.0)
        } else {
            return String(format: "%.1f MB/s", Double(bytesPerSec) / (1024.0 * 1024.0))
        }
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var color: Color = .accentColor

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
