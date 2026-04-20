import Foundation
import Combine

// Global settings for local listening (shared across all profiles)
final class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()

    @Published var listenAddress: String {
        didSet { UserDefaults.standard.set(listenAddress, forKey: "listenAddress") }
    }
    @Published var socksEnabled: Bool {
        didSet { UserDefaults.standard.set(socksEnabled, forKey: "socksEnabled") }
    }
    @Published var socksPort: Int {
        didSet { UserDefaults.standard.set(socksPort, forKey: "socksPort") }
    }
    @Published var httpEnabled: Bool {
        didSet { UserDefaults.standard.set(httpEnabled, forKey: "httpEnabled") }
    }
    @Published var httpPort: Int {
        didSet { UserDefaults.standard.set(httpPort, forKey: "httpPort") }
    }
    @Published var naiveBinaryPath: String {
        didSet { UserDefaults.standard.set(naiveBinaryPath, forKey: "naiveBinaryPath") }
    }
    @Published var autoSystemProxy: Bool {
        didSet { UserDefaults.standard.set(autoSystemProxy, forKey: "autoSystemProxy") }
    }

    init() {
        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        self.socksEnabled = UserDefaults.standard.object(forKey: "socksEnabled") as? Bool ?? true
        self.socksPort = UserDefaults.standard.integer(forKey: "socksPort") == 0 ? 1080 : UserDefaults.standard.integer(forKey: "socksPort")
        self.httpEnabled = UserDefaults.standard.object(forKey: "httpEnabled") as? Bool ?? false
        self.httpPort = UserDefaults.standard.integer(forKey: "httpPort") == 0 ? 8080 : UserDefaults.standard.integer(forKey: "httpPort")
        self.naiveBinaryPath = UserDefaults.standard.string(forKey: "naiveBinaryPath") ?? "/Users/eugene/Downloads/naive-gui/naive"
        self.autoSystemProxy = UserDefaults.standard.object(forKey: "autoSystemProxy") as? Bool ?? false
    }

    // Build the "listen" array for naive config
    var listenURLs: [String] {
        var urls: [String] = []
        if socksEnabled {
            urls.append("socks://\(listenAddress):\(socksPort)")
        }
        if httpEnabled {
            urls.append("http://\(listenAddress):\(httpPort)")
        }
        return urls
    }

    // Build a naive-compatible config dict for a given profile
    func configDict(for profile: ServerProfile) -> [String: Any] {
        var dict: [String: Any] = [
            "listen": listenURLs.count == 1 ? listenURLs[0] : listenURLs,
            "proxy": profile.proxyURL,
            "log": ""
        ]
        return dict
    }

    func configJSON(for profile: ServerProfile) throws -> Data {
        let dict = configDict(for: profile)
        return try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
    }
}
