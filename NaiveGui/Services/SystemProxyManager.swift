import Foundation

enum SystemProxyError: LocalizedError {
    case commandFailed(command: String, args: [String], exitCode: Int, stderr: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(_, let args, let exitCode, let stderr):
            let detail = stderr.isEmpty ? "exit code \(exitCode)" : stderr
            return "networksetup \(args.joined(separator: " ")): \(detail)"
        }
    }
}

/// 系统代理的安全保存/恢复快照。保存启用 NaiveGui 代理前用户原有的代理配置，
/// 断开时恢复，避免破坏用户原有网络设置。
struct SystemProxySnapshot: Codable, Equatable {
    struct ServiceState: Codable, Equatable {
        var socksEnabled: Bool
        var socksHost: String
        var socksPort: String
        var webEnabled: Bool
        var webHost: String
        var webPort: String
        var secureWebEnabled: Bool
        var secureWebHost: String
        var secureWebPort: String
        var autoProxyEnabled: Bool
        var autoProxyURL: String
        var bypassDomains: [String]
    }

    var services: [String: ServiceState]
}

enum SystemProxyManager {
    /// 持久化标志：标记 NaiveGui 当前是否占用了系统代理。
    /// 用于崩溃恢复——重启后若发现此标志为 true，说明上次没正常清理，需恢复。
    private static let activeFlagKey = "naiveGuiSystemProxyActive"
    private static let snapshotKey = "naiveGuiSystemProxySnapshot"
    private static let defaults = AppEnvironment.sharedDefaults

