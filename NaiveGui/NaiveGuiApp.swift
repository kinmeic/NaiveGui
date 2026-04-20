import SwiftUI

@main
struct NaiveGuiApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(appState.globalSettings)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.globalSettings)
        }

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
        } label: {
            Label {
                Text("NaiveGui")
            } icon: {
                Image(systemName: appState.isRunning ? "shield.fill" : "shield")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(appState.isRunning ? .green : .secondary)
            }
        }
    }
}
