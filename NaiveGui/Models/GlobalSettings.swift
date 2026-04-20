import Foundation
import Combine

// Global settings for local listening (shared across all profiles)
final class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()
    private let defaults = AppEnvironment.sharedDefaults
    private var isSyncing = false
    private var ipcObserver: NSObjectProtocol?

    @Published var listenAddress: String {
        didSet { persist(listenAddress, forKey: "listenAddress") }
    }
    @Published var socksPort: Int {
        didSet { persist(socksPort, forKey: "socksPort") }
    }
    @Published var httpEnabled: Bool {
        didSet { persist(httpEnabled, forKey: "httpEnabled") }
    }
    @Published var httpPort: Int {
        didSet { persist(httpPort, forKey: "httpPort") }
    }
    @Published var naiveBinaryPath: String {
        didSet { persist(naiveBinaryPath, forKey: "naiveBinaryPath") }
    }
    @Published var autoSystemProxy: Bool {
        didSet { persist(autoSystemProxy, forKey: "autoSystemProxy") }
    }
    @Published var routingEnabled: Bool {
        didSet { persist(routingEnabled, forKey: "routingEnabled") }
    }
    @Published var routingPort: Int {
        didSet { persist(routingPort, forKey: "routingPort") }
    }
    @Published var routingHTTPPort: Int {
        didSet { persist(routingHTTPPort, forKey: "routingHTTPPort") }
    }
    @Published var singboxBinaryPath: String {
        didSet { persist(singboxBinaryPath, forKey: "singboxBinaryPath") }
    }
    @Published var routingListenAddress: String {
        didSet { persist(routingListenAddress, forKey: "routingListenAddress") }
    }

    init() {
        self.listenAddress = defaults.string(forKey: "listenAddress") ?? "127.0.0.1"
        self.socksPort = defaults.integer(forKey: "socksPort") == 0 ? 1080 : defaults.integer(forKey: "socksPort")
        self.httpEnabled = defaults.object(forKey: "httpEnabled") as? Bool ?? false
        self.httpPort = defaults.integer(forKey: "httpPort") == 0 ? 8080 : defaults.integer(forKey: "httpPort")
        self.naiveBinaryPath = defaults.string(forKey: "naiveBinaryPath") ?? "/Users/eugene/Downloads/naive-gui/naive"
        self.autoSystemProxy = defaults.object(forKey: "autoSystemProxy") as? Bool ?? false
        self.routingEnabled = defaults.object(forKey: "routingEnabled") as? Bool ?? false
        self.routingPort = defaults.integer(forKey: "routingPort") == 0 ? 1081 : defaults.integer(forKey: "routingPort")
        self.routingHTTPPort = defaults.integer(forKey: "routingHTTPPort") == 0 ? 1082 : defaults.integer(forKey: "routingHTTPPort")
        self.singboxBinaryPath = defaults.string(forKey: "singboxBinaryPath") ?? ""
        self.routingListenAddress = defaults.string(forKey: "routingListenAddress") ?? "127.0.0.1"

        ipcObserver = AppIPC.observe(.settingsChanged) { [weak self] in
            self?.reloadFromDefaults()
        }
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

    private func persist<T>(_ value: T, forKey key: String) {
        guard !isSyncing else { return }
        defaults.set(value, forKey: key)
        AppIPC.post(.settingsChanged)
    }

    private func reloadFromDefaults() {
        isSyncing = true
        listenAddress = defaults.string(forKey: "listenAddress") ?? "127.0.0.1"
        socksPort = defaults.integer(forKey: "socksPort") == 0 ? 1080 : defaults.integer(forKey: "socksPort")
        httpEnabled = defaults.object(forKey: "httpEnabled") as? Bool ?? false
        httpPort = defaults.integer(forKey: "httpPort") == 0 ? 8080 : defaults.integer(forKey: "httpPort")
        naiveBinaryPath = defaults.string(forKey: "naiveBinaryPath") ?? "/Users/eugene/Downloads/naive-gui/naive"
        autoSystemProxy = defaults.object(forKey: "autoSystemProxy") as? Bool ?? false
        routingEnabled = defaults.object(forKey: "routingEnabled") as? Bool ?? false
        routingPort = defaults.integer(forKey: "routingPort") == 0 ? 1081 : defaults.integer(forKey: "routingPort")
        routingHTTPPort = defaults.integer(forKey: "routingHTTPPort") == 0 ? 1082 : defaults.integer(forKey: "routingHTTPPort")
        singboxBinaryPath = defaults.string(forKey: "singboxBinaryPath") ?? ""
        routingListenAddress = defaults.string(forKey: "routingListenAddress") ?? "127.0.0.1"
        isSyncing = false
    }
}
