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
