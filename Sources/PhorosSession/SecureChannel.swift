import CryptoKit
import Foundation
import Phoros

// An encrypted Phoros connection.
//
// The first frame a client sends is `secure_hello`, in the clear. The host answers with
// `secure_accept` (or `secure_reject`), also in the clear. Every frame after that, in both
// directions, is sealed with AES-256-GCM. Inside it the session runs exactly as on the
// plaintext wire: hello, code_verify, auth_request and everything after.
//
// Keys come from an X25519 exchange (fresh on every connection, so a recorded session stays
// unreadable even if the pairing secret leaks later) mixed with the pairing secret when the
// client is already paired. A host that does not hold the secret derives different keys and
// cannot produce `proof`, so the client learns before it sends anything that it is talking
// to the Mac it paired with. A client without the secret cannot produce a single frame the
// host can open.
//
// Pairing itself (no secret yet) gets the X25519 exchange only. That stops anyone listening
// on the network, who could previously read the secret straight out of `pair_success`. It
// does not stop an attacker who sits in the middle of the connection during the pairing
// minute; that needs a PAKE and is documented in SECURITY.md.

/// What the client is doing on this connection.
public enum SecureChannelMode: String, Codable, Sendable {
    /// Pairing: no secret exists yet.
    case pair
    /// A paired client coming back. Its secret goes into the keys.
    case authenticate
}

/// Why the handshake did not produce a channel.
public enum SecureChannelError: Error, Equatable, Sendable {
    /// The host does not know this device. Pair again.
    case unknownDevice
    /// The host refused for another reason, in its words.
    case rejected(String)
    /// The host's proof did not verify: it does not hold this device's secret.
    case hostNotAuthenticated
    /// A handshake message was missing a field or had a bad key.
    case malformed
    /// No answer from the host in time.
    case timedOut
    /// The client spoke plaintext to a host that requires encryption.
    case plaintextRefused
    /// A sealed frame did not open. The connection ends.
    case integrity
}

/// `secure_hello`, `secure_accept` and `secure_reject`. JSON, sent as a bare frame.
public struct SecureHandshakeMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case hello = "secure_hello"
        case accept = "secure_accept"
        case reject = "secure_reject"
    }

    public var type: Kind
    /// Hello only.
    public var mode: SecureChannelMode?
    /// Hello in `.authenticate` mode: which secret to use.
    public var deviceID: String?
    /// X25519 public key, base64.
    public var key: String?
    /// 32 random bytes, base64.
    public var nonce: String?
    /// Accept only: HMAC proving the host derived the same keys, base64.
    public var proof: String?
    /// Reject only. `unknown_device`, or a reason safe to show.
    public var error: String?

    public init(type: Kind, mode: SecureChannelMode? = nil, deviceID: String? = nil, key: String? = nil,
                nonce: String? = nil, proof: String? = nil, error: String? = nil) {
        self.type = type
        self.mode = mode
        self.deviceID = deviceID
        self.key = key
        self.nonce = nonce
        self.proof = proof
        self.error = error
    }

    public static let unknownDeviceError = "unknown_device"

    /// A handshake message, or `nil` for any other frame.
    public static func parse(_ frame: Data) -> SecureHandshakeMessage? {
        try? JSONDecoder().decode(SecureHandshakeMessage.self, from: frame)
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }
}

/// One direction of a sealed connection. AES-256-GCM, a 96-bit nonce that is a frame
/// counter (the connection is ordered, so it is never sent), and a 16-byte tag appended to
/// every frame. Not thread-safe: seal from one place, open from one place.
public struct FrameCipher: Sendable {
    public static let overhead = 16

    private let key: SymmetricKey
    public private(set) var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    private mutating func nextNonce() throws -> AES.GCM.Nonce {
        var bytes = Data(count: 4)
        bytes.appendSecureBigEndian(counter)
        counter += 1
        return try AES.GCM.Nonce(data: bytes)
    }

