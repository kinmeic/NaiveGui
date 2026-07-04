import Foundation
import Combine

@MainActor
final class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()
    private let defaults = AppEnvironment.sharedDefaults

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
    @Published var routingPort: Int {
        didSet { persist(routingPort, forKey: "routingPort") }
    }
    @Published var routingHTTPPort: Int {
        didSet { persist(routingHTTPPort, forKey: "routingHTTPPort") }
    }
    @Published var routingListenAddress: String {
        didSet { persist(routingListenAddress, forKey: "routingListenAddress") }
    }
    @Published var routingDefaultOutbound: RuleAction {
        didSet { persist(routingDefaultOutbound.rawValue, forKey: "routingDefaultOutbound") }
    }
    @Published var dohEnabled: Bool {
        didSet { persist(dohEnabled, forKey: "dohEnabled") }
    }
    @Published var dohProvider: String {
        didSet { persist(dohProvider, forKey: "dohProvider") }
    }
    @Published var dohCustomURL: String {
        didSet { persist(dohCustomURL, forKey: "dohCustomURL") }
    }
    @Published var maxConnections: Int {
        didSet { persist(maxConnections, forKey: "maxConnections") }
    }

    init() {
        self.listenAddress = defaults.string(forKey: "listenAddress") ?? "127.0.0.1"
        self.socksPort = defaults.integer(forKey: "socksPort") == 0 ? 1080 : defaults.integer(forKey: "socksPort")
        self.httpEnabled = defaults.object(forKey: "httpEnabled") as? Bool ?? false
        self.httpPort = defaults.integer(forKey: "httpPort") == 0 ? 8080 : defaults.integer(forKey: "httpPort")
        self.naiveBinaryPath = defaults.string(forKey: "naiveBinaryPath") ?? ""
        self.autoSystemProxy = defaults.object(forKey: "autoSystemProxy") as? Bool ?? false
        self.routingPort = defaults.integer(forKey: "routingPort") == 0 ? 1081 : defaults.integer(forKey: "routingPort")
        self.routingHTTPPort = defaults.integer(forKey: "routingHTTPPort") == 0 ? 1082 : defaults.integer(forKey: "routingHTTPPort")
        self.routingListenAddress = defaults.string(forKey: "routingListenAddress") ?? "127.0.0.1"
        self.routingDefaultOutbound = GlobalSettings.loadRoutingDefaultOutbound(from: defaults)
        // DoH 配置：默认关闭，旧用户升级后行为不变（向后兼容）。
        self.dohEnabled = defaults.object(forKey: "dohEnabled") as? Bool ?? false
        self.dohProvider = defaults.string(forKey: "dohProvider") ?? "google"
        self.dohCustomURL = defaults.string(forKey: "dohCustomURL") ?? ""
        // 连接数上限：默认 1000（旧用户无此 key 时回退默认值）。
        let saved = defaults.integer(forKey: "maxConnections")
        self.maxConnections = saved > 0 ? saved : 1000
    }

    var listenURLs: [String] {
        var urls: [String] = []
        urls.append("socks://\(listenAddress):\(socksPort)")
        if httpEnabled {
            urls.append("http://\(listenAddress):\(httpPort)")
        }
        return urls
    }

    var routingListenURLs: [String] {
        [
            "socks://\(routingListenAddress):\(routingPort)",
            "http://\(routingListenAddress):\(routingHTTPPort)"
        ]
    }

    func configDict(for profile: ServerProfile) -> [String: Any] {
        let dict: [String: Any] = [
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
        defaults.set(value, forKey: key)
    }

    private static func loadRoutingDefaultOutbound(from defaults: UserDefaults) -> RuleAction {
        guard let rawValue = defaults.string(forKey: "routingDefaultOutbound"),
              let action = RuleAction(rawValue: rawValue),
              action == .direct || action == .proxy else {
            return .proxy
        }
        return action
    }
}
