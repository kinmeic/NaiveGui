import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(appState.isRunning ? "Disconnect" : "Connect") {
            appState.toggleProxy()
        }

        if appState.isRunning, let profile = appState.profiles.first(where: { $0.id == appState.activeProfileId }) {
            Text("Server: \(profile.name)")
        }

        Divider()

        Button("Show Main Window") {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }

        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }

        Divider()

        Button("Quit") {
            if appState.isRunning {
                appState.stopProxy()
            }
            NSApp.terminate(nil)
        }
    }
}