    /// `plaintext` sealed: ciphertext followed by the tag.
    public mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nextNonce())
        var sealed = Data(capacity: plaintext.count + Self.overhead)
        sealed.append(box.ciphertext)
        sealed.append(box.tag)
        return sealed
    }

    /// Opens the next frame. Throws `SecureChannelError.integrity` on any mismatch,
    /// including a frame that was replayed, reordered or dropped.
    public mutating func open(_ sealed: Data) throws -> Data {
        guard sealed.count >= Self.overhead else { throw SecureChannelError.integrity }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: nextNonce(),
                ciphertext: sealed.prefix(sealed.count - Self.overhead),
                tag: sealed.suffix(Self.overhead)
            )
            return try AES.GCM.open(box, using: key)
        } catch {
            throw SecureChannelError.integrity
        }
    }
}

/// The result of a handshake: one cipher per direction.
public struct SecureChannelKeys: Sendable {
    public var sending: FrameCipher
    public var receiving: FrameCipher
    public let mode: SecureChannelMode
    /// The device whose secret went into the keys. `nil` when pairing.
    public let deviceID: String?
}

/// The client side of the handshake.
public struct SecureChannelClient: Sendable {
    public enum Mode: Sendable {
        case pair
        case authenticate(deviceID: String, secret: SharedSecret)
    }

    public let mode: Mode
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey
    private let nonce: Data

    public init(mode: Mode) {
        self.mode = mode
        ephemeral = Curve25519.KeyAgreement.PrivateKey()
        nonce = SecureChannel.randomBytes(32)
    }

    /// The first frame to send.
    public func hello() -> SecureHandshakeMessage {
        switch mode {
        case .pair:
            return SecureHandshakeMessage(type: .hello, mode: .pair, key: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                                          nonce: nonce.base64EncodedString())
        case .authenticate(let deviceID, _):
            return SecureHandshakeMessage(type: .hello, mode: .authenticate, deviceID: deviceID,
                                          key: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                                          nonce: nonce.base64EncodedString())
        }
    }

    /// Reads the host's answer. Returns the keys, or throws why there are none.
    public func finish(_ reply: SecureHandshakeMessage) throws -> SecureChannelKeys {
        switch reply.type {
        case .reject:
            if reply.error == SecureHandshakeMessage.unknownDeviceError { throw SecureChannelError.unknownDevice }
            throw SecureChannelError.rejected(reply.error ?? "Encrypted connection refused")
        case .hello:
            throw SecureChannelError.malformed
        case .accept:
            break
        }
        guard let hostKeyData = reply.key.flatMap({ Data(base64Encoded: $0) }),
              let hostKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostKeyData),
              let hostNonce = reply.nonce.flatMap({ Data(base64Encoded: $0) }), hostNonce.count == 32,
              let proof = reply.proof.flatMap({ Data(base64Encoded: $0) })
        else { throw SecureChannelError.malformed }

        let (deviceID, secret): (String?, SharedSecret?) = {
            if case .authenticate(let id, let secret) = mode { return (id, secret) }
            return (nil, nil)
        }()
        let schedule = try SecureChannel.schedule(
            mode: deviceID == nil ? .pair : .authenticate, deviceID: deviceID, secret: secret,
            agreement: ephemeral.sharedSecretFromKeyAgreement(with: hostKey),
            clientKey: ephemeral.publicKey.rawRepresentation, clientNonce: nonce,
            hostKey: hostKeyData, hostNonce: hostNonce
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: SecureChannel.hostProofLabel, using: schedule.confirm) else {
            throw SecureChannelError.hostNotAuthenticated
        }
        return SecureChannelKeys(sending: FrameCipher(key: schedule.clientToHost), receiving: FrameCipher(key: schedule.hostToClient),
                                 mode: deviceID == nil ? .pair : .authenticate, deviceID: deviceID)
    }
}

/// The host side of the handshake.
public enum SecureChannelHost {
    public enum Outcome: Sendable {
        /// Send `reply` in the clear, then seal everything with `keys`.
        case accepted(reply: SecureHandshakeMessage, keys: SecureChannelKeys)
        /// Send `reply` in the clear and close.
        case rejected(reply: SecureHandshakeMessage, error: SecureChannelError)
    }

