import Foundation

final class SingboxProcessManager {
    static let shared = SingboxProcessManager()

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

    var onLogLine: ((String, Bool) -> Void)?
    var onUnexpectedExit: (() -> Void)?

    func start(configURL: URL, binaryPath: String) throws {
        guard !isRunning else { return }
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw SingboxError.binaryNotFound(binaryPath)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.arguments = ["run", "-c", configURL.path]

        let errPipe = Pipe()
        let outPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = outPipe

        self.stderrPipe = errPipe
        self.stdoutPipe = outPipe

        startReading(pipe: errPipe, isStderr: true)
        startReading(pipe: outPipe, isStderr: false)

        p.terminationHandler = { [weak self] _ in
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
}

enum SingboxError: LocalizedError {
    case binaryNotFound(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "sing-box binary not found at: \(path)"
        }
    }
}
