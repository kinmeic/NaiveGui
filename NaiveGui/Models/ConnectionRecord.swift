import Foundation

/// 一条活跃或已结束的代理连接记录。供连接表 UI 使用。
/// 阶段4 只做数据结构与后台采集，UI 在后续工作接入。
struct ConnectionRecord: Identifiable, Equatable {
    /// 用客户端 socket fd 作 id —— 一条连接生命周期内 fd 不变，且天然唯一。
    /// 用 Int 而非 UUID，避免每个连接额外分配。
    let id: Int
    let host: String
    let port: Int
    let action: RuleAction
    let reason: String
    let startedAt: Date

    /// 由 pump 线程累加；读时取快照。
    var bytesSent: Int64 = 0
    var bytesReceived: Int64 = 0
    var endedAt: Date?

    var isActive: Bool { endedAt == nil }

    init(id: Int, host: String, port: Int, action: RuleAction, reason: String, startedAt: Date = Date()) {
        self.id = id
        self.host = host
        self.port = port
        self.action = action
        self.reason = reason
        self.startedAt = startedAt
    }

    mutating func addBytes(sent: Int64 = 0, received: Int64 = 0) {
        bytesSent &+= sent
        bytesReceived &+= received
    }

    mutating func markEnded(at date: Date = Date()) {
        endedAt = date
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}
