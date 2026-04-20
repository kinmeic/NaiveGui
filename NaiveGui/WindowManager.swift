import AppKit
import Foundation

final class WindowManager: ObservableObject {
    static let shared = WindowManager()

    private let helperAppName = "NaiveGuiWindow.app"

    private init() {}

    func configure(appState: AppState) {}

    func showMainWindow() {
        if let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: AppRole.mainWindow.bundleIdentifier).first {
            runningApp.activate()
            return
        }

        guard let appURL = helperAppURL() else {
            NSLog("NaiveGui: Unable to locate bundled window app")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                NSLog("NaiveGui: Failed to launch window app: \(error.localizedDescription)")
            }
        }
    }

    private func helperAppURL() -> URL? {
        if let bundledURL = Bundle.main.resourceURL?.appendingPathComponent("Helpers/\(helperAppName)"),
           FileManager.default.fileExists(atPath: bundledURL.path) {
            return bundledURL
        }

        let buildProductsURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(helperAppName)
        if FileManager.default.fileExists(atPath: buildProductsURL.path) {
            return buildProductsURL
        }

        let siblingBuildURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("NaiveGuiWindow.app")
        if FileManager.default.fileExists(atPath: siblingBuildURL.path) {
            return siblingBuildURL
        }

        let parentProductsURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(helperAppName)
        if FileManager.default.fileExists(atPath: parentProductsURL.path) {
            return parentProductsURL
        }

        if let devBundleURL = URL(string: helperAppName, relativeTo: Bundle.main.bundleURL.deletingLastPathComponent()),
           FileManager.default.fileExists(atPath: devBundleURL.path) {
            return devBundleURL
        }

        return nil
    }
}