    /// Answers a `secure_hello`. `storedSecret` looks up a paired device's secret.
    public static func accept(_ hello: SecureHandshakeMessage, storedSecret: (String) -> SharedSecret?) -> Outcome {
        guard hello.type == .hello, let mode = hello.mode,
              let clientKeyData = hello.key.flatMap({ Data(base64Encoded: $0) }),
              let clientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientKeyData),
              let clientNonce = hello.nonce.flatMap({ Data(base64Encoded: $0) }), clientNonce.count == 32
        else {
            return .rejected(reply: SecureHandshakeMessage(type: .reject, error: "Malformed encrypted hello"), error: .malformed)
        }
        var secret: SharedSecret?
        if mode == .authenticate {
            guard let deviceID = hello.deviceID, let stored = storedSecret(deviceID) else {
                return .rejected(reply: SecureHandshakeMessage(type: .reject, error: SecureHandshakeMessage.unknownDeviceError),
                                 error: .unknownDevice)
            }
            secret = stored
        }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hostNonce = SecureChannel.randomBytes(32)
        do {
            let deviceID = mode == .authenticate ? hello.deviceID : nil
            let schedule = try SecureChannel.schedule(
                mode: mode, deviceID: deviceID, secret: secret,
                agreement: ephemeral.sharedSecretFromKeyAgreement(with: clientKey),
                clientKey: clientKeyData, clientNonce: clientNonce,
                hostKey: ephemeral.publicKey.rawRepresentation, hostNonce: hostNonce
            )
            let proof = Data(HMAC<SHA256>.authenticationCode(for: SecureChannel.hostProofLabel, using: schedule.confirm))
            let reply = SecureHandshakeMessage(type: .accept, key: ephemeral.publicKey.rawRepresentation.base64EncodedString(),
                                               nonce: hostNonce.base64EncodedString(), proof: proof.base64EncodedString())
            let keys = SecureChannelKeys(sending: FrameCipher(key: schedule.hostToClient), receiving: FrameCipher(key: schedule.clientToHost),
                                         mode: mode, deviceID: deviceID)
            return .accepted(reply: reply, keys: keys)
        } catch {
            return .rejected(reply: SecureHandshakeMessage(type: .reject, error: "Malformed encrypted hello"), error: .malformed)
        }
    }
}

enum SecureChannel {
    static let label = Data("phoros-secure/1".utf8)
    static let hostProofLabel = Data("phoros-secure/1 host".utf8)

    struct Schedule {
        var clientToHost: SymmetricKey
        var hostToClient: SymmetricKey
        var confirm: SymmetricKey
    }

    /// HKDF-SHA256 over the X25519 result and, when authenticating, the pairing secret,
    /// salted with a hash of everything both sides said.
    static func schedule(
        mode: SecureChannelMode, deviceID: String?, secret: SharedSecret?,
        agreement: SharedSecret_X25519, clientKey: Data, clientNonce: Data, hostKey: Data, hostNonce: Data
    ) throws -> Schedule {
        var transcript = label
        transcript.append(Data(mode.rawValue.utf8))
        let id = Data((deviceID ?? "").utf8)
        transcript.appendSecureBigEndian(UInt32(id.count))
        transcript.append(id)
        transcript.append(clientKey)
        transcript.append(clientNonce)
        transcript.append(hostKey)
        transcript.append(hostNonce)

        var input = agreement.withUnsafeBytes { Data($0) }
        if let secret { input.append(secret.bytes) }
        let output = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: Data(SHA256.hash(data: transcript)),
            info: label + Data(" keys".utf8),
            outputByteCount: 96
        ).withUnsafeBytes { Data($0) }
        return Schedule(
            clientToHost: SymmetricKey(data: output.prefix(32)),
            hostToClient: SymmetricKey(data: output.dropFirst(32).prefix(32)),
            confirm: SymmetricKey(data: output.suffix(32))
        )
    }

    static func randomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

typealias SharedSecret_X25519 = CryptoKit.SharedSecret

private extension Data {
    mutating func appendSecureBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
