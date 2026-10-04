import Network
import XCTest
@testable import PhorosNetwork
import Phoros
import PhorosSession

private let deviceID = "phone-1"
private let secret = SharedSecret(bytes: Data(repeating: 0x42, count: 32))!

/// Every `LegacyTransportTests` test again, over an encrypted link.
final class EncryptedLegacyTransportTests: LegacyTransportTests {
    override var hostSecurity: PhorosConnectionSecurity {
        .host(storedSecret: { $0 == deviceID ? secret : nil }, allowsPlaintext: false)
    }
    override var clientSecurity: PhorosConnectionSecurity {
        .client(.authenticate(deviceID: deviceID, secret: secret))
    }

    func testLinkReportsEncryptionAndDevice() {
        host.start()
        XCTAssertTrue(client.link.isEncrypted)
        let deadline = Date().addingTimeInterval(2)
        while !host.link.isEncrypted, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(host.link.isEncrypted)
        XCTAssertEqual(host.link.secureDeviceID, deviceID)
    }
}

/// `PhorosConnection` handshakes over loopback: who may connect, and what a listener on
/// the wire sees.
final class SecureConnectionTests: XCTestCase {
    private var listener: NWListener!
    private var hostLink: PhorosConnection?
    private var clientLink: PhorosConnection?
    /// Every byte the host received, as it arrived on the wire (before opening).
    private var tap: TapListener?

    override func tearDown() {
        clientLink?.cancel(); hostLink?.cancel(); listener?.cancel(); tap?.cancel()
    }

    /// Starts a host with `hostSecurity`, connects a client with `clientSecurity`, and
    /// returns how each side ended or became ready.
    private func connect(
        host hostSecurity: PhorosConnectionSecurity,
        client clientSecurity: PhorosConnectionSecurity,
        hostFrames: @escaping (Frame) -> Void = { _ in },
        clientFrames: @escaping (Frame) -> Void = { _ in },
        clientReady: XCTestExpectation? = nil,
        hostReady: XCTestExpectation? = nil,
        clientEnd: ((PhorosConnectionEnd) -> Void)? = nil,
        hostEnd: ((PhorosConnectionEnd) -> Void)? = nil
    ) throws {
        listener = try NWListener(using: PhorosConnection.parameters(), on: .any)
        listener.newConnectionHandler = { [self] connection in
            let link = PhorosConnection(accepting: connection, security: hostSecurity)
            link.onFrame = hostFrames
            link.onReady = { hostReady?.fulfill() }
            link.onEnd = { hostEnd?($0) }
            hostLink = link
            link.start()
        }
        let listening = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        listener.start(queue: DispatchQueue(label: "test.listener"))
        wait(for: [listening], timeout: 5)
        let link = PhorosConnection(to: .hostPort(host: "127.0.0.1", port: listener.port!), security: clientSecurity)
        link.handshakeTimeout = 1
        link.onFrame = clientFrames
        link.onReady = { clientReady?.fulfill() }
        link.onEnd = { clientEnd?($0) }
        clientLink = link
        link.start()
    }

