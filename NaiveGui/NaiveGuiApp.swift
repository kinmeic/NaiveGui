import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        let appState = AppState.shared
        if appState.isRunning {
            appState.stopProxy()
        }
    }
}

@main
struct NaiveGuiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
        } label: {
            Image(appState.isRunning ? "MenuBarIconOn" : "MenuBarIcon")
        }
    }
}
