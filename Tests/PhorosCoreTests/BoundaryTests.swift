import XCTest
@testable import PhorosCore

/// The boundary tests from the design (article section 47): the ways a caller can misuse
/// the core, and what the core does about each.
final class BoundaryTests: XCTestCase {
    func testVersionAndLifecycle() {
        XCTAssertEqual(RealtimeCore.version, "0.1.0")
        let before = RealtimeCore.liveHandles
        var core: RealtimeCore? = RealtimeCore()
        XCTAssertEqual(RealtimeCore.liveHandles, before + 1)
        core = nil
        XCTAssertEqual(RealtimeCore.liveHandles, before)
        _ = core
    }

    func testCreateDestroyCyclesDoNotLeakHandles() {
        let before = RealtimeCore.liveHandles
        for _ in 0..<10_000 { _ = RealtimeCore() }
        XCTAssertEqual(RealtimeCore.liveHandles, before)
    }

    func testFeedThenPollTransmitsAndThenTimesOut() throws {
        let core = RealtimeCore()
        var events: [CoreEvent] = []
        core.onEvent = { events.append($0) }
        try core.feed(Data([1, 2, 3]), nowMicros: 10)
        guard case .transmit(let buffer) = try core.poll(nowMicros: 11) else { return XCTFail("expected transmit") }
        XCTAssertEqual(buffer.count, 12)
        XCTAssertEqual(Array(buffer.prefix(4)), Array("PHAK".utf8))
        XCTAssertEqual(try core.poll(nowMicros: 12), .timeout(atMicros: 1_000_012))
        XCTAssertEqual(events, [.fed(bytes: 3)])
    }

    func testZeroLengthIsAcceptedAndOversizedRefused() throws {
        let core = RealtimeCore()
        try core.feed(Data(), nowMicros: 0)
        XCTAssertThrowsError(try core.feed(Data(count: 65_536), nowMicros: 0)) { XCTAssertEqual($0 as? CoreError, .tooLarge) }
        try core.feed(Data(count: 65_535), nowMicros: 0)
    }

    func testTeardownCallbackFiresOnceAndCallsAfterDestroyThrow() throws {
        let core = RealtimeCore()
        var destroying = 0
        core.onEvent = { if case .destroying = $0 { destroying += 1 } }
        try core.feed(Data([1]), nowMicros: 0)
        core.destroy()
        core.destroy()
        XCTAssertEqual(destroying, 1)
        XCTAssertThrowsError(try core.feed(Data([1]), nowMicros: 0)) { XCTAssertEqual($0 as? CoreError, .destroyed) }
        XCTAssertThrowsError(try core.poll(nowMicros: 0)) { XCTAssertEqual($0 as? CoreError, .destroyed) }
    }

    func testPanicIsContainedAndReportedThenTheHandleIsPoisoned() throws {
        let core = RealtimeCore()
        XCTAssertEqual(core._testPanic(), 3, "a Rust panic becomes a status, never an unwind")
        XCTAssertThrowsError(try core.feed(Data([1]), nowMicros: 0)) { XCTAssertEqual($0 as? CoreError, .poisoned) }
        core.destroy()   // destroying a poisoned core must not crash
    }

    func testThreadingMisuseSerializesInsteadOfCorrupting() throws {
        let core = RealtimeCore()
        let fed = expectation(description: "fed"); fed.expectedFulfillmentCount = 8
        let lock = NSLock(); var counted: Int64 = 0
        core.onEvent = { if case .fed(let b) = $0 { lock.lock(); counted += b; lock.unlock() } }
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1_000 { try? core.feed(Data(count: 100), nowMicros: 0) }
            fed.fulfill()
        }
        wait(for: [fed], timeout: 20)
        XCTAssertEqual(counted, 800_000)
        guard case .transmit(let buffer) = try core.poll(nowMicros: 1) else { return XCTFail() }
        let datagrams = buffer.load(fromByteOffset: 8, as: UInt32.self)
        XCTAssertEqual(datagrams, 8_000)
    }

    func testCallbackMayReenterTheCore() throws {
        let core = RealtimeCore()
        var polledFromCallback: CorePoll?
        core.onEvent = { event in
            if case .fed = event, polledFromCallback == nil { polledFromCallback = try? core.poll(nowMicros: 5) }
        }
        try core.feed(Data([9]), nowMicros: 4)
        guard case .transmit = polledFromCallback else { return XCTFail("the callback runs with the lock released") }
    }

    /// The cost of the boundary, measured, not claimed: 1400-byte datagrams through feed
    /// and poll. Printed so the number lands in the ticket, asserted loosely so a slow CI
    /// box does not fail it.
    func testBoundaryCostPerDatagram() throws {
        let core = RealtimeCore()
        let datagram = Data(count: 1400)
        let n = 200_000
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<n {
            try core.feed(datagram, nowMicros: Int64(i))
            _ = try core.poll(nowMicros: Int64(i))
        }
        let perCall = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n)
        print("boundary cost: \(Int(perCall)) ns per feed+poll of 1400 B (\(Int(1400 * 1e9 / perCall / 1e6)) MB/s)")
        XCTAssertLessThan(perCall, 20_000)
    }
}
