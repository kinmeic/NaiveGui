import Darwin
import Foundation

/// 单线程、非阻塞的双向 TCP relay。
///
/// 每个方向维护独立的待写缓冲：
/// - 源 fd 可读且缓冲未到高水位时监听 `POLLIN`；
/// - 缓冲非空时在目标 fd 上监听 `POLLOUT`；
/// - 缓冲达到高水位后暂停读取，降到低水位后自动恢复；
/// - 单方向 EOF 后先排空该方向缓冲，再对目标执行 `SHUT_WR`；
/// - 两个方向都完成后才结束整条 relay。
///
/// RelayHub 拥有注册后的 fd 生命周期，但不负责 close；完成回调负责最终 close。
///
/// 并发不变量：
/// - `relays/endpoints/cancelled/threadStarted/nextKey` 的所有访问均持有 `lock`；
/// - Relay 的缓冲与 EOF 状态只由唯一的 hub 线程修改，其他线程只能注册或请求取消；
/// - 回调在释放 `lock` 后执行，避免回调重入造成死锁。
/// `@unchecked Sendable` 仅用于向 Swift 5 描述上述锁/单写线程同步，不能绕开这些约束。
final class RelayHub: @unchecked Sendable {
    static let shared = RelayHub()

    typealias Callback = @Sendable () -> Void

    private enum Side: Sendable {
        case a
        case b
    }

    private struct PendingBuffer {
        private(set) var data = Data()
        private(set) var offset = 0

        var count: Int { data.count - offset }
        var isEmpty: Bool { count == 0 }

        mutating func append(_ bytes: UnsafeRawBufferPointer) {
            guard bytes.count > 0 else { return }
            if offset > 0, offset >= 64 * 1024 {
                data.removeSubrange(0..<offset)
                offset = 0
            }
            data.append(bytes.bindMemory(to: UInt8.self))
        }

        mutating func consume(_ count: Int) {
            offset += count
            if offset == data.count {
                data.removeAll(keepingCapacity: true)
                offset = 0
            } else if offset >= 64 * 1024, offset * 2 >= data.count {
                data.removeSubrange(0..<offset)
                offset = 0
            }
        }

        func withReadableBytes<T>(_ body: (UnsafeRawBufferPointer) -> T) -> T {
            data.withUnsafeBytes { raw in
                let start = raw.baseAddress?.advanced(by: offset)
                return body(UnsafeRawBufferPointer(start: start, count: count))
            }
        }
    }

    private struct Direction {
        let source: Int32
        let destination: Int32
        let byteDirection: RelayByteTracker.Direction
        var pending = PendingBuffer()
        var sourceEOF = false
        var destinationShutdown = false
        var readPaused = false
    }

    private struct Relay {
        let key: UInt64
        let a: Int32
        let b: Int32
        let byteTracker: RelayByteTracker?
        let onTick: Callback?
        let completion: Callback
        var aToB: Direction
        var bToA: Direction
        var lastActivity: Date
        var lastTick: Date
    }

    private struct Endpoint {
        let relayKey: UInt64
        let side: Side
    }

    private let lock = NSLock()
    private var relays: [UInt64: Relay] = [:]
    private var endpoints: [Int32: Endpoint] = [:]
    private var cancelled = Set<UInt64>()
    private var nextKey: UInt64 = 1

    private let wakePipeRead: Int32
    private let wakePipeWrite: Int32
    private var threadStarted = false

    private let idleTimeoutSec: TimeInterval = 300
    private let highWaterMark = 512 * 1024
    private let lowWaterMark = 128 * 1024
    private let ioChunkSize = 64 * 1024

    private init() {
        var pipeFDs: [Int32] = [-1, -1]
        if pipe(&pipeFDs) == 0 {
            wakePipeRead = pipeFDs[0]
            wakePipeWrite = pipeFDs[1]
            Self.setNonBlocking(wakePipeRead)
            Self.setNonBlocking(wakePipeWrite)
            _ = fcntl(wakePipeRead, F_SETFD, FD_CLOEXEC)
            _ = fcntl(wakePipeWrite, F_SETFD, FD_CLOEXEC)
        } else {
            wakePipeRead = -1
            wakePipeWrite = -1
        }
    }

    /// 注册 relay 后立即返回。完成回调在 RelayHub 线程上调用且只调用一次。
    func relay(
        _ a: Int32,
        _ b: Int32,
        byteTracker: RelayByteTracker?,
        onTick: Callback? = nil,
        completion: @escaping Callback
    ) {
        guard Self.makeNonBlocking(a), Self.makeNonBlocking(b) else {
            shutdown(a, SHUT_RDWR)
            shutdown(b, SHUT_RDWR)
            completion()
            return
        }

        let relay: Relay
        lock.lock()
        let key = nextKey
        nextKey &+= 1
        relay = Relay(
            key: key,
            a: a,
            b: b,
            byteTracker: byteTracker,
            onTick: onTick,
            completion: completion,
            aToB: Direction(source: a, destination: b, byteDirection: .sent),
            bToA: Direction(source: b, destination: a, byteDirection: .received),
            lastActivity: Date(),
            lastTick: Date()
        )
        relays[key] = relay
        endpoints[a] = Endpoint(relayKey: key, side: .a)
        endpoints[b] = Endpoint(relayKey: key, side: .b)
        lock.unlock()

        ensureThreadStarted()
        wake()
    }

