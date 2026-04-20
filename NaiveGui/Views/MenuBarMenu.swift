import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Menu("Profiles") {
            if appState.profiles.isEmpty {
                Text("No Profiles")
            } else {
                ForEach(appState.profiles) { profile in
                    Button(appState.selectedProfileId == profile.id ? "✓ \(profile.name)" : profile.name) {
                        appState.selectedProfileId = profile.id
                    }
                }
            }
        }

        Divider()

        Button(appState.isRunning ? "Disconnect" : "Connect") {
            appState.toggleProxy()
        }

        if appState.isRunning, let profile = appState.profiles.first(where: { $0.id == appState.activeProfileId }) {
            Text("Server: \(profile.name)")
        }

        Divider()

        Button("Show Main Window") {
            let existing = NSApp.windows.first {
                $0.isVisible && !($0 is NSPanel) &&
                ($0.identifier?.rawValue == "main" || $0.title == "NaiveGui")
            }
            if let window = existing {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openWindow(id: "main")
            }
        }

        Divider()

        Button("Quit") {
            appState.requestQuit()
        }
    }
}
