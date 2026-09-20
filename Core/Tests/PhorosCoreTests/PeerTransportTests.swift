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
        let big = Data((0..<300_000).map { UInt8($0 & 0xff) })   // a 1080p keyframe
        Thread.sleep(forTimeInterval: 0.3)   // let the channels open
        host.sendVideo(big, presentationTimestamp: 1, isKeyframe: true)
        host.sendVideo(Data(repeating: 1, count: 20_000), presentationTimestamp: 2, isKeyframe: false)
        host.sendVideo(Data(repeating: 2, count: 500), presentationTimestamp: 3, isKeyframe: false)
        client.sendInput(ControllerReport(buttons: [.a]), connected: true)
        wait(for: [frames, gotInput], timeout: 10)
        lock.lock(); let got = received.sorted { $0.frameNumber < $1.frameNumber }; lock.unlock()
        XCTAssertEqual(got.map(\.frameNumber), [0, 1, 2])
        XCTAssertEqual(got[0].bitstream, big)
        XCTAssertTrue(got[0].isKeyframe)
        XCTAssertEqual(got[1].bitstream.count, 20_000)
        client.cancel(); host.cancel()
    }
}
