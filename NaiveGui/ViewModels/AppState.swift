import Foundation
import SwiftUI

final class AppState: ObservableObject {
    static let shared = AppState()
    private let defaults = AppEnvironment.sharedDefaults
    private let role = AppRole.current
    private var isSyncingState = false
    private var ipcObservers: [NSObjectProtocol] = []

    @Published var profiles: [ServerProfile] = []
    @Published var selectedProfileId: UUID? {
        didSet {
            guard !isSyncingState else { return }
            if let id = selectedProfileId {
                defaults.set(id.uuidString, forKey: "selectedProfileId")
            } else {
                defaults.removeObject(forKey: "selectedProfileId")
            }
            AppIPC.post(.selectedProfileChanged)
        }
    }
    @Published var isRunning: Bool = false {
        didSet { publishSharedStateIfNeeded() }
    }
    @Published var activeProfileId: UUID? {
        didSet { publishSharedStateIfNeeded() }
    }
    @Published var statusMessage: String = "Not Connected" {
        didSet { publishSharedStateIfNeeded() }
    }
    @Published var quitRequested: Bool = false

    let globalSettings = GlobalSettings.shared
    let logCapture = LogCaptureService.shared

    private let processManager = NaiveProcessManager.shared
    private let singboxManager = SingboxProcessManager.shared
    private let configManager = ConfigFileManager.shared
    private let singboxConfigManager = SingboxConfigManager.shared

    var selectedProfile: ServerProfile? {
        profiles.first { $0.id == selectedProfileId }
    }

    private init() {
        configManager.ensureDirectories()
        loadProfiles()
        if role == .menuBarHost {
            reconcileRuntimeState()
            setupProcessCallbacks()
        } else {
            syncSharedState()
        }
        setupIPC()
    }

    func loadProfiles() {
        profiles = configManager.loadAllProfiles()
        if let saved = defaults.string(forKey: "selectedProfileId"),
           let id = UUID(uuidString: saved),
           profiles.contains(where: { $0.id == id }) {
            isSyncingState = true
            selectedProfileId = id
            isSyncingState = false
        } else {
            isSyncingState = true
            selectedProfileId = profiles.first?.id
            isSyncingState = false
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
        configManager.saveProfileOrder(profiles)
        selectedProfileId = profile.id
        AppIPC.post(.profilesChanged)
    }

    func deleteProfile(_ id: UUID) {
        if isRunning && activeProfileId == id {
            stopProxy()
        }
        try? configManager.deleteProfile(id: id)
        profiles.removeAll { $0.id == id }
        configManager.saveProfileOrder(profiles)
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
        AppIPC.post(.profilesChanged)
    }

    func moveSelectedProfileUp() {
        guard let id = selectedProfileId,
              let index = profiles.firstIndex(where: { $0.id == id }),
              index > 0 else { return }
        profiles.swapAt(index, index - 1)
        configManager.saveProfileOrder(profiles)
        AppIPC.post(.profilesChanged)
    }

    func moveSelectedProfileDown() {
        guard let id = selectedProfileId,
              let index = profiles.firstIndex(where: { $0.id == id }),
              index < profiles.count - 1 else { return }
        profiles.swapAt(index, index + 1)
        configManager.saveProfileOrder(profiles)
        AppIPC.post(.profilesChanged)
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
        configManager.saveProfileOrder(profiles)
        selectedProfileId = copy.id
        AppIPC.post(.profilesChanged)
    }

    func saveProfile(_ profile: inout ServerProfile) {
        profile.updatedAt = Date()
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
        }
        try? configManager.saveProfile(profile)
        AppIPC.post(.profilesChanged)
    }