    /// 请求结束指定 fd 所属的 relay。实际移除和回调统一在 RelayHub 线程执行。
    @discardableResult
    func shutdownRelay(containing fd: Int32) -> Bool {
        lock.lock()
        let key = endpoints[fd]?.relayKey
        if let key {
            cancelled.insert(key)
        }
        lock.unlock()
        guard key != nil else { return false }
        wake()
        return true
    }

    private func ensureThreadStarted() {
        lock.lock()
        defer { lock.unlock() }
        guard !threadStarted else { return }
        threadStarted = true
        let thread = Thread { [weak self] in
            self?.runLoop()
        }
        thread.name = "relay-hub"
        thread.start()
    }

    private func runLoop() {
        var readBuffer = [UInt8](repeating: 0, count: ioChunkSize)

        while true {
            let (pollFDs, snapshot) = makePollSnapshot()
            var mutablePollFDs = pollFDs
            let ready = mutablePollFDs.withUnsafeMutableBufferPointer { ptr -> Int32 in
                poll(ptr.baseAddress, nfds_t(ptr.count), 1_000)
            }

            if ready < 0 {
                if errno == EINTR { continue }
                _ = poll(nil, 0, 10)
                continue
            }

            if wakePipeRead >= 0,
               let wakeFD = mutablePollFDs.first,
               wakeFD.fd == wakePipeRead,
               (wakeFD.revents & Int16(POLLIN)) != 0 {
                drainWakePipe()
            }

            var completed = takeCancelledKeys()

            for pollFD in mutablePollFDs where pollFD.fd != wakePipeRead && pollFD.revents != 0 {
                guard let endpoint = snapshot[pollFD.fd], !completed.contains(endpoint.relayKey) else {
                    continue
                }
                guard var relay = relay(for: endpoint.relayKey) else { continue }

                var fatalError = false
                var tick = false
                var tickCallback: Callback?
                let invalidBits = Int16(POLLERR) | Int16(POLLNVAL)
                if (pollFD.revents & invalidBits) != 0 {
                    fatalError = true
                } else {
                    let readable = (pollFD.revents & Int16(POLLIN)) != 0
                    let hungUp = (pollFD.revents & Int16(POLLHUP)) != 0
                    let writable = (pollFD.revents & Int16(POLLOUT)) != 0

                    if readable || hungUp {
                        let result = read(
                            from: endpoint.side,
                            relay: &relay,
                            buffer: &readBuffer
                        )
                        fatalError = result.fatal
                        tick = tick || result.didTransfer
                    }

                    if !fatalError, writable {
                        let result = write(to: endpoint.side, relay: &relay)
                        fatalError = result.fatal
                        tick = tick || result.didTransfer
                    }
                }

                if fatalError {
                    completed.insert(endpoint.relayKey)
                } else {
                    applyHalfCloses(to: &relay)
                    if tick, Date().timeIntervalSince(relay.lastTick) >= 0.5 {
                        relay.lastTick = Date()
                        tickCallback = relay.onTick
                    }
                    if relayIsComplete(relay) {
                        completed.insert(endpoint.relayKey)
                    } else {
                        store(relay)
                    }
                }

                tickCallback?()
            }

            let now = Date()
            for relay in allRelays() where now.timeIntervalSince(relay.lastActivity) > idleTimeoutSec {
                completed.insert(relay.key)
            }

            for key in completed {
                completeRelay(key)
            }
        }
    }

    private func makePollSnapshot() -> ([pollfd], [Int32: Endpoint]) {
        lock.lock()
        defer { lock.unlock() }

        var result: [pollfd] = []
        var snapshot: [Int32: Endpoint] = [:]
        if wakePipeRead >= 0 {
            result.append(pollfd(fd: wakePipeRead, events: Int16(POLLIN), revents: 0))
        }

        for (fd, endpoint) in endpoints {
            guard let relay = relays[endpoint.relayKey] else { continue }
            var events: Int16 = 0
            switch endpoint.side {
            case .a:
                if !relay.aToB.sourceEOF, !relay.aToB.readPaused {
                    events |= Int16(POLLIN)
                }
                if !relay.bToA.pending.isEmpty {
                    events |= Int16(POLLOUT)
                }
            case .b:
                if !relay.bToA.sourceEOF, !relay.bToA.readPaused {
                    events |= Int16(POLLIN)
                }
                if !relay.aToB.pending.isEmpty {
                    events |= Int16(POLLOUT)
                }
            }
            result.append(pollfd(fd: fd, events: events, revents: 0))
            snapshot[fd] = endpoint
        }
        return (result, snapshot)
    }

