import Darwin
import Foundation

final class NaiveProcessManager {
    static let shared = NaiveProcessManager()

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stdoutPipe: Pipe?

    var isRunning: Bool {
        process?.isRunning == true
    }

    var pid: Int32 {
        process?.processIdentifier ?? 0
    }

    private init() {}

    func start(configURL: URL, binaryPath: String) throws {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw NaiveError.binaryNotFound(binaryPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = [configURL.path]

        let errPipe = Pipe()
        let outPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = outPipe

        self.stderrPipe = errPipe
        self.stdoutPipe = outPipe

        startReading(pipe: errPipe, isStderr: true)
        startReading(pipe: outPipe, isStderr: false)

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.processDidTerminate()
            }
        }

        do {
            try p.run()
            self.process = p
        } catch {
            self.stderrPipe = nil
            self.stdoutPipe = nil
            throw error
        }
    }

    func waitForSOCKSReady(host: String, port: Int, timeout: TimeInterval = 8) throws {
        let deadline = Date().addingTimeInterval(timeout)
        let probeHost = Self.probeHost(for: host)
        var lastError: Error?

        while Date() < deadline {
            guard isRunning else { throw NaiveError.exitedDuringStartup }

            do {
                try Self.probeSOCKS(host: probeHost, port: port)
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        throw NaiveError.startupTimedOut("\(probeHost):\(port)", lastError?.localizedDescription)
    }

    func stop() {
        guard let p = process, p.isRunning else {
            processDidTerminate()
            return
        }
        p.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            if let p = self?.process, p.isRunning {
                kill(pid_t(p.processIdentifier), SIGKILL)
            }
        }
    }

    var onLogLine: ((String, Bool) -> Void)?
    var onUnexpectedExit: (() -> Void)?

    private func startReading(pipe: Pipe, isStderr: Bool) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            for line in lines {
                self?.onLogLine?(line, isStderr)
            }
        }
    }

    private func processDidTerminate() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stderrPipe = nil
        stdoutPipe = nil
        onUnexpectedExit?()
    }

    private static func probeHost(for listenHost: String) -> String {
        switch listenHost.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "", "0.0.0.0", "::", "[::]":
            return "127.0.0.1"
        default:
            return listenHost
        }
    }

    private static func probeSOCKS(host: String, port: Int) throws {
        let fd = try connect(host: host, port: port)
        defer { close(fd) }

        try writeAll(fd, bytes: [0x05, 0x01, 0x00])
        let response = try readExact(fd, count: 2)
        guard response == [0x05, 0x00] else {
            throw ReadinessProbeError.invalidResponse
        }
    }

    private static func connect(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "\(port)", &hints, &result)
        guard status == 0, let first = result else { throw ReadinessProbeError.invalidAddress(host) }
        defer { freeaddrinfo(first) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let info = ptr {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                var noSigPipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                    return fd
                }
                close(fd)
            }
            ptr = info.pointee.ai_next
        }

        throw ReadinessProbeError.connectFailed(host, port)
    }

    private static func writeAll(_ fd: Int32, bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = send(fd, base.advanced(by: offset), bytes.count - offset, 0)
                if written <= 0 { throw ReadinessProbeError.writeFailed }
                offset += written
            }
        }
    }

    private static func readExact(_ fd: Int32, count: Int) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return recv(fd, base.advanced(by: offset), count - offset, 0)
            }
            if readCount <= 0 { throw ReadinessProbeError.shortRead }
            offset += readCount
        }
        return data
    }
}

enum NaiveError: LocalizedError {
    case binaryNotFound(String)
    case alreadyRunning
    case exitedDuringStartup
    case startupTimedOut(String, String?)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "Naive binary not found at: \(path)"
        case .alreadyRunning:
            return "Naive is already running"
        case .exitedDuringStartup:
            return "Naive exited before its local SOCKS listener was ready"
        case .startupTimedOut(let address, let lastError):
            if let lastError {
                return "Timed out waiting for Naive SOCKS listener at \(address): \(lastError)"
            }
            return "Timed out waiting for Naive SOCKS listener at \(address)"
        }
    }
}

private enum ReadinessProbeError: LocalizedError {
    case invalidAddress(String)
    case connectFailed(String, Int)
    case shortRead
    case invalidResponse
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidAddress(let host): return "invalid address: \(host)"
        case .connectFailed(let host, let port): return "connect failed: \(host):\(port)"
        case .shortRead: return "connection closed while probing SOCKS readiness"
        case .invalidResponse: return "local listener did not answer as SOCKS5"
        case .writeFailed: return "socket write failed while probing SOCKS readiness"
        }
    }
}
