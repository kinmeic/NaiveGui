import Darwin
import XCTest
@testable import NaiveGui

final class CallbackStorageTests: XCTestCase {
    func testRepeatedLogHandlerReplacementKeepsOnlyLatestHandler() {
        let callback = LogLineCallback()
        let lock = NSLock()
        var received = -1

        for value in 0..<10_000 {
            callback.install { _, _ in
                lock.lock()
                received = value
                lock.unlock()
            }
        }

        callback.invoke("line", isStderr: false)
        lock.lock()
        let result = received
        lock.unlock()
        XCTAssertEqual(result, 9_999)
    }

    func testConcurrentHandlerReplacementAndInvocationIsSafe() {
        let callback = LogLineCallback()
        let queue = DispatchQueue(label: "callback-storage-test", attributes: .concurrent)
        let group = DispatchGroup()

        for value in 0..<2_000 {
            group.enter()
            queue.async {
                callback.install { _, _ in _ = value }
                group.leave()
            }
            group.enter()
            queue.async {
                callback.invoke("line", isStderr: false)
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    func testEventHandlerCanBeRemoved() {
        let callback = EventCallback()
        let lock = NSLock()
        var count = 0
        callback.install {
            lock.lock()
            count += 1
            lock.unlock()
        }
        callback.invoke()
        callback.install(nil)
        callback.invoke()

        lock.lock()
        let result = count
        lock.unlock()
        XCTAssertEqual(result, 1)
    }
}

final class RelayHubTests: XCTestCase {
    private struct RelayFixture {
        let leftClient: Int32
        let leftHub: Int32
        let rightHub: Int32
        let rightClient: Int32
    }

    func testBidirectionalRelayAndHalfClose() throws {
        let fixture = try makeFixture()
        defer {
            close(fixture.leftClient)
            close(fixture.rightClient)
        }

        let completed = expectation(description: "relay completed")
        RelayHub.shared.relay(
            fixture.leftHub,
            fixture.rightHub,
            byteTracker: nil,
            completion: {
                close(fixture.leftHub)
                close(fixture.rightHub)
                completed.fulfill()
            }
        )

        let request = Data("request-body".utf8)
        try Self.writeAll(fixture.leftClient, request)
        XCTAssertEqual(try readExact(fixture.rightClient, count: request.count), request)

        _ = shutdown(fixture.leftClient, SHUT_WR)
        XCTAssertTrue(waitForEOF(fixture.rightClient), "right side should observe the forwarded half-close")

        let response = Data("response-after-half-close".utf8)
        try Self.writeAll(fixture.rightClient, response)
        XCTAssertEqual(try readExact(fixture.leftClient, count: response.count), response)
        _ = shutdown(fixture.rightClient, SHUT_WR)
        XCTAssertTrue(waitForEOF(fixture.leftClient))

        wait(for: [completed], timeout: 2)
    }

    func testSlowReceiverDoesNotBlockOtherRelay() throws {
        let slow = try makeFixture()
        let fast = try makeFixture()
        defer {
            close(slow.leftClient)
            close(slow.rightClient)
            close(fast.leftClient)
            close(fast.rightClient)
        }

        let slowCompleted = expectation(description: "slow relay completed")
        let fastCompleted = expectation(description: "fast relay completed")
        RelayHub.shared.relay(slow.leftHub, slow.rightHub, byteTracker: nil, completion: {
            close(slow.leftHub)
            close(slow.rightHub)
            slowCompleted.fulfill()
        })
        RelayHub.shared.relay(fast.leftHub, fast.rightHub, byteTracker: nil, completion: {
            close(fast.leftHub)
            close(fast.rightHub)
            fastCompleted.fulfill()
        })

        let writerDone = expectation(description: "slow writer finished")
        let largePayload = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
        DispatchQueue.global().async {
            try? Self.writeAll(slow.leftClient, largePayload)
            _ = shutdown(slow.leftClient, SHUT_WR)
            writerDone.fulfill()
        }

        // Give the slow direction enough time to fill its relay buffer and kernel send buffer.
        usleep(100_000)

        let ping = Data("ping".utf8)
        try Self.writeAll(fast.leftClient, ping)
        XCTAssertEqual(try readExact(fast.rightClient, count: ping.count, timeoutMs: 500), ping)

        _ = shutdown(fast.leftClient, SHUT_WR)
        _ = shutdown(fast.rightClient, SHUT_WR)
        XCTAssertTrue(RelayHub.shared.shutdownRelay(containing: slow.leftHub))

        wait(for: [fastCompleted, slowCompleted, writerDone], timeout: 3)
    }

    func testShutdownRelayCompletesPromptly() throws {
        let fixture = try makeFixture()
        defer {
            close(fixture.leftClient)
            close(fixture.rightClient)
        }

        let completed = expectation(description: "cancelled relay completed")
        RelayHub.shared.relay(
            fixture.leftHub,
            fixture.rightHub,
            byteTracker: nil,
            completion: {
                close(fixture.leftHub)
                close(fixture.rightHub)
                completed.fulfill()
            }
        )

        XCTAssertTrue(RelayHub.shared.shutdownRelay(containing: fixture.leftHub))
        wait(for: [completed], timeout: 1)
    }

    private func makeFixture() throws -> RelayFixture {
        var left: [Int32] = [-1, -1]
        var right: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &left) == 0,
              socketpair(AF_UNIX, SOCK_STREAM, 0, &right) == 0 else {
            throw POSIXError(.ENFILE)
        }
        for fd in left + right {
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        return RelayFixture(
            leftClient: left[0],
            leftHub: left[1],
            rightHub: right[0],
            rightClient: right[1]
        )
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    private func readExact(_ fd: Int32, count: Int, timeoutMs: Int32 = 1_000) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, count))
        while result.count < count {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, timeoutMs) > 0 else {
                throw POSIXError(.ETIMEDOUT)
            }
            let requested = min(buffer.count, count - result.count)
            let received = recv(fd, &buffer, requested, 0)
            guard received > 0 else { throw POSIXError(.ECONNRESET) }
            result.append(buffer, count: received)
        }
        return result
    }

    private func waitForEOF(_ fd: Int32, timeoutMs: Int32 = 1_000) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, timeoutMs) > 0 else { return false }
        var byte: UInt8 = 0
        return recv(fd, &byte, 1, 0) == 0
    }
}
