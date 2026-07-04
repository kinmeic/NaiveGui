import Foundation

/// 最小的锁保护状态容器。所有可变值只能通过 `withLock` 访问。
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

// UserDefaults documents its instance methods as thread-safe. Foundation has not
// yet annotated the class as Sendable on all deployment SDKs supported here.
extension UserDefaults: @retroactive @unchecked Sendable {}
