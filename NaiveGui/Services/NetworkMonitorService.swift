import Foundation

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

    private init() {}

    func startMonitoring(port: Int, pid: Int32 = 0) {
        stopMonitoring()
        monitorPort = port
        naivePid = pid

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                self.sample()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.sample()
        }
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

    private func sample() {
        let port = monitorPort
        let count = countConnections(port: port)
        let (rx, tx) = getProcessBytes()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectionCount = count
            if self.lastRxBytes > 0 {
                self.downloadSpeed = max(0, (rx - self.lastRxBytes) / 2)
                self.uploadSpeed = max(0, (tx - self.lastTxBytes) / 2)
            }
            self.lastRxBytes = rx
            self.lastTxBytes = tx
        }
    }

    // Count ESTABLISHED connections on the specific port
    private func countConnections(port: Int) -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", ":\(port)", "-n", "-P", "-sTCP:ESTABLISHED"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        // Subtract 1 for header line
        let lines = output.components(separatedBy: "\n").filter { $0.contains("ESTABLISHED") }
        return lines.count
    }

    // Get bytes for the naive process via /proc/pid or nettop
    private func getProcessBytes() -> (rx: Int64, tx: Int64) {
        guard naivePid > 0 else { return (0, 0) }

        // Use nettop to get bytes for specific PID
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
        // header line
        // process_name,pid,bytes_in,bytes_out
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
