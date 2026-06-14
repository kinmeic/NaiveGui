import Foundation
import SwiftUI

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

    private var didSetSystemProxy = false

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
        let autoSystemProxy = globalSettings.autoSystemProxy
        let systemProxyBypassDomains = Self.systemProxyBypassDomains(
            naiveListenAddress: listenAddress,
            routingListenAddress: routingListenAddress,
            serverAddress: profile.serverAddress
        )
        let profileId = profile.id
        let profileName = profile.name

        isConnecting = true
        statusMessage = "Connecting..."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var attemptedSystemProxy = false
            do {
                let configURL = try self.configManager.writeActiveConfig(for: profile)
                if autoSystemProxy {
                    try SystemProxyManager.setProxyBypassDomains(systemProxyBypassDomains)
                }
                try self.processManager.start(configURL: configURL, binaryPath: naiveBinaryPath)
                try self.processManager.waitForSOCKSReady(host: listenAddress, port: naivePort)

                let rules = self.singboxConfigManager.loadRules()
                try self.routingManager.start(
                    naivePort: naivePort,
                    routingPort: routingPort,
                    routingHTTPPort: routingHTTPPort,
                    routingListenAddress: routingListenAddress,
                    defaultOutbound: defaultOutbound,
                    rules: rules
                )

                if autoSystemProxy {
                    attemptedSystemProxy = true
                    try SystemProxyManager.setSOCKSProxy(host: routingListenAddress, port: routingPort, enabled: true)
                    try SystemProxyManager.setHTTPProxy(host: routingListenAddress, port: routingHTTPPort, enabled: true)
                }

                DispatchQueue.main.async {
                    self.activeProfileId = profileId
                    self.setRunning(true)
                    self.didSetSystemProxy = autoSystemProxy
                    self.isConnecting = false
                    self.statusMessage = "Connected: \(profileName) (Routed)"
                }
            } catch {
                self.routingManager.stop()
                self.singboxConfigManager.deleteSingboxConfig()
                self.processManager.stop()
                self.configManager.deleteActiveConfig()
                if attemptedSystemProxy {
                    SystemProxyManager.disableAllProxies()
                }

                DispatchQueue.main.async {
                    self.isConnecting = false
                    self.isRunning = false
                    self.defaults.set(false, forKey: "isRunning")
                    self.activeProfileId = nil
                    self.statusMessage = "Error: \(error.localizedDescription)"
                    self.clearSystemProxyIfNeeded()
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
        isConnecting = false
        routingManager.stop()
        singboxConfigManager.deleteSingboxConfig()
        processManager.stop()
        configManager.deleteActiveConfig()

        setRunning(false)
        activeProfileId = nil
        statusMessage = "Disconnected"
        clearSystemProxyIfNeeded()
    }

    func toggleProxy() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reconcileRuntimeState()
            if self.isRunning {
                self.stopProxy()
            } else {
                self.startProxy()
            }
        }
    }

    func requestQuit() {
        quitRequested = true
        if isRunning {
            stopProxy()
        }
        NSApp.terminate(nil)
    }

    private func setupProcessCallbacks() {
        processManager.onLogLine = { [weak self] line, isStderr in
            self?.logCapture.append("[naive] \(line)", isStderr: isStderr)
        }
        processManager.onUnexpectedExit = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                self.routingManager.stop()
                self.setRunning(false)
                self.activeProfileId = nil
                self.statusMessage = "Disconnected"
                self.clearSystemProxyIfNeeded()
            }
        }

        routingManager.onLogLine = { [weak self] line, isStderr in
            self?.logCapture.append("[router] \(line)", isStderr: isStderr)
        }
        routingManager.onUnexpectedExit = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isRunning else { return }
                self.processManager.stop()
                self.singboxConfigManager.deleteSingboxConfig()
                self.configManager.deleteActiveConfig()
                self.setRunning(false)
                self.activeProfileId = nil
                self.statusMessage = "Disconnected"
                self.clearSystemProxyIfNeeded()
            }
        }
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
        SystemProxyManager.disableAllProxies()
    }
}
