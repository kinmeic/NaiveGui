import Foundation
import SwiftUI

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var profiles: [ServerProfile] = []
    @Published var selectedProfileId: UUID? {
        didSet {
            if let id = selectedProfileId {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedProfileId")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedProfileId")
            }
        }
    }
    @Published var isRunning: Bool = false
    @Published var activeProfileId: UUID?
    @Published var statusMessage: String = "Not Connected"

    let globalSettings = GlobalSettings.shared
    let logCapture = LogCaptureService.shared
    let networkMonitor = NetworkMonitorService.shared

    private let processManager = NaiveProcessManager.shared
    private let singboxManager = SingboxProcessManager.shared
    private let configManager = ConfigFileManager.shared
    private let singboxConfigManager = SingboxConfigManager.shared

    var selectedProfile: ServerProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    private init() {
        loadProfiles()
        setupProcessCallbacks()
    }

    func loadProfiles() {
        profiles = configManager.loadAllProfiles()
        if let saved = UserDefaults.standard.string(forKey: "selectedProfileId"),
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
        try? configManager.saveProfile(profile)
        profiles.append(profile)
        selectedProfileId = profile.id
    }

    func deleteProfile(_ id: UUID) {
        if isRunning && activeProfileId == id {
            stopProxy()
        }
        try? configManager.deleteProfile(id: id)
        profiles.removeAll { $0.id == id }
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
    }

    func moveSelectedProfileUp() {
        guard let id = selectedProfileId,
              let index = profiles.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        profiles.swapAt(index, index - 1)
    }

    func moveSelectedProfileDown() {
        guard let id = selectedProfileId,
              let index = profiles.firstIndex(where: { $0.id == id }),
              index < profiles.count - 1 else { return }
        profiles.swapAt(index, index + 1)
    }

    func duplicateProfile(_ profile: ServerProfile) {
        var copy = ServerProfile(
            name: "\(profile.name) Copy",
            serverAddress: profile.serverAddress,
            serverPort: profile.serverPort,
            username: profile.username,
            password: profile.password,
            proxyProtocol: profile.proxyProtocol
        )
        try? configManager.saveProfile(copy)
        profiles.append(copy)
        selectedProfileId = copy.id
    }

    func saveProfile(_ profile: inout ServerProfile) {
        profile.updatedAt = Date()
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        }
        try? configManager.saveProfile(profile)
    }

    func startProxy() {
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

        if globalSettings.routingEnabled && !FileManager.default.fileExists(atPath: globalSettings.singboxBinaryPath) {
            statusMessage = "Error: sing-box binary not found - set path in Settings"
            return
        }

        statusMessage = "Connecting..."
        NSLog("NaiveGui: Starting proxy with binary=\(globalSettings.naiveBinaryPath)")

        do {
            // 1. Start naive
            let configURL = try configManager.writeActiveConfig(for: profile)
            NSLog("NaiveGui: Config written to \(configURL.path)")
            try processManager.start(configURL: configURL, binaryPath: globalSettings.naiveBinaryPath)
            NSLog("NaiveGui: Process started, isRunning=\(processManager.isRunning)")
            activeProfileId = profile.id
            isRunning = true

            let naivePort = globalSettings.socksEnabled ? globalSettings.socksPort : globalSettings.httpPort

            // 2. Start sing-box if routing enabled
            if globalSettings.routingEnabled {
                let rules = singboxConfigManager.loadRules()
                let singboxConfigURL = try singboxConfigManager.writeSingboxConfig(
                    naivePort: naivePort,
                    routingPort: globalSettings.routingPort,
                    rules: rules
                )
                try singboxManager.start(configURL: singboxConfigURL, binaryPath: globalSettings.singboxBinaryPath)
                NSLog("NaiveGui: sing-box started on port \(globalSettings.routingPort)")
                statusMessage = "Connected: \(profile.name) (Routed)"
            } else {
                statusMessage = "Connected: \(profile.name)"
            }

            // 3. Start network monitoring
            networkMonitor.startMonitoring(port: naivePort, pid: processManager.pid)

            // 4. Set system proxy
            if globalSettings.autoSystemProxy {
                if globalSettings.routingEnabled {
                    // Route through sing-box
                    try? SystemProxyManager.setSOCKSProxy(host: globalSettings.listenAddress, port: globalSettings.routingPort, enabled: true)
                    try? SystemProxyManager.setHTTPProxy(host: globalSettings.listenAddress, port: globalSettings.routingPort + 1, enabled: true)
                } else {
                    // Direct to naive
                    if globalSettings.socksEnabled {
                        try? SystemProxyManager.setSOCKSProxy(host: globalSettings.listenAddress, port: globalSettings.socksPort, enabled: true)
                    }
                    if globalSettings.httpEnabled {
                        try? SystemProxyManager.setHTTPProxy(host: globalSettings.listenAddress, port: globalSettings.httpPort, enabled: true)
                    }
                }
            }
        } catch {
            NSLog("NaiveGui: Error starting proxy: \(error)")
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    func stopProxy() {
        // 1. Stop sing-box first
        singboxManager.stop()
        singboxConfigManager.deleteSingboxConfig()

        // 2. Stop naive
        processManager.stop()
        configManager.deleteActiveConfig()

        isRunning = false
        activeProfileId = nil
        statusMessage = "Disconnected"
        networkMonitor.stopMonitoring()

        if globalSettings.autoSystemProxy {
            SystemProxyManager.disableAllProxies()
        }
    }

    func toggleProxy() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isRunning {
                self.stopProxy()
            } else {
                self.startProxy()
            }
        }
    }

    private func setupProcessCallbacks() {
        processManager.onLogLine = { [weak self] line, isStderr in
            self?.logCapture.append("[naive] \(line)", isStderr: isStderr)
        }
        processManager.onUnexpectedExit = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                self.singboxManager.stop()
                self.isRunning = false
                self.activeProfileId = nil
                self.statusMessage = "Disconnected"
                self.networkMonitor.stopMonitoring()
                if self.globalSettings.autoSystemProxy {
                    SystemProxyManager.disableAllProxies()
                }
            }
        }

        singboxManager.onLogLine = { [weak self] line, isStderr in
            self?.logCapture.append("[sing-box] \(line)", isStderr: isStderr)
        }
        singboxManager.onUnexpectedExit = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                NSLog("NaiveGui: sing-box unexpectedly exited")
            }
        }
    }
}
