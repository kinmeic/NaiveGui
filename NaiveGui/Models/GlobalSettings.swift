import Foundation
import Combine

// Global settings for local listening (shared across all profiles)
final class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()

    @Published var listenAddress: String {
        didSet { UserDefaults.standard.set(listenAddress, forKey: "listenAddress") }
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
    @Published var routingEnabled: Bool {
        didSet { UserDefaults.standard.set(routingEnabled, forKey: "routingEnabled") }
    }
    @Published var routingPort: Int {
        didSet { UserDefaults.standard.set(routingPort, forKey: "routingPort") }
    }
    @Published var singboxBinaryPath: String {
        didSet { UserDefaults.standard.set(singboxBinaryPath, forKey: "singboxBinaryPath") }
    }
    @Published var routingListenAddress: String {
        didSet { UserDefaults.standard.set(routingListenAddress, forKey: "routingListenAddress") }
    }

    init() {
        self.listenAddress = UserDefaults.standard.string(forKey: "listenAddress") ?? "127.0.0.1"
        self.socksPort = UserDefaults.standard.integer(forKey: "socksPort") == 0 ? 1080 : UserDefaults.standard.integer(forKey: "socksPort")
        self.httpEnabled = UserDefaults.standard.object(forKey: "httpEnabled") as? Bool ?? false
        self.httpPort = UserDefaults.standard.integer(forKey: "httpPort") == 0 ? 8080 : UserDefaults.standard.integer(forKey: "httpPort")
        self.naiveBinaryPath = UserDefaults.standard.string(forKey: "naiveBinaryPath") ?? "/Users/eugene/Downloads/naive-gui/naive"
        self.autoSystemProxy = UserDefaults.standard.object(forKey: "autoSystemProxy") as? Bool ?? false
        self.routingEnabled = UserDefaults.standard.object(forKey: "routingEnabled") as? Bool ?? false
        self.routingPort = UserDefaults.standard.integer(forKey: "routingPort") == 0 ? 1081 : UserDefaults.standard.integer(forKey: "routingPort")
        self.singboxBinaryPath = UserDefaults.standard.string(forKey: "singboxBinaryPath") ?? ""
        self.routingListenAddress = UserDefaults.standard.string(forKey: "routingListenAddress") ?? "127.0.0.1"
    }

    // Build the "listen" array for naive config
    var listenURLs: [String] {
        var urls: [String] = []
        urls.append("socks://\(listenAddress):\(socksPort)")
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
