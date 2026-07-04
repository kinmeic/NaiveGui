import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    private let defaults = AppEnvironment.sharedDefaults

    @Published var profiles: [ServerProfile] = []
    @Published var selectedProfileId: UUID? {
        didSet {
            if let id = selectedProfileId {
                defaults.set(id.uuidString, forKey: "selectedProfileId")
            } else {
                defaults.removeObject(forKey: "selectedProfileId")
            }
        }
    }
    @Published var isRunning: Bool = false
    @Published var isConnecting: Bool = false
    @Published var activeProfileId: UUID?
    @Published var statusMessage: String = "Not Connected"
    @Published var quitRequested: Bool = false
    /// 是否正在自动重连（指数退避等待中）。UI 可据此显示状态。
    @Published var isReconnecting: Bool = false

    private var didSetSystemProxy = false
    /// 启用系统代理前捕获的快照，断开/崩溃恢复时用于恢复用户原有设置。
    private var systemProxySnapshot: SystemProxySnapshot?
    /// 自动重连：重试次数（指数退避后清零）。
    private var reconnectAttempts = 0
    /// 自动重连：当前重连任务（用于用户主动断开时取消）。
    private var reconnectWorkItem: DispatchWorkItem?
    /// 自动重连：上次连接使用的 profile id（重连用同一配置）。
    private var lastConnectedProfileId: UUID?
    private let maxReconnectAttempts = 10

    let globalSettings = GlobalSettings.shared
    let logCapture = LogCaptureService.shared

    private let processManager = NaiveProcessManager.shared
    private let routingManager = NativeRoutingProxyManager.shared
    private let configManager = ConfigFileManager.shared
    private let singboxConfigManager = SingboxConfigManager.shared

    var selectedProfile: ServerProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    private init() {
        configManager.ensureDirectories()
        // 启动时检测上次崩溃残留的系统代理，恢复用户原有设置。
        SystemProxyManager.recoverIfNeeded()
        loadProfiles()
        reconcileRuntimeState()
        setupProcessCallbacks()
    }

    func loadProfiles() {
        profiles = configManager.loadAllProfiles()
        if let saved = defaults.string(forKey: "selectedProfileId"),
           let id = UUID(uuidString: saved),
           profiles.contains(where: { $0.id == id }) {
            selectedProfileId = id
        } else {
            selectedProfileId = profiles.first?.id
        }
    }

    func addProfile() {
        let profile = ServerProfile(
            name: "New Server",
            serverAddress: "",
            serverPort: 443,
            username: "",
            password: ""
        )
        do {
            try configManager.saveProfile(profile)
            profiles.append(profile)
            configManager.saveProfileOrder(profiles)
            selectedProfileId = profile.id
        } catch {
            statusMessage = "Error adding profile: \(error.localizedDescription)"
        }
    }

    func deleteProfile(_ id: UUID) {
        if isRunning && activeProfileId == id {
            stopProxy()
        }
        do {
            try configManager.deleteProfile(id: id)
            profiles.removeAll { $0.id == id }
            configManager.saveProfileOrder(profiles)
            if selectedProfileId == id {
                selectedProfileId = profiles.first?.id
            }
        } catch {
            statusMessage = "Error deleting profile: \(error.localizedDescription)"
        }
    }

    func moveSelectedProfileUp() {
        guard let id = selectedProfileId,
              let index = profiles.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        profiles.swapAt(index, index - 1)
        configManager.saveProfileOrder(profiles)
    }

    func moveSelectedProfileDown() {
        guard let id = selectedProfileId,
              let index = profiles.firstIndex(where: { $0.id == id }),
              index < profiles.count - 1 else { return }
        profiles.swapAt(index, index + 1)
        configManager.saveProfileOrder(profiles)
    }

    func duplicateProfile(_ profile: ServerProfile) {
        let copy = ServerProfile(
            name: "\(profile.name) Copy",
            serverAddress: profile.serverAddress,
            serverPort: profile.serverPort,
            username: profile.username,
            password: profile.password,
            proxyProtocol: profile.proxyProtocol
        )
        do {
            try configManager.saveProfile(copy)
            profiles.append(copy)
            configManager.saveProfileOrder(profiles)
            selectedProfileId = copy.id
        } catch {
            statusMessage = "Error duplicating profile: \(error.localizedDescription)"
        }
    }

    func saveProfile(_ profile: inout ServerProfile) {
        profile.updatedAt = Date()
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        }
        do {
            try configManager.saveProfile(profile)
        } catch {
            statusMessage = "Error saving profile: \(error.localizedDescription)"
        }
    }

    func startProxy() {
        guard !isConnecting else { return }
        loadProfiles()
        guard let profile = selectedProfile else {
            NSLog("NaiveGui: No profile selected")
            return
        }
        guard !profile.serverAddress.isEmpty else {
            statusMessage = "Error: Server address is empty"
            return
        }
        guard !globalSettings.listenURLs.isEmpty else {
            statusMessage = "Error: No listen protocol enabled"
            return
        }
        guard FileManager.default.fileExists(atPath: globalSettings.naiveBinaryPath) else {
            statusMessage = "Error: Binary not found - set path in Settings"
            return
        }

        let naiveBinaryPath = globalSettings.naiveBinaryPath
        let listenAddress = globalSettings.listenAddress
        let naivePort = globalSettings.socksPort
        let routingPort = globalSettings.routingPort
        let routingHTTPPort = globalSettings.routingHTTPPort
        let routingListenAddress = globalSettings.routingListenAddress
        let defaultOutbound = globalSettings.routingDefaultOutbound
        let maxConnections = globalSettings.maxConnections
        let proxyMode = globalSettings.proxyMode
        let activeConfigData: Data
        do {
            activeConfigData = try globalSettings.configJSON(for: profile)
        } catch {
            statusMessage = "Error creating config: \(error.localizedDescription)"
            return
        }
        let dohURL: URL?
        if globalSettings.dohEnabled {
            if globalSettings.dohProvider == "custom" {
                dohURL = URL(string: globalSettings.dohCustomURL)
            } else {
                dohURL = DNSResolver.Provider(rawValue: globalSettings.dohProvider)?.url
            }
        } else {
            dohURL = nil
        }
        let dnsConfiguration = DNSResolver.Configuration(
            enabled: globalSettings.dohEnabled && dohURL != nil,
            url: dohURL,
            socksProxyHost: NaiveProcessManager.probeListenHost(for: listenAddress),
            socksProxyPort: naivePort,
            timeout: 5
        )
        let systemProxyBypassDomains = Self.systemProxyBypassDomains(
            naiveListenAddress: listenAddress,
            routingListenAddress: routingListenAddress,
            serverAddress: profile.serverAddress
        )
        let profileId = profile.id
        let profileName = profile.name

        isConnecting = true
        statusMessage = "Connecting..."

        let configManager = configManager
        let processManager = processManager
        let routingManager = routingManager
        let singboxConfigManager = singboxConfigManager
        DispatchQueue.global(qos: .userInitiated).async {
            // attemptedSystemProxy：只要 capture 了快照就视为"已尝试"，任一后续步骤失败都要恢复。
            var attemptedSystemProxy = false
            var capturedSnapshot: SystemProxySnapshot?
            do {
                let configURL = try configManager.writeActiveConfig(data: activeConfigData)
                if proxyMode == .systemProxy {
                    // 先保存用户原有代理设置，断开/失败时能恢复，避免破坏。
                    capturedSnapshot = try SystemProxyManager.captureAndPrepare()
                    attemptedSystemProxy = true
                    try SystemProxyManager.setProxyBypassDomains(systemProxyBypassDomains)
                }
                try processManager.start(configURL: configURL, binaryPath: naiveBinaryPath)
                try processManager.waitForSOCKSReady(host: listenAddress, port: naivePort)

                // naive 就绪后配置 DoH 解析器：让 DoH 请求经本地 naive SOCKS5 代理发出，避免 DNS 泄漏。
                // DoH 默认关闭，未启用时 DNSResolver.resolve 直接返回空，行为与改造前一致。
                DNSResolver.shared.configure(dnsConfiguration)

                let rules = singboxConfigManager.loadRules()
                try routingManager.start(
                    naivePort: naivePort,
                    routingPort: routingPort,
                    routingHTTPPort: routingHTTPPort,
                    routingListenAddress: routingListenAddress,
                    defaultOutbound: defaultOutbound,
                    rules: rules,
                    maxConnections: maxConnections
                )

                if proxyMode == .transparent {
                    self.startTransparentProxy()
                } else if proxyMode == .systemProxy {
                    try SystemProxyManager.setSOCKSProxy(host: routingListenAddress, port: routingPort, enabled: true)
                    try SystemProxyManager.setHTTPProxy(host: routingListenAddress, port: routingHTTPPort, enabled: true)
                }

                // 在 Task 前用 let 捕获快照，避免 var 在并发闭包中的数据竞争。
                let snapshotToStore = capturedSnapshot
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeProfileId = profileId
                    self.setRunning(true)
                    self.didSetSystemProxy = proxyMode == .systemProxy
                    self.systemProxySnapshot = snapshotToStore
                    self.isConnecting = false
                    self.statusMessage = "Connected: \(profileName) (Routed)"
                    // 连接成功：记录 profile 用于自动重连，重置退避计数。
                    self.lastConnectedProfileId = profileId
                    self.reconnectAttempts = 0
                }
            } catch {
                routingManager.stop()
                singboxConfigManager.deleteSingboxConfig()
                processManager.stop()
                configManager.deleteActiveConfig()
                if attemptedSystemProxy {
                    // 用快照恢复，而非无脑关闭，保护用户原有代理设置。
                    SystemProxyManager.restoreProxies(snapshot: capturedSnapshot)
                }

                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isConnecting = false
                    self.isRunning = false
                    self.defaults.set(false, forKey: "isRunning")
                    self.activeProfileId = nil
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.didSetSystemProxy = false
                    self.systemProxySnapshot = nil
                }
            }
        }
    }

    private static func systemProxyBypassDomains(
        naiveListenAddress: String,
        routingListenAddress: String,
        serverAddress: String
    ) -> [String] {
        [
            "localhost",
            "127.0.0.1",
            "127.0.0.0/8",
            "::1",
            "*.local",
            "169.254/16",
            naiveListenAddress,
            routingListenAddress,
            serverAddress
        ]
    }

    func stopProxy() {
        cancelReconnect()
        isConnecting = false
        stopTransparentProxy()
        routingManager.stop()
        singboxConfigManager.deleteSingboxConfig()
        processManager.stop()
        configManager.deleteActiveConfig()
        ConnectionTracker.shared.reset()

        setRunning(false)
        activeProfileId = nil
        statusMessage = "Disconnected"
        clearSystemProxyIfNeeded()
    }

    // MARK: - Transparent Proxy (NetworkExtension)

    /// 启动透明代理（TUN 模式）。通过 NETunnelProviderManager 加载 NE 扩展。
    private func startTransparentProxy() {
        guard let profile = selectedProfile else {
            logCapture.append("[app] transparent proxy: no profile selected", isStderr: true)
            return
        }
        Task {
            do {
                try await TransparentProxyManager.shared.enable(
                    profile: profile,
                    socksPort: globalSettings.socksPort,
                    naiveBinaryPath: globalSettings.naiveBinaryPath,
                    listenAddress: globalSettings.listenAddress,
                    defaultOutbound: globalSettings.routingDefaultOutbound.rawValue
                )
                logCapture.append("[app] transparent proxy (TUN) tunnel started", isStderr: false)
            } catch {
                logCapture.append("[app] transparent proxy failed: \(error.localizedDescription)", isStderr: true)
                await MainActor.run {
                    self.statusMessage = "TUN mode failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 停止透明代理。
    private func stopTransparentProxy() {
        Task {
            try? await TransparentProxyManager.shared.disable()
            logCapture.append("[app] transparent proxy (TUN) tunnel stopped", isStderr: false)
        }
    }

    func toggleProxy() {
        reconcileRuntimeState()
        if isRunning {
            stopProxy()
        } else {
            startProxy()
        }
    }

    func requestQuit() {
        quitRequested = true
        // 取消挂起的自动重连，避免退出后又触发重连。
        cancelReconnect()
        // 无论 isRunning 还是 isConnecting（naive 可能已起但未就绪），都要停。
        // stopProxy 内部会处理 isConnecting 标志并清理子进程。
        stopProxy()
        NSApp.terminate(nil)
    }

    private func setupProcessCallbacks() {
        let logCapture = logCapture
        processManager.onLogLine = { line, isStderr in
            logCapture.append("[naive] \(line)", isStderr: isStderr)
        }
        processManager.onUnexpectedExit = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                // naive 意外退出：先清理子状态，再尝试自动重连（指数退避）。
                self.routingManager.stop()
                self.setRunning(false)
                self.activeProfileId = nil
                self.clearSystemProxyIfNeeded()
                self.scheduleReconnect()
            }
        }

        routingManager.onLogLine = { line, isStderr in
            logCapture.append("[router] \(line)", isStderr: isStderr)
        }
        routingManager.onUnexpectedExit = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                // 路由代理崩溃：清理子状态，再尝试自动重连。
                self.processManager.stop()
                self.singboxConfigManager.deleteSingboxConfig()
                self.configManager.deleteActiveConfig()
                self.setRunning(false)
                self.activeProfileId = nil
                self.clearSystemProxyIfNeeded()
                self.scheduleReconnect()
            }
        }
    }

    /// 自动重连调度。指数退避：1s → 2s → 4s → 8s → 16s，封顶 30s。
    /// 最多重试 maxReconnectAttempts 次，超过后放弃并提示用户。
    private func scheduleReconnect() {
        // 用户正在退出 → 不重连。
        guard !quitRequested else {
            isReconnecting = false
            statusMessage = "Disconnected"
            return
        }
        guard reconnectAttempts < maxReconnectAttempts else {
            isReconnecting = false
            statusMessage = "Reconnect failed after \(maxReconnectAttempts) attempts; disconnected"
            logCapture.append("[app] auto-reconnect gave up after \(maxReconnectAttempts) attempts", isStderr: true)
            return
        }
        // 重连必须基于上次的 profile；若已删除则放弃。
        guard let profileId = lastConnectedProfileId,
              profiles.contains(where: { $0.id == profileId }) else {
            isReconnecting = false
            statusMessage = "Disconnected (profile no longer available)"
            return
        }

        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts - 1)), 30.0)
        isReconnecting = true
        statusMessage = "Reconnecting in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts))..."
        logCapture.append("[app] naive exited unexpectedly; reconnect #\(reconnectAttempts) in \(Int(delay))s", isStderr: false)

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 等待期间用户可能主动断开或退出。
            guard !self.quitRequested, self.isReconnecting else {
                self.isReconnecting = false
                return
            }
            // 切回 selectedProfile 为上次连接的 profile，然后触发连接。
            self.selectedProfileId = profileId
            self.isReconnecting = false
            self.startProxy()
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// 取消挂起的自动重连（用户主动断开时调用）。
    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if isReconnecting {
            isReconnecting = false
        }
        reconnectAttempts = 0
    }

    private func reconcileRuntimeState() {
        guard isRunning || defaults.bool(forKey: "isRunning") else { return }
        guard !processManager.isRunning else { return }

        routingManager.stop()
        singboxConfigManager.deleteSingboxConfig()
        configManager.deleteActiveConfig()

        setRunning(false)
        activeProfileId = nil
        statusMessage = "Disconnected"
        clearSystemProxyIfNeeded()
    }

    private func setRunning(_ value: Bool) {
        isRunning = value
        defaults.set(value, forKey: "isRunning")
    }

    private func clearSystemProxyIfNeeded() {
        guard didSetSystemProxy else { return }
        didSetSystemProxy = false
        // 用快照恢复用户原有代理设置，而非无脑关闭所有代理。
        SystemProxyManager.restoreProxies(snapshot: systemProxySnapshot)
        systemProxySnapshot = nil
    }
}
