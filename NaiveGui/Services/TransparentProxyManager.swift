import Foundation
import NetworkExtension

/// 主 App 侧的透明代理控制器：通过 NETunnelProviderManager 启停 NE 隧道。
///
/// 与 AppState 的 stub 对接：entitlement 到位后，startTransparentProxy/stopTransparentProxy
/// 调用此类的方法，由系统加载 NaiveGuiTunnel 扩展。
final class TransparentProxyManager {
    static let shared = TransparentProxyManager()

    private init() {}

    /// 启用 NE 隧道。写共享配置 → 创建/更新 VPN 配置 → 启动。
    /// 调用方（MainActor）预先传入所需设置值，避免 async 方法跨 actor 访问 GlobalSettings。
    func enable(profile: ServerProfile,
                socksPort: Int,
                naiveBinaryPath: String,
                listenAddress: String,
                defaultOutbound: String) async throws {
        // 1. 写共享配置到 App Group UserDefaults（扩展进程读）。
        let defaults = UserDefaults(suiteName: AppEnvironment.sharedDefaultsSuite) ?? .standard
        let profileData = try JSONEncoder().encode(profile)
        defaults.set(profileData, forKey: "activeProfile")
        defaults.set(socksPort, forKey: "socksPort")
        defaults.set(naiveBinaryPath, forKey: "naiveBinaryPath")
        defaults.set(listenAddress, forKey: "listenAddress")
        defaults.set(defaultOutbound, forKey: "routingDefaultOutbound")

        // 2. 创建或更新 NETunnelProvider 配置。
        let manager = try await loadOrCreateManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.naive.gui.tunnel"
        proto.serverAddress = profile.serverAddress
        manager.protocolConfiguration = proto
        manager.localizedDescription = "NaiveGui Transparent Proxy"
        manager.isEnabled = true
        try await manager.saveToPreferences()

        // 3. 启动隧道。
        try manager.connection.startVPNTunnel()
    }

    /// 禁用 NE 隧道。
    func disable() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        for m in managers {
            if m.connection.status == .connected || m.connection.status == .connecting {
                m.connection.stopVPNTunnel()
            }
        }
    }

    /// 当前隧道状态。
    var status: NEVPNStatus {
        // 同步读取（loadAllFromPreferences 是 async，这里给个近似值）。
        // 精确状态需 await loadAllFromPreferences 后查 connection.status。
        return .invalid
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first ?? NETunnelProviderManager()
    }
}