    func testAuthenticatedRoundTrip() throws {
        let ready = expectation(description: "client ready")
        let hostGot = expectation(description: "host got")
        let clientGot = expectation(description: "client got")
        try connect(
            host: .host(storedSecret: { $0 == deviceID ? secret : nil }, allowsPlaintext: false),
            client: .client(.authenticate(deviceID: deviceID, secret: secret)),
            hostFrames: { [self] frame in
                if case .message(let json) = frame, json == Data(#"{"type":"auth_request"}"#.utf8) {
                    hostGot.fulfill()
                    hostLink?.send(Packet.encode(.control, payload: Data(#"{"type":"auth_success"}"#.utf8)))
                }
            },
            clientFrames: { frame in
                if case .packet(let packet) = frame, packet.payload == Data(#"{"type":"auth_success"}"#.utf8) { clientGot.fulfill() }
            },
            clientReady: ready
        )
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(clientLink!.isEncrypted)
        clientLink!.send(Data(#"{"type":"auth_request"}"#.utf8))
        wait(for: [hostGot, clientGot], timeout: 5)
        XCTAssertEqual(hostLink?.secureDeviceID, deviceID)
    }

    func testSendsBeforeTheHandshakeFinishesAreHeldAndSealed() throws {
        let got = expectation(description: "host got both"); got.expectedFulfillmentCount = 2
        var seen: [Data] = []
        try connect(
            host: .host(storedSecret: { _ in secret }, allowsPlaintext: false),
            client: .client(.authenticate(deviceID: deviceID, secret: secret)),
            hostFrames: { if case .message(let json) = $0 { seen.append(json); got.fulfill() } }
        )
        clientLink!.send(Data("{\"n\":1}".utf8))
        clientLink!.send(Data("{\"n\":2}".utf8))
        wait(for: [got], timeout: 5)
        XCTAssertEqual(seen, [Data("{\"n\":1}".utf8), Data("{\"n\":2}".utf8)])
    }

    func testPairingModeNeedsNoSecret() throws {
        let ready = expectation(description: "client ready")
        try connect(
            host: .host(storedSecret: { _ in nil }, allowsPlaintext: false),
            client: .client(.pair),
            clientReady: ready
        )
        wait(for: [ready], timeout: 5)
        XCTAssertTrue(clientLink!.isEncrypted)
        XCTAssertNil(clientLink!.secureDeviceID)
    }

    func testUnknownDeviceIsToldToPairAgain() throws {
        let ended = expectation(description: "client ended")
        var reason: PhorosConnectionEnd?
        try connect(
            host: .host(storedSecret: { _ in nil }, allowsPlaintext: false),
            client: .client(.authenticate(deviceID: deviceID, secret: secret)),
            clientEnd: { reason = $0; ended.fulfill() }
        )
        wait(for: [ended], timeout: 5)
        guard case .secureChannelFailed(.unknownDevice) = reason else { return XCTFail("\(String(describing: reason))") }
    }

    func testHostWithTheWrongSecretIsCaughtBeforeTheClientSendsAnything() throws {
        let ended = expectation(description: "client ended")
        var reason: PhorosConnectionEnd?
        let other = SharedSecret(bytes: Data(repeating: 0x07, count: 32))!
        try connect(
            host: .host(storedSecret: { _ in other }, allowsPlaintext: false),
            client: .client(.authenticate(deviceID: deviceID, secret: secret)),
            clientEnd: { reason = $0; ended.fulfill() }
        )
        wait(for: [ended], timeout: 5)
        guard case .secureChannelFailed(.hostNotAuthenticated) = reason else { return XCTFail("\(String(describing: reason))") }
    }

    func testOlderClientIsServedPlaintextWhenAllowed() throws {
        let got = expectation(description: "host got hello")
        try connect(
            host: .host(storedSecret: { _ in secret }, allowsPlaintext: true),
            client: .none,
            hostFrames: { if case .message = $0 { got.fulfill() } }
        )
        clientLink!.send(try JSONEncoder().encode(PairingMessage(type: .hello, deviceName: "old", deviceID: "x")))
        wait(for: [got], timeout: 5)
        XCTAssertEqual(hostLink?.isEncrypted, false)
    }

    func testOlderClientIsRefusedWhenPlaintextIsOff() throws {
        let ended = expectation(description: "host ended")
        var reason: PhorosConnectionEnd?
        try connect(
            host: .host(storedSecret: { _ in secret }, allowsPlaintext: false),
            client: .none,
            hostEnd: { reason = $0; ended.fulfill() }
        )
        clientLink!.send(try JSONEncoder().encode(PairingMessage(type: .hello, deviceName: "old", deviceID: "x")))
        wait(for: [ended], timeout: 5)
        guard case .secureChannelFailed(.plaintextRefused) = reason else { return XCTFail("\(String(describing: reason))") }
    }

    func testEncryptedClientAgainstAnOlderHostTimesOut() throws {
        let ended = expectation(description: "client ended")
        var reason: PhorosConnectionEnd?
        // An older host: plaintext only, ignores a message type it does not know.
        try connect(host: .none, client: .client(.pair), clientEnd: { reason = $0; ended.fulfill() })
        wait(for: [ended], timeout: 5)
        guard case .secureChannelFailed(.timedOut) = reason else { return XCTFail("\(String(describing: reason))") }
    }

    func testNothingSecretIsVisibleOnTheWire() throws {
        // A relay between client and host records every byte the client sends.
        let host = try NWListener(using: PhorosConnection.parameters(), on: .any)
        let gotSecret = expectation(description: "host saw the auth request")
        host.newConnectionHandler = { [self] connection in
            let link = PhorosConnection(accepting: connection, security: .host(storedSecret: { _ in secret }, allowsPlaintext: false))
            link.onFrame = { if case .message(let json) = $0, String(decoding: json, as: UTF8.self).contains(secret.hex) { gotSecret.fulfill() } }
            hostLink = link
            link.start()
        }
        let listening = expectation(description: "listening")
        host.stateUpdateHandler = { if case .ready = $0 { listening.fulfill() } }
        host.start(queue: DispatchQueue(label: "test.host"))
        wait(for: [listening], timeout: 5)
        listener = host
        tap = try TapListener(forwardingTo: host.port!)

        let ready = expectation(description: "client ready")
        let link = PhorosConnection(to: .hostPort(host: "127.0.0.1", port: tap!.port), security: .client(.authenticate(deviceID: deviceID, secret: secret)))
        link.onReady = { ready.fulfill() }
        clientLink = link
        link.start()
        wait(for: [ready], timeout: 5)
        // What Beam sends after the handshake: the auth request, secret and all.
        link.send(try JSONEncoder().encode(ClientCapabilities(deviceName: "phone", deviceID: deviceID).authRequest(secret: secret)))
        link.send(Data(repeating: 0x41, count: 64))
        wait(for: [gotSecret], timeout: 5)

        let wire = tap!.recorded
        XCTAssertGreaterThan(wire.count, 100)
        XCTAssertNil(wire.range(of: Data(secret.hex.utf8)), "the secret crossed the wire in the clear")
        XCTAssertNil(wire.range(of: secret.bytes), "the secret crossed the wire in the clear")
        XCTAssertNil(wire.range(of: Data(repeating: 0x41, count: 64)), "a frame crossed the wire in the clear")
    }
}

/// A TCP relay that records what the client sends.
private final class TapListener {
    let listener: NWListener
    private let queue = DispatchQueue(label: "test.tap")
    private var bytes = Data()
    private var connections: [NWConnection] = []

    var port: NWEndpoint.Port { listener.port! }
    var recorded: Data { queue.sync { bytes } }

    init(forwardingTo target: NWEndpoint.Port) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [self] inbound in
            let outbound = NWConnection(host: "127.0.0.1", port: target, using: .tcp)
            connections += [inbound, outbound]
            inbound.start(queue: queue)
            outbound.start(queue: queue)
            pump(from: inbound, to: outbound, record: true)
            pump(from: outbound, to: inbound, record: false)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    private func pump(from: NWConnection, to: NWConnection, record: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                if record { self.bytes.append(data) }
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if done || error != nil { return }
            self.pump(from: from, to: to, record: record)
        }
    }

    func cancel() {
        connections.forEach { $0.cancel() }
        listener.cancel()
    }
}
