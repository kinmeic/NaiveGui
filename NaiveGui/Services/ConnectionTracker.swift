import Foundation

/// 活跃连接表。线程安全地记录每条代理连接的状态和字节统计。
/// 阶段4：只做后台采集与状态查询，UI 在后续工作接入。
///
/// 关键约束：`@Published var records` 必须只在主线程修改（Combine 的 objectWillChange
/// 同步发送，跨线程会触发 data race，Debug 下运行时 trap）。
/// 因此整个类型隔离到 MainActor；后台线程通过 MainActor Task 提交更新。
@MainActor
final class ConnectionTracker: ObservableObject {
    static let shared = ConnectionTracker()

    /// 当前活跃 + 最近结束的连接。已结束的记录保留 retentionSec 秒后自动移除，
    /// 既能让用户看到"刚结束的连接"结果，又不会永久堆积。
    @Published private(set) var records: [ConnectionRecord] = []

    /// 全局累计上下行字节（自本次代理启动以来）。供状态栏/连接表头部展示。
    @Published private(set) var totalBytesSent: Int64 = 0
    @Published private(set) var totalBytesReceived: Int64 = 0

    private let maxRecords = 500
    /// 已结束记录的保留时长（秒）。超过后由清扫定时器移除。
    private let retentionSec: TimeInterval = 30
    /// 后台清扫定时器。每 10 秒扫一次，移除过期的 closed 记录。
    private var cleanupTimer: DispatchSourceTimer?

    private init() {}

    /// 连接开始时记录。
    func recordStart(id: Int, host: String, port: Int, action: RuleAction, reason: String) {
        let record = ConnectionRecord(id: id, host: host, port: port, action: action, reason: reason)
        if let idx = records.firstIndex(where: { $0.id == id }) {
            records[idx] = record
        } else {
            records.insert(record, at: 0)
        }
        trim()
    }

    /// 周期性更新字节计数，并累加全局统计。
    func updateBytes(id: Int, sent: Int64, received: Int64) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let previous = records[idx]
        totalBytesSent &+= max(0, sent - previous.bytesSent)
        totalBytesReceived &+= max(0, received - previous.bytesReceived)
        records[idx].bytesSent = sent
        records[idx].bytesReceived = received
    }

    /// 连接结束时标记。
    func recordEnd(id: Int) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].markEnded()
        trim()
        startCleanupTimerIfNeeded()
    }

    /// 清空所有记录（断开代理时调用）。
    func reset() {
        stopCleanupTimer()
        records.removeAll()
        totalBytesSent = 0
        totalBytesReceived = 0
    }

    // MARK: - 已结束记录的自动清理

    /// 手动清空所有已结束的记录（UI 的 "Clear closed" 按钮调用）。
    func removeClosed() {
        records.removeAll { !$0.isActive }
        stopCleanupTimer()
    }

    /// 启动后台清扫定时器（若未运行）。每 10 秒移除 endedAt 超过 retentionSec 的记录。
    private func startCleanupTimerIfNeeded() {
        guard cleanupTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.purgeExpired()
        }
        timer.resume()
        cleanupTimer = timer
    }

    private func stopCleanupTimer() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
    }

    /// 移除已结束且超过保留期的记录。若无 closed 记录则停掉定时器（省电）。
    private func purgeExpired() {
        let cutoff = Date().addingTimeInterval(-retentionSec)
        let before = records.count
        records.removeAll { record in
            if let ended = record.endedAt, ended < cutoff {
                return true
            }
            return false
        }
        // 没有已结束的记录了，停掉定时器，下次有连接结束再启动。
        if !records.contains(where: { !$0.isActive }) {
            stopCleanupTimer()
        }
        _ = before // 保留变量供调试观察
    }

    private func trim() {
        // 主线程内调用，无需加锁。
        guard records.count > maxRecords else { return }
        let excess = records.count - maxRecords
        if excess > 0 {
            var removed = 0
            records.removeAll { record in
                guard removed < excess, !record.isActive else { return false }
                removed += 1
                return true
            }
        }
    }
}
