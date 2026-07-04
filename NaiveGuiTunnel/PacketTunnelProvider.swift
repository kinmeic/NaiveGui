import Foundation
import NetworkExtension

/// NetworkExtension 主类：系统调度的 Packet Tunnel Provider。
///
/// 生命周期：
/// - startTunnel：读共享配置 → 启动 naive → 配置虚拟网卡 → 启动 TunnelEngine
/// - stopTunnel：停止引擎 → 停止 naive → 清理
///
/// 自环防护：naive 服务器的 IP 通过 excludedRoutes 走物理网卡，
/// 其余流量走 utun（includedRoutes = default）。
class PacketTunnelProvider: NEPacketTunnelProvider {
    private var engine: TunnelEngine?
    private var naiveManager: NaiveProcessManager?

    override func startTunnel(options: [String: NSObject]?,
                              completionHandler: @escaping (Error?) -> Void) {
        // 1. 读 App Group 共享配置（主 App 写入的 profile + 规则 + DoH 设置）。
        let defaults = UserDefaults(suiteName: AppEnvironment.sharedDefaultsSuite) ?? .standard
        guard let profileData = defaults.data(forKey: "activeProfile"),
              let profile = try? JSONDecoder().decode(ServerProfile.self, from: profileData) else {
            completionHandler(NeError.noProfile)
            return
        }

        // 2. 启动 naive 子进程（在扩展内启动，主 App 退出不影响）。
        let naivePort = defaults.integer(forKey: "socksPort").nonZero ?? 1080
        let binaryPath = defaults.string(forKey: "naiveBinaryPath") ?? ""
        let listenAddress = defaults.string(forKey: "listenAddress") ?? "127.0.0.1"

        let manager = NaiveProcessManager.shared
        do {
            let configURL = try writeConfig(for: profile, defaults: defaults)
            try manager.start(configURL: configURL, binaryPath: binaryPath)
            try manager.waitForSOCKSReady(host: listenAddress, port: naivePort)
        } catch {
            completionHandler(error)
            return
        }
        naiveManager = manager

        // 3. 配置虚拟网卡 + 自环防护。
        let tunnelSettings = buildTunnelSettings(excluding: profile.serverAddress)
        setTunnelNetworkSettings(tunnelSettings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            if let error {
                self.naiveManager?.stop()
                completionHandler(error)
                return
            }

            // 4. 初始化规则引擎 + DoH + 包处理引擎。
            let rules = self.loadRules()
            let cacheURL = Self.ruleSetCacheDirectory()
            let routeMatcher = NativeRouteMatcher(
                defaultOutbound: self.loadDefaultOutbound(defaults: defaults),
                rules: rules,
                ruleSetStore: RuleSetStore(cacheDirectory: cacheURL) { _, _ in },
                logger: nil
            )
            routeMatcher.preloadRuleSets()

            let resolver = DNSResolver.shared
            resolver.socksProxyHost = NaiveProcessManager.probeListenHost(for: listenAddress)
            resolver.socksProxyPort = naivePort

            let dnsInterceptor = DnsInterceptor(resolver: resolver)
            let udpRelay = UdpRelay(matcher: routeMatcher, naivePort: naivePort)
            let tcpReassembler = TcpReassembler()

            self.engine = TunnelEngine(
                packetFlow: self.packetFlow,
                dnsInterceptor: dnsInterceptor,
                udpRelay: udpRelay,
                tcpReassembler: tcpReassembler,
                matcher: routeMatcher,
                naivePort: naivePort
            )
            self.engine?.start()
            completionHandler(nil)
        }
    }

    override func stopTunnel(reason: NEProviderStopReason,
                             completionHandler: @escaping () -> Void) {
        engine?.stop()
        engine = nil
        naiveManager?.stop()
        naiveManager = nil
        completionHandler()
    }

    // MARK: - 隧道网络设置

    private func buildTunnelSettings(excluding serverIP: String) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // 自环防护：naive 服务器走物理网卡，不进 utun。
        ipv4.excludedRoutes = [
            NEIPv4Route(destinationAddress: serverIP, subnetMask: "255.255.255.255")
        ]
        settings.ipv4Settings = ipv4
        // 虚拟 DNS 服务器（DnsInterceptor 会处理 53 端口）。
        settings.dnsSettings = NEDNSSettings(servers: ["198.18.0.2"])
        // MTU 1400：TUN 虚拟网卡的典型值，留余量给外层封装（TLS/HTTP2），避免分片。
        settings.mtu = 1400
        return settings
    }

    // MARK: - 辅助

    private func writeConfig(for profile: ServerProfile, defaults: UserDefaults) throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaiveGui", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let configURL = appSupport.appendingPathComponent("tunnel-active.json")
        let config = GlobalSettings.shared.configDict(for: profile)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        return configURL
    }

    private func loadRules() -> [RoutingRule] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NaiveGui", isDirectory: true)
        let url = appSupport.appendingPathComponent("routing-rules.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RoutingRule].self, from: data)) ?? []
    }

    private func loadDefaultOutbound(defaults: UserDefaults) -> RuleAction {
        guard let raw = defaults.string(forKey: "routingDefaultOutbound"),
              let action = RuleAction(rawValue: raw),
              action == .direct || action == .proxy else {
            return .proxy
        }
        return action
    }

    private static func ruleSetCacheDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("NaiveGui", isDirectory: true)
            .appendingPathComponent("rule-set-cache", isDirectory: true)
    }
}

private extension Int {
    var nonZero: Int? { self > 0 ? self : nil }
}

enum NeError: LocalizedError {
    case noProfile

    var errorDescription: String? {
        switch self {
        case .noProfile: return "No active profile configured for transparent proxy"
        }
    }
}
