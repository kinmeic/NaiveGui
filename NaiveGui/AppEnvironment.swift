import Foundation

enum AppEnvironment {
    static let sharedDefaultsSuite = "com.naive.gui.shared"
    static let sharedDefaults = UserDefaults(suiteName: sharedDefaultsSuite) ?? .standard
}
