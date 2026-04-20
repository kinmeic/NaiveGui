import AppKit
import Foundation

enum AppRole {
    case menuBarHost
    case mainWindow

    static var current: AppRole {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return bundleID.hasSuffix(".window") ? .mainWindow : .menuBarHost
    }

    var bundleIdentifier: String {
        switch self {
        case .menuBarHost:
            return "com.naive.gui"
        case .mainWindow:
            return "com.naive.gui.window"
        }
    }
}

enum AppEnvironment {
    static let sharedDefaultsSuite = "com.naive.gui.shared"
    static let sharedDefaults = UserDefaults(suiteName: sharedDefaultsSuite) ?? .standard
}

enum AppIPC {
    static let center = DistributedNotificationCenter.default()

    enum Notification: String {
        case stateChanged = "com.naive.gui.stateChanged"
        case profilesChanged = "com.naive.gui.profilesChanged"
        case selectedProfileChanged = "com.naive.gui.selectedProfileChanged"
        case settingsChanged = "com.naive.gui.settingsChanged"
        case toggleProxyRequested = "com.naive.gui.toggleProxyRequested"
        case showMainWindowRequested = "com.naive.gui.showMainWindowRequested"
    }

    static func post(_ notification: Notification) {
        center.post(name: Foundation.Notification.Name(notification.rawValue), object: nil)
    }

    static func observe(_ notification: Notification, using block: @escaping () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: Foundation.Notification.Name(notification.rawValue), object: nil, queue: .main) { _ in
            block()
        }
    }
}
