import Foundation

enum AppEnvironment {
    static let sharedDefaultsSuite = "com.naive.gui.shared"
    static let sharedDefaults = UserDefaults(suiteName: sharedDefaultsSuite) ?? .standard
    /// App Group 标识符，用于 NetworkExtension 扩展与主 App 共享配置。
    /// entitlement 审核通过后，配置存储迁移到此 group container。
    static let appGroupID = "group.com.naive.gui"
}
