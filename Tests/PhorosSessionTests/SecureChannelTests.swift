import CryptoKit
import XCTest
@testable import PhorosSession
import Phoros

final class SecureChannelTests: XCTestCase {
    private let secret = PhorosSession.SharedSecret(bytes: Data(repeating: 0x42, count: 32))!

    private func handshake(client mode: SecureChannelClient.Mode, hostSecret: PhorosSession.SharedSecret?) throws -> (SecureChannelKeys, SecureChannelKeys) {
        let client = SecureChannelClient(mode: mode)
        guard case .accepted(let reply, let hostKeys) = SecureChannelHost.accept(client.hello(), storedSecret: { _ in hostSecret }) else {
            throw SecureChannelError.malformed
        }
        return (try client.finish(reply), hostKeys)
    }

    func testBothSidesDeriveMatchingKeys() throws {
        var (client, host) = try handshake(client: .authenticate(deviceID: "d", secret: secret), hostSecret: secret)
        for size in [0, 1, 14, 1_410, 100_000] {
            let frame = Data((0..<size).map { UInt8($0 & 0xff) })
            XCTAssertEqual(try host.receiving.open(client.sending.seal(frame)), frame)
            XCTAssertEqual(try client.receiving.open(host.sending.seal(frame)), frame)
        }
        XCTAssertEqual(host.deviceID, "d")
        XCTAssertEqual(host.mode, .authenticate)
    }

    func testSealedFrameIsSixteenBytesLonger() throws {
        var (client, _) = try handshake(client: .pair, hostSecret: nil)
        XCTAssertEqual(try client.sending.seal(Data(count: 1_410)).count, 1_410 + FrameCipher.overhead)
    }

    func testDirectionsUseDifferentKeys() throws {
        var (client, host) = try handshake(client: .pair, hostSecret: nil)
        let sealed = try client.sending.seal(Data("hello".utf8))
        // A frame reflected back at its sender does not open.
        XCTAssertThrowsError(try client.receiving.open(sealed))
        XCTAssertNoThrow(try host.receiving.open(sealed))
    }

    func testTamperedReplayedAndReorderedFramesFail() throws {
        var (client, host) = try handshake(client: .pair, hostSecret: nil)
        var tampered = try client.sending.seal(Data("one".utf8))
        tampered[tampered.startIndex] ^= 1
        XCTAssertThrowsError(try host.receiving.open(tampered)) { XCTAssertEqual($0 as? SecureChannelError, .integrity) }

        var (c2, h2) = try handshake(client: .pair, hostSecret: nil)
        let first = try c2.sending.seal(Data("1".utf8))
        let second = try c2.sending.seal(Data("2".utf8))
        XCTAssertThrowsError(try h2.receiving.open(second))  // out of order

        var (c3, h3) = try handshake(client: .pair, hostSecret: nil)
        let once = try c3.sending.seal(Data("1".utf8))
        XCTAssertNoThrow(try h3.receiving.open(once))
        XCTAssertThrowsError(try h3.receiving.open(once))  // replayed
        _ = (first, host)
    }

    func testWrongSecretIsCaughtByTheClient() {
        let client = SecureChannelClient(mode: .authenticate(deviceID: "d", secret: secret))
        let other = PhorosSession.SharedSecret(bytes: Data(repeating: 1, count: 32))!
        guard case .accepted(let reply, _) = SecureChannelHost.accept(client.hello(), storedSecret: { _ in other }) else { return XCTFail() }
        XCTAssertThrowsError(try client.finish(reply)) { XCTAssertEqual($0 as? SecureChannelError, .hostNotAuthenticated) }
    }

    func testUnknownDeviceIsRejected() {
        let client = SecureChannelClient(mode: .authenticate(deviceID: "d", secret: secret))
        guard case .rejected(let reply, let error) = SecureChannelHost.accept(client.hello(), storedSecret: { _ in nil }) else { return XCTFail() }
        XCTAssertEqual(error, .unknownDevice)
        XCTAssertThrowsError(try client.finish(reply)) { XCTAssertEqual($0 as? SecureChannelError, .unknownDevice) }
    }

    func testMalformedHelloIsRejected() {
        let hello = SecureHandshakeMessage(type: .hello, mode: .pair, key: "not base64", nonce: nil)
        guard case .rejected(_, let error) = SecureChannelHost.accept(hello, storedSecret: { _ in nil }) else { return XCTFail() }
        XCTAssertEqual(error, .malformed)
    }

    func testEveryConnectionGetsFreshKeys() throws {
        var (a, _) = try handshake(client: .authenticate(deviceID: "d", secret: secret), hostSecret: secret)
        var (b, _) = try handshake(client: .authenticate(deviceID: "d", secret: secret), hostSecret: secret)
        XCTAssertNotEqual(try a.sending.seal(Data("same".utf8)), try b.sending.seal(Data("same".utf8)))
    }

    // MARK: Pinned wire

    func testHandshakeMessagesKeepTheirKeys() throws {
        let hello = SecureHandshakeMessage(type: .hello, mode: .authenticate, deviceID: "d", key: "k", nonce: "n")
        let object = try JSONSerialization.jsonObject(with: hello.encoded()) as! [String: String]
        XCTAssertEqual(object, ["type": "secure_hello", "mode": "authenticate", "deviceID": "d", "key": "k", "nonce": "n"])
        let reject = try JSONSerialization.jsonObject(with: SecureHandshakeMessage(type: .reject, error: "unknown_device").encoded()) as! [String: String]
        XCTAssertEqual(reject, ["type": "secure_reject", "error": "unknown_device"])
        XCTAssertEqual(SecureHandshakeMessage.parse(Data(#"{"type":"secure_accept","key":"a","nonce":"b","proof":"c"}"#.utf8))?.type, .accept)
        XCTAssertNil(SecureHandshakeMessage.parse(Data(#"{"type":"hello","deviceID":"d"}"#.utf8)))
    }

    /// The key schedule is the wire: another implementation (the Rust core, BEAM-88) has
    /// to produce these exact bytes from these inputs.
    func testKeySchedulePinned() throws {
        let clientKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let hostKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let schedule = try SecureChannel.schedule(
            mode: .authenticate, deviceID: "phone-1", secret: secret,
            agreement: clientKey.sharedSecretFromKeyAgreement(with: hostKey.publicKey),
            clientKey: clientKey.publicKey.rawRepresentation, clientNonce: Data(repeating: 3, count: 32),
            hostKey: hostKey.publicKey.rawRepresentation, hostNonce: Data(repeating: 4, count: 32)
        )
        func hex(_ key: SymmetricKey) -> String { key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(schedule.clientToHost), "666c36fb4546f7f7b583a53fa1fb337c529eaf66bc1f7aedbe5f4f00966189ee")
        XCTAssertEqual(hex(schedule.hostToClient), "9bfd722397ece61f1ed3a12183e9065d7526eb54b7ef4571ef082b0fa6707cea")
        XCTAssertEqual(hex(schedule.confirm), "1e198e8ae6ac532373002a3a5ee3097fedc31b1a8b7d16b999c49274869d0946")

        var cipher = FrameCipher(key: schedule.clientToHost)
        let sealed = try cipher.seal(Data("phoros".utf8))
        XCTAssertEqual(sealed.map { String(format: "%02x", $0) }.joined(), "d2ccd69a0f05681f92a2d4f3086058e6107d07829553")
    }
}
