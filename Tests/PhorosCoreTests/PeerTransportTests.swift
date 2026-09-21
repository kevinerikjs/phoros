import XCTest
@testable import PhorosCore
import Phoros
import PhorosSession

final class PeerTransportTests: XCTestCase {
    func testFramesLargerThanAMessageArriveWholeAndInputAndControlCross() {
        let hostPeer = RealtimePeer(isHost: true, localAddress: "127.0.0.1:39041")!
        let clientPeer = RealtimePeer(isHost: false, localAddress: "127.0.0.1:39042")!
        let host = PhorosPeerTransport(peer: hostPeer)
        let client = PhorosPeerTransport(peer: clientPeer)
        XCTAssertEqual(hostPeer.runOwnSocket(), 0); XCTAssertEqual(clientPeer.runOwnSocket(), 0)
        let ready = expectation(description: "ready"); ready.expectedFulfillmentCount = 2
        host.onReady = { ready.fulfill() }; client.onReady = { ready.fulfill() }
        hostPeer.setRemote(info: clientPeer.localInfo, address: "127.0.0.1:39042", nowMicros: 0)
        clientPeer.setRemote(info: hostPeer.localInfo, address: "127.0.0.1:39041", nowMicros: 0)
        wait(for: [ready], timeout: 10)

        let frames = expectation(description: "frames"); frames.expectedFulfillmentCount = 3
        var received: [AssembledFrame] = []
        let lock = NSLock()
        client.onInbound = { if case .video(let f) = $0 { lock.lock(); received.append(f); lock.unlock(); frames.fulfill() } }
        let gotInput = expectation(description: "input")
        host.onInbound = { if case .input(let r, let c) = $0, r.buttons.contains(.a), c { gotInput.fulfill() } }
        // Annex B with real NAL headers: an IDR of 300 KB (a 1080p keyframe), two slices.
        func nal(_ type: UInt8, _ count: Int) -> Data { Data([0, 0, 0, 1, type]) + Data((0..<count).map { UInt8($0 % 251 + 1) }) }
        let big = nal(0x65, 300_000), delta1 = nal(0x41, 20_000), delta2 = nal(0x41, 500)
        Thread.sleep(forTimeInterval: 0.3)   // let the channels open
        host.sendVideo(big, presentationTimestamp: 1_000_000, isKeyframe: true)
        host.sendVideo(delta1, presentationTimestamp: 1_008_333, isKeyframe: false)
        host.sendVideo(delta2, presentationTimestamp: 1_016_666, isKeyframe: false)
        client.sendInput(ControllerReport(buttons: [.a]), connected: true)
        wait(for: [frames, gotInput], timeout: 10)
        lock.lock(); let got = received.sorted { $0.presentationTimestamp < $1.presentationTimestamp }; lock.unlock()
        print("received:", got.map { "pts \($0.presentationTimestamp) \($0.bitstream.count) B key=\($0.isKeyframe)" })
        XCTAssertEqual(got.map(\.presentationTimestamp), [1_000_000, 1_008_333, 1_016_666].map { $0 * 9 / 100 * 100 / 9 })
        XCTAssertEqual(got[0].bitstream, big, "the keyframe comes back byte for byte")
        XCTAssertTrue(got[0].isKeyframe)
        XCTAssertEqual(got[1].bitstream, delta1)
        XCTAssertEqual(got[2].bitstream, delta2)
        client.cancel(); host.cancel()
    }
}
