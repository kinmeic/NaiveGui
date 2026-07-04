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
            } else {
                openWindow(id: "main")
            }
            // 强制激活到最前面。
            NSApp.activate(ignoringOtherApps: true)
            // 再确保窗口在最前（activate 后可能仍需提层）。
            if let window = existing ?? NSApp.windows.first(where: { $0.identifier?.rawValue == "main" || $0.title == "NaiveGui" }) {
                window.deminiaturize(nil)
                window.orderFrontRegardless()
            }
        }

        Divider()

        Button("Quit") {
            appState.requestQuit()
        }
    }
}
