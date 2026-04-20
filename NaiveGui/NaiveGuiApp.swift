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
            Image(appState.isRunning ? "MenuBarIconOn" : "MenuBarIcon")
        }
    }
}
