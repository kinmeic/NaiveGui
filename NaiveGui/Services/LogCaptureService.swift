import Foundation

final class LogCaptureService: ObservableObject, @unchecked Sendable {
    static let shared = LogCaptureService()

    @Published var lines: [LogLine] = []
    private let maxLines = 2000

    /// 日志限流参数。高频流量下每连接 2-3 行日志会爆炸，对相似日志做窗口聚合。
    /// 策略：对归一化后的 key，在 window 秒内超过 maxPerWindow 条时，多余的不立即写入，
    /// 累计计数；窗口结束后若累计 > 0，写入一条 "... and N more" 摘要。
    private let window: TimeInterval = 1.0
    private let maxPerWindow = 30
    private var suppressed: [String: Int] = [:]
    private var windowStart: Date = Date()
    private let rateLock = NSLock()
    /// 周期性 flush 定时器。确保最后一个窗口（之后无新日志时）的抑制摘要也能输出。
    private var flushTimer: DispatchSourceTimer?

    private init() {
        startFlushTimer()
    }

    /// 每 window 秒检查一次，把已结束窗口的抑制摘要 flush 出来。
    /// 修复"最后一个窗口没有后续日志时摘要不输出"的问题。
    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + window, repeating: window)
        timer.setEventHandler { [weak self] in
            self?.rateLock.lock()
            self?.flushSuppressedLocked()
            self?.windowStart = Date()
            self?.rateLock.unlock()
        }
        timer.resume()
        flushTimer = timer
    }

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
        let key = rateLimitKey(for: text)
        let suppressedNow = shouldSuppress(key: key)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if suppressedNow {
                // 不写入，等窗口结束统一摘要。
                return
            }
            self.appendLine(text, isStderr: isStderr)
        }
    }

    private func appendLine(_ text: String, isStderr: Bool) {
        let line = LogLine(text: text, isStderr: isStderr, timestamp: Date())
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    /// 把日志归一化为限流 key。同动作的连接日志归为同一桶。
    /// 用 contains 而非 hasPrefix，因为实际日志带 "[router]"/"[naive]" 前缀。
    private func rateLimitKey(for text: String) -> String {
        if text.contains("accepted") {
            if text.contains("SOCKS") { return "socks:accepted" }
            if text.contains("HTTP") { return "http:accepted" }
        }
        if text.contains("-> DIRECT") { return "action:direct" }
        if text.contains("-> PROXY") { return "action:proxy" }
        if text.contains("-> BLOCK") { return "action:block" }
        // 错误、规则集状态等不限流，每条独立 key。
        return text
    }

    private func shouldSuppress(key: String) -> Bool {
        rateLock.lock()
        defer { rateLock.unlock() }
        let now = Date()
        if now.timeIntervalSince(windowStart) >= window {
            // 窗口滚动：先把上一窗口的聚合摘要 flush。
            flushSuppressedLocked()
            windowStart = now
        }
        let count = suppressed[key, default: 0] + 1
        if count > maxPerWindow {
            suppressed[key] = count
            return true
        }
        suppressed[key] = count
        return false
    }

    /// 把累计的抑制计数写成一两条摘要日志。调用方持锁；内部 dispatch 到主线程写日志。
    private func flushSuppressedLocked() {
        guard !suppressed.isEmpty else { return }
        var total = 0
        for (_, n) in suppressed { total += max(0, n - maxPerWindow) }
        suppressed.removeAll()
        if total > 0 {
            let summaryTotal = total
            DispatchQueue.main.async { [weak self] in
                self?.appendLine("… \(summaryTotal) similar log entries suppressed (rate limit)", isStderr: false)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.lines.removeAll()
        }
        rateLock.lock()
        suppressed.removeAll()
        windowStart = Date()
        rateLock.unlock()
    }
}
