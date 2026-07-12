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

    /// 所有 String 解析 + 限流 + contains 工作都搬到这条独占串行队列。
    /// 生产者（handleSOCKS / readabilityHandler 等）只做 O(1) 入队后立即返回，
    /// 不在调用方线程跑 contains/锁，因此任何重入都无法增长调用方栈（防栈溢出）。
    private let logQueue = DispatchQueue(label: "naivegui.logcapture", qos: .utility)

    /// 待处理条目计数 + 上限。日志洪峰下队列饱和则丢弃，防内存无限增长。
    private let pendingLock = NSLock()
    private var pending = 0
    private let maxPending = 8_192
    /// 饱和诊断只打一次，避免诊断本身成为新的日志洪流。
    private var diagnosticsLogged = false
    private let diagnosticsLock = NSLock()

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

    /// 生产者入口：O(1)、非阻塞、不在调用方线程跑 contains/锁。
    /// 调用方只负责入队，字符串解析和限流均在独占队列执行。
    func append(_ text: String, isStderr: Bool) {
        // 防御：丢弃超长单行。避免 contains/解析在异常输入上消耗过多栈/时间。
        // 正常 naive 单行日志远小于此阈值。
        guard text.utf8.count <= 16_000 else { return }

        // 内存上限：队列饱和时丢弃，避免日志洪峰下 pending 无界增长。
        pendingLock.lock()
        let saturated = pending >= maxPending
        if !saturated { pending += 1 }
        pendingLock.unlock()
        guard !saturated else {
            logOnceDiagnostic("log capture pipeline saturated (pending>=\(maxPending)); dropping lines.")
            return
        }

        let captured = text
        logQueue.async { [weak self] in
            self?.process(captured, isStderr: isStderr)
        }
    }

    /// 仅在 logQueue 上执行。contains / 限流锁都在这里，串行队列保证永不嵌套。
    private func process(_ text: String, isStderr: Bool) {
        defer {
            pendingLock.lock()
            pending -= 1
            pendingLock.unlock()
        }
        let key = rateLimitKey(for: text)
        let suppressedNow = shouldSuppress(key: key)
        guard !suppressedNow else { return }
        // 被限流的不进入主线程，减少跨线程 dispatch 次数与 UI 压力。
        DispatchQueue.main.async { [weak self] in
            self?.appendLine(text, isStderr: isStderr)
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

    /// 一次性诊断：队列饱和时只 NSLog 一条，避免日志洪流放大自身。
    /// NSLog 自身线程安全；这里只保护 diagnosticsLogged 标志的原子性。
    private func logOnceDiagnostic(_ message: String) {
        diagnosticsLock.lock()
        let already = diagnosticsLogged
        if !already { diagnosticsLogged = true }
        diagnosticsLock.unlock()
        if !already {
            NSLog("NaiveGui: %@", message)
        }
    }
}