    private func read(
        from side: Side,
        relay: inout Relay,
        buffer: inout [UInt8]
    ) -> (fatal: Bool, didTransfer: Bool) {
        let fd: Int32
        let capacity: Int
        switch side {
        case .a:
            fd = relay.a
            capacity = max(0, highWaterMark - relay.aToB.pending.count)
        case .b:
            fd = relay.b
            capacity = max(0, highWaterMark - relay.bToA.pending.count)
        }
        guard capacity > 0 else { return (false, false) }

        let requested = min(buffer.count, capacity)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return recv(fd, base, requested, 0)
        }
        if count > 0 {
            buffer.withUnsafeBytes { raw in
                let slice = UnsafeRawBufferPointer(start: raw.baseAddress, count: count)
                switch side {
                case .a:
                    relay.aToB.pending.append(slice)
                    relay.aToB.readPaused = relay.aToB.pending.count >= highWaterMark
                    relay.byteTracker?.add(bytes: Int64(count), direction: .sent)
                case .b:
                    relay.bToA.pending.append(slice)
                    relay.bToA.readPaused = relay.bToA.pending.count >= highWaterMark
                    relay.byteTracker?.add(bytes: Int64(count), direction: .received)
                }
            }
            relay.lastActivity = Date()
            return (false, true)
        }
        if count == 0 {
            switch side {
            case .a: relay.aToB.sourceEOF = true
            case .b: relay.bToA.sourceEOF = true
            }
            return (false, false)
        }
        if errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR {
            return (false, false)
        }
        return (true, false)
    }

    private func write(to side: Side, relay: inout Relay) -> (fatal: Bool, didTransfer: Bool) {
        let fd: Int32
        switch side {
        case .a: fd = relay.a
        case .b: fd = relay.b
        }

        var written = 0
        let attempted: Bool
        switch side {
        case .a:
            attempted = !relay.bToA.pending.isEmpty
            if attempted {
                written = relay.bToA.pending.withReadableBytes {
                    send(fd, $0.baseAddress, $0.count, 0)
                }
            }
        case .b:
            attempted = !relay.aToB.pending.isEmpty
            if attempted {
                written = relay.aToB.pending.withReadableBytes {
                    send(fd, $0.baseAddress, $0.count, 0)
                }
            }
        }
        guard attempted else { return (false, false) }

        if written > 0 {
            switch side {
            case .a:
                relay.bToA.pending.consume(written)
                if relay.bToA.pending.count <= lowWaterMark {
                    relay.bToA.readPaused = false
                }
            case .b:
                relay.aToB.pending.consume(written)
                if relay.aToB.pending.count <= lowWaterMark {
                    relay.aToB.readPaused = false
                }
            }
            relay.lastActivity = Date()
            return (false, true)
        }
        if written < 0, errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR {
            return (false, false)
        }
        return (true, false)
    }

    private func applyHalfCloses(to relay: inout Relay) {
        if relay.aToB.sourceEOF,
           relay.aToB.pending.isEmpty,
           !relay.aToB.destinationShutdown {
            _ = shutdown(relay.b, SHUT_WR)
            relay.aToB.destinationShutdown = true
        }
        if relay.bToA.sourceEOF,
           relay.bToA.pending.isEmpty,
           !relay.bToA.destinationShutdown {
            _ = shutdown(relay.a, SHUT_WR)
            relay.bToA.destinationShutdown = true
        }
    }

    private func relayIsComplete(_ relay: Relay) -> Bool {
        relay.aToB.sourceEOF &&
            relay.bToA.sourceEOF &&
            relay.aToB.pending.isEmpty &&
            relay.bToA.pending.isEmpty
    }

    private func completeRelay(_ key: UInt64) {
        lock.lock()
        let relay = relays.removeValue(forKey: key)
        if let relay {
            endpoints.removeValue(forKey: relay.a)
            endpoints.removeValue(forKey: relay.b)
        }
        cancelled.remove(key)
        lock.unlock()

        guard let relay else { return }
        _ = shutdown(relay.a, SHUT_RDWR)
        _ = shutdown(relay.b, SHUT_RDWR)
        relay.completion()
    }

    private func relay(for key: UInt64) -> Relay? {
        lock.lock()
        defer { lock.unlock() }
        return relays[key]
    }

    private func store(_ relay: Relay) {
        lock.lock()
        if relays[relay.key] != nil {
            relays[relay.key] = relay
        }
        lock.unlock()
    }

    private func allRelays() -> [Relay] {
        lock.lock()
        defer { lock.unlock() }
        return Array(relays.values)
    }

    private func takeCancelledKeys() -> Set<UInt64> {
        lock.lock()
        defer { lock.unlock() }
        let keys = cancelled
        cancelled.removeAll()
        return keys
    }

    private func drainWakePipe() {
        guard wakePipeRead >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 256)
        while Darwin.read(wakePipeRead, &bytes, bytes.count) > 0 {}
    }

    private func wake() {
        guard wakePipeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = withUnsafePointer(to: &byte) {
            Darwin.write(wakePipeWrite, $0, 1)
        }
    }

    @discardableResult
    private static func makeNonBlocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private static func setNonBlocking(_ fd: Int32) {
        _ = makeNonBlocking(fd)
    }
}
