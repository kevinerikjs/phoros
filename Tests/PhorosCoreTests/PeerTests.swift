import Network
import XCTest
@testable import PhorosCore

/// Two str0m peers on loopback: ICE lite + DTLS + SCTP through the C ABI, then the socket
/// ownership tournament from BEAM-53: the round trip of a realtime-channel echo when Rust
/// owns both sockets (design B) versus Network.framework feeding the client (design A).
final class PeerTests: XCTestCase {
    private func nowMicros() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1000) }

    private func percentiles(_ values: [Double]) -> String {
        let s = values.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
        return String(format: "p50 %.0f  p90 %.0f  p99 %.0f  max %.0f µs (n=%d)", p(0.5), p(0.9), p(0.99), s.last ?? 0, s.count)
    }

    /// Host echoes every realtime message back; the client measures the round trip.
    private func runEcho(hostPort: UInt16, clientPort: UInt16, client: RealtimePeer, host: RealtimePeer, sender: ((Int, Data) -> Int32)? = nil, drive: (String) -> (() -> Void)) -> [Double] {
        let connected = expectation(description: "both connected"); connected.expectedFulfillmentCount = 2
        host.onEvent = { if case .connected = $0 { connected.fulfill() } }
        client.onEvent = { if case .connected = $0 { connected.fulfill() } }
        host.onData = { channel, bytes in _ = host.send(channel: channel, bytes) }
        var rtts: [Double] = []
        let lock = NSLock()
        client.onData = { _, bytes in
            let sentAt = bytes.load(as: Int64.self)
            lock.lock(); rtts.append(Double(self.nowMicros() - sentAt)); lock.unlock()
        }
        let stop = drive(host.localInfo)
        wait(for: [connected], timeout: 10)
        // send until the channel is open, then 500 timestamped messages at 2 ms
        var payload = Data(count: 64)
        var sent = 0
        let deadline = Date().addingTimeInterval(10)
        while sent < 500, Date() < deadline {
            let t = nowMicros()
            payload.withUnsafeMutableBytes { $0.storeBytes(of: t, as: Int64.self) }
            if (sender ?? { client.send(channel: $0, $1) })(1, payload) == 0 { sent += 1 }
            Thread.sleep(forTimeInterval: 0.002)
        }
        Thread.sleep(forTimeInterval: 0.5)
        stop()
        lock.lock(); let result = rtts; lock.unlock()
        return result
    }

    func testDesignB_RustOwnsBothSockets() {
        let host = RealtimePeer(isHost: true, localAddress: "127.0.0.1:39011")!
        let client = RealtimePeer(isHost: false, localAddress: "127.0.0.1:39012")!
        XCTAssertEqual(host.runOwnSocket(), 0); XCTAssertEqual(client.runOwnSocket(), 0)
        let rtts = runEcho(hostPort: 39011, clientPort: 39012, client: client, host: host) { hostInfo in
            host.setRemote(info: client.localInfo, address: "127.0.0.1:39012", nowMicros: 0)
            client.setRemote(info: hostInfo, address: "127.0.0.1:39011", nowMicros: 0)
            return { client.destroy(); host.destroy() }
        }
        print("design B (Rust sockets both sides): \(percentiles(rtts))")
        XCTAssertGreaterThan(rtts.count, 450)
    }

    func testDesignA_NetworkFrameworkFeedsTheClient() {
        let host = RealtimePeer(isHost: true, localAddress: "127.0.0.1:39021")!
        let client = RealtimePeer(isHost: false, localAddress: "127.0.0.1:39022")!
        XCTAssertEqual(host.runOwnSocket(), 0)
        let queue = DispatchQueue(label: "peer.client", qos: .userInteractive)
        let driven = NetworkDrivenPeer(peer: client, remoteHost: "127.0.0.1", remotePort: 39021, localPort: 39022, queue: queue)
        let rtts = runEcho(hostPort: 39021, clientPort: 39022, client: client, host: host, sender: { channel, data in
            // an open channel accepts; before that the peer returns an error we mirror here
            let status = client.send(channel: channel, data)
            if status == 0 { queue.async { driven.pump() } }
            return status
        }) { hostInfo in
            host.setRemote(info: client.localInfo, address: "127.0.0.1:39022", nowMicros: 0)
            driven.start(remoteInfo: hostInfo)
            return { driven.stop(); host.destroy() }
        }
        print("design A (Network.framework feeds the client): \(percentiles(rtts))")
        XCTAssertGreaterThan(rtts.count, 450)
    }

    func testDesignA_WithInteractiveVideoServiceClass() {
        let host = RealtimePeer(isHost: true, localAddress: "127.0.0.1:39031")!
        let client = RealtimePeer(isHost: false, localAddress: "127.0.0.1:39032")!
        XCTAssertEqual(host.runOwnSocket(), 0)
        let queue = DispatchQueue(label: "peer.client", qos: .userInteractive)
        let driven = NetworkDrivenPeer(peer: client, remoteHost: "127.0.0.1", remotePort: 39031, localPort: 39032, serviceClass: .interactiveVideo, queue: queue)
        let rtts = runEcho(hostPort: 39031, clientPort: 39032, client: client, host: host, sender: { channel, data in
            let status = client.send(channel: channel, data)
            if status == 0 { queue.async { driven.pump() } }
            return status
        }) { hostInfo in
            host.setRemote(info: client.localInfo, address: "127.0.0.1:39032", nowMicros: 0)
            driven.start(remoteInfo: hostInfo)
            return { driven.stop(); host.destroy() }
        }
        print("design A + interactiveVideo: \(percentiles(rtts))")
        XCTAssertGreaterThan(rtts.count, 450)
    }
}
