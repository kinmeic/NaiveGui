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

    private init() {}

    func startMonitoring(port: Int) {
        stopMonitoring()
        monitorPort = port

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                self.sample()
            }
        }
        // First sample on background thread
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
        }
    }

    private func sample() {
        let port = monitorPort
        let count = countConnections(port: port)
        let rx = getCurrentBytes(index: 6)
        let tx = getCurrentBytes(index: 9)

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
        return output.components(separatedBy: "\n").filter { $0.contains("ESTABLISHED") }.count
    }

    private func getCurrentBytes(index: Int) -> Int64 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/netstat")
        task.arguments = ["-I", "lo0", "-b"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.components(separatedBy: "\n")
        if lines.count > 1 {
            let cols = lines[1].components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if cols.count > index, let val = Int64(cols[index]) {
                return val
            }
        }
        return 0
    }
}