    /// 启用 NaiveGui 代理前，先保存当前系统代理状态到快照 + 持久化标志。
    /// 若检测到上次崩溃残留（flag 为 true），先恢复再重新捕获，避免覆盖原始快照。
    /// 残留恢复失败时抛错并保留旧快照——不进行重新捕获，避免覆盖原始状态后无法重试。
    static func captureAndPrepare() throws -> SystemProxySnapshot {
        // 若上次残留（崩溃未清理），先按已保存的原始快照恢复，再重新捕获。
        if defaults.bool(forKey: activeFlagKey), let persisted = loadPersistedSnapshot() {
            var restoreOK = true
            for (service, state) in persisted.services {
                restoreOK = restoreServiceState(service, state: state) && restoreOK
            }
            // 恢复失败：保留旧快照，抛错让调用方放弃本次连接。下次启动可再次尝试恢复。
            if !restoreOK {
                throw SystemProxyError.commandFailed(
                    command: "/usr/sbin/networksetup",
                    args: ["restoreResidual"],
                    exitCode: -1,
                    stderr: "failed to restore previous proxy state; snapshot preserved for retry"
                )
            }
        }

        let services = try getNetworkServices()
        var snapshot = SystemProxySnapshot(services: [:])
        for service in services {
            snapshot.services[service] = captureServiceState(service)
        }
        // 持久化快照 + 标志，供崩溃恢复用。
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: snapshotKey)
        }
        defaults.set(true, forKey: activeFlagKey)
        return snapshot
    }

    /// 设置 SOCKS 代理（同时设置指定服务）。
    static func setSOCKSProxy(host: String, port: Int, enabled: Bool) throws {
        let services = try getNetworkServices()
        for service in services {
            if enabled {
                try runShell("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, host, "\(port)"])
                try runShell("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "on"])
            } else {
                try runShell("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
            }
        }
    }

    static func setHTTPProxy(host: String, port: Int, enabled: Bool) throws {
        let services = try getNetworkServices()
        for service in services {
            if enabled {
                try runShell("/usr/sbin/networksetup", ["-setwebproxy", service, host, "\(port)"])
                try runShell("/usr/sbin/networksetup", ["-setwebproxystate", service, "on"])
                try runShell("/usr/sbin/networksetup", ["-setsecurewebproxy", service, host, "\(port)"])
                try runShell("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "on"])
            } else {
                try runShell("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
                try runShell("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
            }
        }
    }

    static func setProxyBypassDomains(_ domains: [String]) throws {
        let normalizedDomains = Array(Set(domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !normalizedDomains.isEmpty else { return }

        let services = try getNetworkServices()
        for service in services {
            let mergedDomains = Array(Set(getProxyBypassDomains(for: service) + normalizedDomains)).sorted()
            try runShell("/usr/sbin/networksetup", ["-setproxybypassdomains", service] + mergedDomains)
        }
    }

    /// 恢复到启用前的快照状态（安全断开）。优先用传入的快照；若 nil 则读持久化的。
    /// 返回是否恢复成功——失败时保留快照，下次启动可重试。
    @discardableResult
    static func restoreProxies(snapshot: SystemProxySnapshot? = nil) -> Bool {
        let active = defaults.bool(forKey: activeFlagKey)
        guard active else { return true } // 不曾占用，无需恢复

        let resolved = snapshot ?? (loadPersistedSnapshot())
        guard let snap = resolved else {
            // 无快照可恢复，回退到关闭所有（兜底）。
            forceDisableAll()
            clearPersistedState()
            return true
        }

        var allOK = true
        for (service, state) in snap.services {
            allOK = restoreServiceState(service, state: state) && allOK
        }
        // 仅在全部成功时清除快照；失败时保留，便于下次启动重试。
        if allOK {
            clearPersistedState()
        }
        return allOK
    }

    /// 兜底：无脑关闭所有代理（仅在无快照可用时）。
    static func forceDisableAll() {
        guard let services = try? getNetworkServices() else { return }
        for service in services {
            _ = try? runShell("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
            _ = try? runShell("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
            _ = try? runShell("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
            _ = try? runShell("/usr/sbin/networksetup", ["-setautoproxystate", service, "off"])
        }
    }

    /// 应用启动时调用：检测上次崩溃残留并恢复。
    static func recoverIfNeeded() {
        let active = defaults.bool(forKey: activeFlagKey)
        guard active else { return }
        // 上次没正常清理（崩溃或强杀），恢复快照。
        restoreProxies()
    }

    // MARK: - 快照读写

    private static func captureServiceState(_ service: String) -> SystemProxySnapshot.ServiceState {
        SystemProxySnapshot.ServiceState(
            socksEnabled: proxyEnabled(service, kind: "socksfirewall"),
            socksHost: getProxyField(service, kind: "socksfirewall", field: "Server") ?? "",
            socksPort: getProxyField(service, kind: "socksfirewall", field: "Port") ?? "",
            webEnabled: proxyEnabled(service, kind: "web"),
            webHost: getProxyField(service, kind: "web", field: "Server") ?? "",
            webPort: getProxyField(service, kind: "web", field: "Port") ?? "",
            secureWebEnabled: proxyEnabled(service, kind: "secureweb"),
            secureWebHost: getProxyField(service, kind: "secureweb", field: "Server") ?? "",
            secureWebPort: getProxyField(service, kind: "secureweb", field: "Port") ?? "",
            autoProxyEnabled: proxyEnabled(service, kind: "autoproxy"),
            autoProxyURL: getProxyField(service, kind: "autoproxy", field: "URL") ?? "",
            bypassDomains: getProxyBypassDomains(for: service)
        )
    }

    /// 恢复单个服务的代理状态。返回是否全部成功——失败时调用方应保留快照以便重试。
    /// 始终写回地址，再恢复 enabled：即使原状态是关闭（有地址但 disabled），
    /// 也要把地址写回，否则 NaiveGui 的地址会残留，用户以后手动开启会用到错误代理。
    @discardableResult
    private static func restoreServiceState(_ service: String, state: SystemProxySnapshot.ServiceState) -> Bool {
        var allOK = true
        // SOCKS：先写地址（若有），再设状态。
        if !state.socksHost.isEmpty {
            allOK = runShellTry("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, state.socksHost, state.socksPort]) && allOK
        }
        allOK = runShellTry("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, state.socksEnabled ? "on" : "off"]) && allOK

        // Web (HTTP)
        if !state.webHost.isEmpty {
            allOK = runShellTry("/usr/sbin/networksetup", ["-setwebproxy", service, state.webHost, state.webPort]) && allOK
        }
        allOK = runShellTry("/usr/sbin/networksetup", ["-setwebproxystate", service, state.webEnabled ? "on" : "off"]) && allOK

        // Secure Web (HTTPS)
        if !state.secureWebHost.isEmpty {
            allOK = runShellTry("/usr/sbin/networksetup", ["-setsecurewebproxy", service, state.secureWebHost, state.secureWebPort]) && allOK
        }
        allOK = runShellTry("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, state.secureWebEnabled ? "on" : "off"]) && allOK

        // Auto proxy (PAC)
        if !state.autoProxyURL.isEmpty {
            allOK = runShellTry("/usr/sbin/networksetup", ["-setautoproxyurl", service, state.autoProxyURL]) && allOK
        }
        allOK = runShellTry("/usr/sbin/networksetup", ["-setautoproxystate", service, state.autoProxyEnabled ? "on" : "off"]) && allOK

        // bypass domains：空也要恢复（传 "Empty" 清空 NaiveGui 添加的绕过项）。
        if state.bypassDomains.isEmpty {
            allOK = runShellTry("/usr/sbin/networksetup", ["-setproxybypassdomains", service, "Empty"]) && allOK
        } else {
            allOK = runShellTry("/usr/sbin/networksetup", ["-setproxybypassdomains", service] + state.bypassDomains) && allOK
        }
        return allOK
    }

    /// runShell 的 try? 版本，返回是否成功（用于恢复时聚合错误）。
    @discardableResult
    private static func runShellTry(_ command: String, _ args: [String]) -> Bool {
        (try? runShell(command, args)) != nil
    }

    private static func loadPersistedSnapshot() -> SystemProxySnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(SystemProxySnapshot.self, from: data)
    }

    private static func clearPersistedState() {
        defaults.set(false, forKey: activeFlagKey)
        defaults.removeObject(forKey: snapshotKey)
    }

    // MARK: - networksetup 查询

    /// 不同代理类型对应的 networksetup 查询命令动词。
    /// 注意 PAC 的查询是 -getautoproxyurl，不是 -getautoproxyproxy。
    private static func queryCommand(for kind: String) -> String {
        switch kind {
        case "autoproxy": return "-getautoproxyurl"
        default: return "-get\(kind)proxy"
        }
    }

    private static func proxyEnabled(_ service: String, kind: String) -> Bool {
        let output = (try? runShell("/usr/sbin/networksetup", [queryCommand(for: kind), service])) ?? ""
        return output.contains("Enabled: Yes")
    }

    private static func getProxyField(_ service: String, kind: String, field: String) -> String? {
        let output = (try? runShell("/usr/sbin/networksetup", [queryCommand(for: kind), service])) ?? ""
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(field):") {
                let value = trimmed.dropFirst("\(field):".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    /// 返回需要设置/恢复代理的网络服务名。
    ///
    /// 只返回承载默认路由的活跃服务（如当前在用的 Wi-Fi 或有线），而非
    /// `listallnetworkservices` 里全部历史服务。机器上常有大量已断开的
    /// 残留服务（USB 网卡、雷电桥接、WireGuard 等），对它们设置代理不生效，
    /// 却仍要逐个 fork/exec networksetup，启动/恢复阶段串行执行数十次子进程，
    /// 造成可观的延迟。只处理默认路由出口服务即覆盖全部出站流量。
    ///
    /// 拿不到默认路由（离线、异常）时回退到全量非禁用服务，保证不漏设。
    private static func getNetworkServices() throws -> [String] {
        if let primary = primaryNetworkServiceForDefaultRoute() {
            return [primary]
        }
        // 兜底：离线或无法确定出口服务时，退回到全量扫描，确保不漏。
        let output = try runShell("/usr/sbin/networksetup", ["-listallnetworkservices"])
        var lines = output.components(separatedBy: "\n")
        lines.removeFirst() // header line
        return lines.filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// 通过默认路由接口名反查所属网络服务名。
    /// `route -n get default` 给出出口接口（如 en0），
    /// `networksetup -listnetworkserviceorder` 给出"服务名→Device"映射，
    /// 二者匹配即得到当前出口的网络服务名。
    /// 任一步骤失败返回 nil，调用方回退到全量扫描。
    private static func primaryNetworkServiceForDefaultRoute() -> String? {
        guard let iface = defaultRouteInterface(), !iface.isEmpty else { return nil }
        guard let output = try? runShell("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else {
            return nil
        }
        // 输出形如：
        // (1) Wi-Fi
        // (Hardware Port: Wi-Fi, Device: en0)
        // 按空行/换行遍历，遇到 Device: 匹配 iface 时，取上一行的服务名。
        var currentService: String?
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("("), line.contains("Device:") {
                // 形如 (Hardware Port: Wi-Fi, Device: en0)
                if line.contains("Device: \(iface)") {
                    if let svc = currentService, !svc.isEmpty {
                        return svc
                    }
                }
                currentService = nil
            } else if !line.isEmpty {
                // 形如 (1) Wi-Fi  ->  取 "Wi-Fi"
                if let parenEnd = line.lastIndex(of: ")") {
                    let after = line.index(after: parenEnd)
                    let name = String(line[after...]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        currentService = name
                    }
                }
            }
        }
        return nil
    }

    /// 读取默认路由的出口接口名（如 "en0"）。失败或无默认路由返回 nil。
    private static func defaultRouteInterface() -> String? {
        guard let output = try? runShell("/sbin/route", ["-n", "get", "default"]) else {
            return nil
        }
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("interface:") {
                let value = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    private static func getProxyBypassDomains(for service: String) -> [String] {
        guard let output = try? runShell("/usr/sbin/networksetup", ["-getproxybypassdomains", service]) else {
            return []
        }

        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("There aren't any bypass domains set") }
    }

    @discardableResult
    private static func runShell(_ command: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if task.terminationStatus != 0 {
            throw SystemProxyError.commandFailed(command: command, args: args, exitCode: Int(task.terminationStatus), stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
