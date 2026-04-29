import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.quitRequested ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

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
    @ObservedObject private var globalSettings = GlobalSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
        } label: {
            if globalSettings.routingEnabled && globalSettings.autoSystemProxy {
                Image(appState.isRunning ? "MenuBarIconProxyOn" : "MenuBarIconProxy")
            } else {
                Image(appState.isRunning ? "MenuBarIconOn" : "MenuBarIcon")
            }
        }

        WindowGroup(id: "main") {
            MainWindow()
                .environmentObject(appState)
                .environmentObject(appState.globalSettings)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 900, height: 600)
    }
}