    func startProxy() {
        guard role == .menuBarHost else {
            AppIPC.post(.toggleProxyRequested)
            return
        }
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

            let naivePort = globalSettings.socksPort

            // 2. Start sing-box if routing enabled
            if globalSettings.routingEnabled {
                let rules = singboxConfigManager.loadRules()
                let singboxConfigURL = try singboxConfigManager.writeSingboxConfig(
                    naivePort: naivePort,
                    routingPort: globalSettings.routingPort,
                    routingHTTPPort: globalSettings.routingHTTPPort,
                    routingListenAddress: globalSettings.routingListenAddress,
                    rules: rules
                )
                try singboxManager.start(configURL: singboxConfigURL, binaryPath: globalSettings.singboxBinaryPath)
                NSLog("NaiveGui: sing-box started on port \(globalSettings.routingPort)")
                isRunning = true
                statusMessage = "Connected: \(profile.name) (Routed)"
            } else {
                isRunning = true
                statusMessage = "Connected: \(profile.name)"
            }

            // Set system proxy
            if globalSettings.autoSystemProxy {
                if globalSettings.routingEnabled {
                    // Route through sing-box
                    try? SystemProxyManager.setSOCKSProxy(host: globalSettings.routingListenAddress, port: globalSettings.routingPort, enabled: true)
                    try? SystemProxyManager.setHTTPProxy(host: globalSettings.routingListenAddress, port: globalSettings.routingHTTPPort, enabled: true)
                } else {
                    // Direct to naive
                    try? SystemProxyManager.setSOCKSProxy(host: globalSettings.listenAddress, port: globalSettings.socksPort, enabled: true)
                    if globalSettings.httpEnabled {
                        try? SystemProxyManager.setHTTPProxy(host: globalSettings.listenAddress, port: globalSettings.httpPort, enabled: true)
                    }
                }
            }
        } catch {
            singboxManager.stop()
            singboxConfigManager.deleteSingboxConfig()
            processManager.stop()
            configManager.deleteActiveConfig()
            isRunning = false
            activeProfileId = nil
            NSLog("NaiveGui: Error starting proxy: \(error)")
            statusMessage = "Error: \(error.localizedDescription)"
            if globalSettings.autoSystemProxy {
                SystemProxyManager.disableAllProxies()
            }
        }
    }

    func stopProxy() {
        guard role == .menuBarHost else {
            AppIPC.post(.toggleProxyRequested)
            return
        }
        // 1. Stop sing-box first
        singboxManager.stop()
        singboxConfigManager.deleteSingboxConfig()

        // 2. Stop naive
        processManager.stop()
        configManager.deleteActiveConfig()

        isRunning = false
        activeProfileId = nil
        statusMessage = "Disconnected"

        if globalSettings.autoSystemProxy {
            SystemProxyManager.disableAllProxies()
        }
    }

    func toggleProxy() {
        guard role == .menuBarHost else {
            AppIPC.post(.toggleProxyRequested)
            return
        }
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
        guard role == .menuBarHost else {
            NSApp.terminate(nil)
            return
        }
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
                self.singboxManager.stop()
                self.isRunning = false
                self.activeProfileId = nil
                self.statusMessage = "Disconnected"
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
                self.processManager.stop()
                self.singboxConfigManager.deleteSingboxConfig()
                self.configManager.deleteActiveConfig()
                self.isRunning = false
                self.activeProfileId = nil
                self.statusMessage = "Disconnected"
                if self.globalSettings.autoSystemProxy {
                    SystemProxyManager.disableAllProxies()
                }
            }
        }
    }

    private func setupIPC() {
        ipcObservers.append(AppIPC.observe(.profilesChanged) { [weak self] in
            self?.loadProfiles()
        })
        ipcObservers.append(AppIPC.observe(.selectedProfileChanged) { [weak self] in
            self?.loadProfiles()
        })
        ipcObservers.append(AppIPC.observe(.stateChanged) { [weak self] in
            self?.syncSharedState()
        })

        guard role == .menuBarHost else { return }

        ipcObservers.append(AppIPC.observe(.toggleProxyRequested) { [weak self] in
            self?.toggleProxy()
        })
    }

    private func publishSharedStateIfNeeded() {
        guard role == .menuBarHost, !isSyncingState else { return }
        defaults.set(isRunning, forKey: "isRunning")
        defaults.set(activeProfileId?.uuidString, forKey: "activeProfileId")
        defaults.set(statusMessage, forKey: "statusMessage")
        AppIPC.post(.stateChanged)
    }

    private func syncSharedState() {
        guard role == .mainWindow else { return }
        isSyncingState = true
        isRunning = defaults.bool(forKey: "isRunning")
        if let active = defaults.string(forKey: "activeProfileId") {
            activeProfileId = UUID(uuidString: active)
        } else {
            activeProfileId = nil
        }
        statusMessage = defaults.string(forKey: "statusMessage") ?? "Not Connected"
        isSyncingState = false
    }

    private func reconcileRuntimeState() {
        guard role == .menuBarHost else { return }
        guard isRunning || defaults.bool(forKey: "isRunning") else { return }
        guard !processManager.isRunning else { return }

        singboxManager.stop()
        singboxConfigManager.deleteSingboxConfig()
        configManager.deleteActiveConfig()

        isRunning = false
        activeProfileId = nil
        statusMessage = "Disconnected"

        if globalSettings.autoSystemProxy {
            SystemProxyManager.disableAllProxies()
        }
    }
}
