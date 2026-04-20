import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
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
    @StateObject private var windowManager = WindowManager.shared
    @ObservedObject private var globalSettings = GlobalSettings.shared

    init() {
        WindowManager.shared.configure(appState: AppState.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
                .environmentObject(windowManager)
        } label: {
            if globalSettings.autoSystemProxy {
                Image(appState.isRunning ? "MenuBarIconProxyOn" : "MenuBarIconProxy")
            } else {
                Image(appState.isRunning ? "MenuBarIconOn" : "MenuBarIcon")
            }
        }
    }
}
