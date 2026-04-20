import Foundation

final class LogCaptureService: ObservableObject {
    static let shared = LogCaptureService()

    @Published var lines: [LogLine] = []
    private let maxLines = 2000

    private init() {}

    enum LogLevel {
        case error, warning, info
    }

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let isStderr: Bool
        let timestamp: Date

        var level: LogCaptureService.LogLevel {
            let lower = text.lowercased()
            if lower.contains("error") || lower.contains("fatal") { return .error }
            if lower.contains("warn") { return .warning }
            return .info
        }
    }

    func append(_ text: String, isStderr: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let line = LogLine(text: text, isStderr: isStderr, timestamp: Date())
            self.lines.append(line)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.lines.removeAll()
        }
    }
}
