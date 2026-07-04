import Foundation

/// 活跃连接数硬上限限流器。线程安全。
///
/// 当活跃连接数达到 maxConnections 时，acquire() 返回 false，调用方应直接拒绝新连接。
/// 防止 BT 下载、爬虫、端口扫描等异常高并发耗尽 fd 与 RelayHub 缓冲内存。
///
/// 设计：用 NSLock 保护计数（acquire/release 在每条连接的热路径上，开销要低）。
/// 默认上限 1000——对正常浏览/办公绰绰有余，异常场景下拒绝保护。
final class ConnectionLimiter: @unchecked Sendable {
    private let maxConnections: Int
    private var active: Int = 0
    private let lock = NSLock()

    init(maxConnections: Int = 1000) {
        self.maxConnections = maxConnections
    }

    /// 尝试获取一个连接槽。成功返回 true（调用方处理完后必须 release）；
    /// 已达上限返回 false（调用方应拒绝连接）。
    func acquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if active >= maxConnections {
            return false
        }
        active += 1
        return true
    }

    /// 释放一个连接槽。必须与 acquire 成对调用。
    func release() {
        lock.lock()
        if active > 0 {
            active -= 1
        }
        lock.unlock()
    }

    /// 当前活跃连接数（供 UI 展示）。
    var currentActive: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    var limit: Int { maxConnections }
}
