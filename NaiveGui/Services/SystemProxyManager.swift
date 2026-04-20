import Foundation

// System proxy management via networksetup
// Will be fully utilized when PAC/routing is implemented
enum SystemProxyManager {
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
            } else {
                try runShell("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
            }
        }
    }

    static func disableAllProxies() {
        guard let services = try? getNetworkServices() else { return }
        for service in services {
            try? runShell("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
            try? runShell("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
            try? runShell("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
            try? runShell("/usr/sbin/networksetup", ["-setautoproxystate", service, "off"])
        }
    }

    private static func getNetworkServices() throws -> [String] {
        let output = try runShell("/usr/sbin/networksetup", ["-listallnetworkservices"])
        var lines = output.components(separatedBy: "\n")
        lines.removeFirst() // header line
        return lines.filter { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    @discardableResult
    private static func runShell(_ command: String, _ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
