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

/// A concrete callback holder for the app's high-frequency log path.
///
/// Keep callbacks behind `install`/`invoke` instead of exposing them through a
/// generic `inout` container. This keeps a stable, concrete call boundary and
/// avoids the repeating Swift reabstraction-thunk path visible in the crashes.
final class LogLineCallback: @unchecked Sendable {
    typealias Handler = @Sendable (String, Bool) -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func install(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func invoke(_ line: String, isStderr: Bool) {
        lock.lock()
        let current = handler
        lock.unlock()
        current?(line, isStderr)
    }
}

/// Thread-safe zero-argument callback holder. See `LogLineCallback` for why
/// this deliberately is not implemented with the generic `LockedBox`.
final class EventCallback: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let lock = NSLock()
    private var handler: Handler?

    func install(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func invoke() {
        lock.lock()
        let current = handler
        lock.unlock()
        current?()
    }
}

// UserDefaults documents its instance methods as thread-safe. Foundation has not
// yet annotated the class as Sendable on all deployment SDKs supported here.
extension UserDefaults: @unchecked Sendable {}
