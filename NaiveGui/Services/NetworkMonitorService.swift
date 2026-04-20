import Foundation
import AppKit

final class NetworkMonitorService: ObservableObject {
    static let shared = NetworkMonitorService()

    @Published var connectionCount: Int = 0
    @Published var downloadSpeed: Int64 = 0
    @Published var uploadSpeed: Int64 = 0

    private var timer: Timer?
    private var lastRxBytes: Int64 = 0
    private var lastTxBytes: Int64 = 0
    private var monitorPort: Int = 0
    private var naivePid: Int32 = 0
    private var isWindowVisible = true

    private init() {}

    func startMonitoring(port: Int, pid: Int32 = 0) {
        stopMonitoring()
        monitorPort = port
        naivePid = pid
        lastRxBytes = 0
        lastTxBytes = 0
        isWindowVisible = true
        refreshTimer()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        DispatchQueue.main.async { [weak self] in
            self?.connectionCount = 0
            self?.downloadSpeed = 0
            self?.uploadSpeed = 0
            self?.lastRxBytes = 0
            self?.lastTxBytes = 0
        }
    }

    func updateWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        if visible {
            // Reset baseline on re-show so first delta isn't stale
            lastRxBytes = 0
            lastTxBytes = 0
            refreshTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    private func refreshTimer() {
        timer?.invalidate()
        timer = nil

        let interval: TimeInterval = NSApplication.shared.isActive ? 0.5 : 1.0

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                self.sample()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.sample()
        }
    }

    private func sample() {
        let port = monitorPort
        let count = countConnections(port: port)
        let (rx, tx) = getProcessBytes()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectionCount = count
            if self.lastRxBytes > 0 {
                let dt: Double = NSApplication.shared.isActive ? 0.5 : 1.0
                self.downloadSpeed = max(0, Int64(Double(rx - self.lastRxBytes) / dt))
                self.uploadSpeed = max(0, Int64(Double(tx - self.lastTxBytes) / dt))
            }
            self.lastRxBytes = rx
            self.lastTxBytes = tx
        }
    }

    // Count ESTABLISHED connections on the specific port
    private func countConnections(port: Int) -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", ":\(port)", "-n", "-P"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // Count lines containing ESTABLISHED (excluding header)
        let lines = output.components(separatedBy: "\n")
        var count = 0
        for line in lines {
            if line.contains("(ESTABLISHED)") {
                count += 1
            }
        }
        return count
    }

    // Get bytes for the naive process via nettop
    private func getProcessBytes() -> (rx: Int64, tx: Int64) {
        guard naivePid > 0 else { return (0, 0) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        task.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out", "-p", "\(naivePid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return parseNettopOutput(output)
        } catch {
            return (0, 0)
        }
    }

    private func parseNettopOutput(_ output: String) -> (rx: Int64, tx: Int64) {
        // nettop -P -L 1 output format:
        // ,bytes_in,bytes_out,
        // process_name.pid,bytes_in,bytes_out,
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var totalRx: Int64 = 0
        var totalTx: Int64 = 0

        for line in lines.dropFirst() {
            let cols = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if cols.count >= 3 {
                totalRx += Int64(cols[1]) ?? 0
                totalTx += Int64(cols[2]) ?? 0
            }
        }
        return (totalRx, totalTx)
    }
}
