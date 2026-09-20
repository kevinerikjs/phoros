import Network
import XCTest
@testable import PhorosNetwork
import Phoros
import PhorosSession

/// A host transport and a client transport over a loopback TCP listener: what one sends
/// the other receives as the unit it was sent as, and the wire between them is the v1 wire.
final class LegacyTransportTests: XCTestCase {
    var listener: NWListener!
    var host: PhorosLegacyTransport!
    var client: PhorosLegacyTransport!

    override func setUpWithError() throws {
        listener = try NWListener(using: PhorosConnection.parameters(), on: .any)
        let accepted = expectation(description: "accepted")
        listener.newConnectionHandler = { [self] connection in
            host = PhorosLegacyTransport(accepting: connection, options: LegacyTransportOptions(role: .host, probeInterval: 0.05, keepAwakeInterval: 0))
            accepted.fulfill()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        wait(for: [ready], timeout: 5)
        let port = listener.port!
        client = PhorosLegacyTransport(to: .hostPort(host: "127.0.0.1", port: port))
        let clientReady = expectation(description: "client ready")
        client.onReady = { clientReady.fulfill() }
        client.start()
        wait(for: [accepted, clientReady], timeout: 5)
    }

    override func tearDown() {
        client?.cancel(); host?.cancel(); listener?.cancel()
    }

    func testVideoArrivesAsWholeFramesInOrder() {
        host.start()
        let got = expectation(description: "frames"); got.expectedFulfillmentCount = 3
        var frames: [AssembledFrame] = []
        client.onInbound = { if case .video(let f) = $0 { frames.append(f); got.fulfill() } }
        let big = Data((0..<20_000).map { UInt8($0 & 0xff) })
        host.sendVideoParameterSets(Data([0, 0, 0, 1, 0x67]), codec: .h264)
        host.sendVideo(big, presentationTimestamp: 1_000, isKeyframe: true)
        host.sendVideo(Data([1, 2, 3]), presentationTimestamp: 2_000, isKeyframe: false)
        host.sendVideo(Data(repeating: 9, count: 1_500), presentationTimestamp: 3_000, isKeyframe: false)
        wait(for: [got], timeout: 5)
        XCTAssertEqual(frames.map(\.frameNumber), [0, 1, 2])
        XCTAssertEqual(frames[0].bitstream, big)
        XCTAssertTrue(frames[0].isKeyframe)
        XCTAssertEqual(frames[1].bitstream, Data([1, 2, 3]))
        XCTAssertEqual(frames.map(\.presentationTimestamp), [1_000, 2_000, 3_000])
    }

    func testControlInputAudioAndMessagesCrossBothWays() {
        host.start()
        let hostGot = expectation(description: "host inbound"); hostGot.expectedFulfillmentCount = 3
        var hostInbound: [String] = []
        host.onInbound = { inbound in
            switch inbound {
            case .control(.qualityRequest(let p)): hostInbound.append("quality \(p.rawValue)"); hostGot.fulfill()
            case .input(let r, let connected): hostInbound.append("input a=\(r.buttons.contains(.a)) \(connected)"); hostGot.fulfill()
            case .message(let json): hostInbound.append("message \(json.count > 0)"); hostGot.fulfill()
            default: break
            }
        }
        let clientGot = expectation(description: "client inbound"); clientGot.expectedFulfillmentCount = 2
        var clientInbound: [String] = []
        client.onInbound = { inbound in
            switch inbound {
            case .audio(let header, let data, let codec): clientInbound.append("audio \(header.sequenceNumber) \(data.count) \(codec.wireName)"); clientGot.fulfill()
            case .control(.qualityChanged(let p)): clientInbound.append("changed \(p.rawValue)"); clientGot.fulfill()
            default: break
            }
        }
        client.sendControl(.qualityRequest(.p720_60))
        client.sendInput(ControllerReport(buttons: [.a]), connected: true)
        client.sendMessage(try! JSONEncoder().encode(PairingMessage(type: .hello, deviceName: "t", deviceID: "d")))
        host.sendAudio(Data(repeating: 7, count: 100), codec: .pcmFloat32, presentationTimestamp: 42)
        host.sendControl(.qualityChanged(.p720_60))
        wait(for: [hostGot, clientGot], timeout: 5)
        XCTAssertEqual(Set(hostInbound), ["quality 720p60", "input a=true true", "message true"])
        XCTAssertEqual(Set(clientInbound), ["audio 0 100 pcm_f32le", "changed 720p60"])
    }

    func testHostProbesAndClientAnswersWithoutTheApplication() {
        host.start()
        host.setStreaming(true)
        let probed = expectation(description: "probe traced")
        host.onTrace = { if case .probe = $0 { probed.fulfill() } }
        wait(for: [probed], timeout: 5)
        XCTAssertNotNil(host.metrics.roundTrip)
        XCTAssertGreaterThan(host.metrics.bitrate, 0)
    }

    func testUnknownControlTypeIsReportedNotDropped() {
        host.start()
        let got = expectation(description: "unknown")
        host.onInbound = { if case .unknownControl(let type) = $0 { XCTAssertEqual(type, "teleport"); got.fulfill() } }
        client.sendMessage(Data(#"{"type":"teleport","payload":{}}"#.utf8))
        wait(for: [got], timeout: 5)
    }
}
