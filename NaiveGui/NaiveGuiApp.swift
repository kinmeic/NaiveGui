import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Monitor window close/open
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.styleMask.contains(.titled) else { return }
        NetworkMonitorService.shared.updateWindowVisible(false)
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.styleMask.contains(.titled) else { return }
        NetworkMonitorService.shared.updateWindowVisible(true)
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
