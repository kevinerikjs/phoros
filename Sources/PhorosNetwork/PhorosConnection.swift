import Foundation
import Network
import Phoros
import PhorosSession

/// Why a `PhorosConnection` ended.
public enum PhorosConnectionEnd: Error, Sendable {
    /// The peer closed the connection.
    case closedByPeer
    /// The transport failed.
    case transportFailed(NWError)
    /// The peer sent something the framing cannot parse. See `FrameDecoderError`.
    case protocolViolation(FrameDecoderError)
    /// The encrypted handshake failed, or a sealed frame did not open. See `SecureChannelError`.
    case secureChannelFailed(SecureChannelError)
    /// `cancel()` was called.
    case cancelled
}

/// Whether a connection is encrypted, and how. See `SecureChannel`.
public enum PhorosConnectionSecurity: Sendable {
    /// The plaintext wire every peer before Phoros 1.7 speaks.
    case none
    /// Client: open with `secure_hello`. Use only with a host that advertised
    /// `supportsEncryption`; an older host ignores the hello and the connection
    /// times out with `.secureChannelFailed(.timedOut)`.
    case client(SecureChannelClient.Mode)
    /// Host: answer a `secure_hello` if the first frame is one. A first frame that is
    /// anything else is an older client on the plaintext wire, served only when
    /// `allowsPlaintext`.
    case host(storedSecret: @Sendable (String) -> SharedSecret?, allowsPlaintext: Bool)
}

/// One length-prefixed Phoros connection over Network.framework.
///
/// Wraps an `NWConnection` with the receive loop every peer otherwise
/// hand-writes: read a four-byte length, bound it, read the body, classify it
/// as a packet or a JSON message, repeat. Sends are ordinary writes with the
/// length prefix added.
///
/// ```swift
/// let link = PhorosConnection(to: endpoint, security: .client(.authenticate(deviceID: id, secret: secret)))
/// link.onFrame = { frame in … }
/// link.onEnd = { reason in … }
/// link.start()
/// link.send(Packet.encode(.control, payload: json))
/// ```
///
/// With `security` set, the connection runs the `SecureChannel` handshake before
/// `onReady` and seals every frame after it. Frames and callbacks look the same
/// either way. Callbacks arrive on `queue`. The connection does not interpret
/// frames; pair it with `PhorosSession` types or your own handling.
public final class PhorosConnection: @unchecked Sendable {
    /// Called for every complete frame.
    public var onFrame: ((Frame) -> Void)?
    /// Called once the connection is ready to send: after the encrypted handshake
    /// on a secure connection, after the first frame on a host that also serves
    /// plaintext.
    public var onReady: (() -> Void)?
    /// Called when the transport has no route right now. `NWConnection` waits
    /// here indefinitely rather than failing, so a caller that wants a retry
    /// loop to advance should start a timer here and `cancel()` if it expires.
    public var onWaiting: ((NWError) -> Void)?
    /// Called once, when the connection ends for any reason.
    public var onEnd: ((PhorosConnectionEnd) -> Void)?

    /// Largest frame accepted from the peer. Anything larger ends the
    /// connection with `protocolViolation`.
    public let maximumFrameLength: Int

    /// Seconds a client waits for `secure_accept`.
    public var handshakeTimeout: TimeInterval = 10

    public let connection: NWConnection
    public let security: PhorosConnectionSecurity
    private let queue: DispatchQueue
    private var ended = false

    private enum Phase {
        case plaintext
        case clientHandshake(SecureChannelClient)
        case hostFirstFrame
        case sealed
    }
    /// Receive side, connection queue only.
    private var phase: Phase = .plaintext
    private var receiving: FrameCipher?
    private var handshakeTimer: DispatchSourceTimer?

    /// Send side. Frames are sealed with a counter nonce, so sealing and handing
    /// the bytes to the connection happen together under this lock, in order.
    private let sendLock = NSLock()
    private var sending: FrameCipher?
    private var holdsSends = false
    private var heldSends: [(Data, ((NWError?) -> Void)?)] = []

    private let stateLock = NSLock()
    private var _isEncrypted = false
    private var _secureDeviceID: String?

    /// Whether frames on this connection are sealed. Final once `onReady` has fired.
    public var isEncrypted: Bool { stateLock.withLock { _isEncrypted } }
    /// On an encrypted connection in `.authenticate` mode, the device whose
    /// secret the keys were derived from. A host should reject an `authRequest`
    /// for any other device on this connection.
    public var secureDeviceID: String? { stateLock.withLock { _secureDeviceID } }

    /// An outbound connection.
    /// TCP tuned for a live stream: Nagle off, so a 14-byte controller report
    /// or the last fragment of a frame is never held back waiting for an ACK,
    /// and the interactive-video service class. Use these for the listener
    /// on the host and for the outbound connection on the client.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    public init(
        to endpoint: NWEndpoint,
        parameters: NWParameters = PhorosConnection.parameters(),
        security: PhorosConnectionSecurity = .none,
        maximumFrameLength: Int = 8 << 20,
        queue: DispatchQueue = DispatchQueue(label: "phoros.connection", qos: .userInteractive)
    ) {
        connection = NWConnection(to: endpoint, using: parameters)
        self.security = security
        self.maximumFrameLength = maximumFrameLength
        self.queue = queue
    }

    /// An inbound connection handed over by an `NWListener`.
    public init(
        accepting connection: NWConnection,
        security: PhorosConnectionSecurity = .none,
        maximumFrameLength: Int = 8 << 20,
        queue: DispatchQueue = DispatchQueue(label: "phoros.connection", qos: .userInteractive)
    ) {
        self.connection = connection
        self.security = security
        self.maximumFrameLength = maximumFrameLength
        self.queue = queue
    }

    public func start() {
        switch security {
        case .none: break
        case .client, .host: sendLock.withLock { holdsSends = true }
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.becameReady()
            case .waiting(let error):
                self.onWaiting?(error)
            case .failed(let error):
                self.end(.transportFailed(error))
            case .cancelled:
                self.end(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        connection.cancel()
    }

    private func becameReady() {
        switch security {
        case .none:
            phase = .plaintext
            onReady?()
        case .client(let mode):
            let client = SecureChannelClient(mode: mode)
            phase = .clientHandshake(client)
            connection.send(content: client.hello().encoded().lengthPrefixed(), completion: .contentProcessed { _ in })
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + handshakeTimeout)
            timer.setEventHandler { [weak self] in self?.end(.secureChannelFailed(.timedOut)) }
            timer.resume()
            handshakeTimer = timer
        case .host:
            phase = .hostFirstFrame
        }
        receiveLength()
    }

    /// Sends one frame. `frame` is a packet or a bare JSON message; the length
    /// prefix is added here, and the frame is sealed on an encrypted connection.
    /// `completion` runs when the transport has taken the bytes, with the error
    /// if it failed.
    public func send(_ frame: Data, completion: ((NWError?) -> Void)? = nil) {
        sendLock.lock()
        defer { sendLock.unlock() }
        if holdsSends {
            heldSends.append((frame, completion))
            return
        }
        writeLocked(frame, completion: completion)
    }

    /// Sends bytes that already hold one or more length-prefixed frames, as a
    /// single write. On an encrypted connection each frame is sealed and
    /// re-prefixed. Returns the number of bytes handed to the transport.
    @discardableResult
    public func sendFramed(_ framed: Data, completion: @escaping (NWError?) -> Void) -> Int {
        sendLock.lock()
        defer { sendLock.unlock() }
        guard sending != nil || holdsSends else {
            connection.send(content: framed, completion: .contentProcessed(completion))
            return framed.count
        }
        let frames = Self.split(framed)
        if holdsSends {
            for (index, frame) in frames.enumerated() {
                heldSends.append((frame, index == frames.count - 1 ? completion : nil))
            }
            return framed.count + frames.count * FrameCipher.overhead
        }
        var out = Data(capacity: framed.count + frames.count * FrameCipher.overhead)
        for frame in frames {
            guard let sealed = sealLocked(frame) else { return 0 }
            out.append(sealed.lengthPrefixed())
        }
        connection.send(content: out, completion: .contentProcessed(completion))
        return out.count
    }

    /// Caller holds `sendLock`.
    private func writeLocked(_ frame: Data, completion: ((NWError?) -> Void)?) {
        let body: Data
        if sending != nil {
            guard let sealed = sealLocked(frame) else { return }
            body = sealed
        } else {
            body = frame
        }
        connection.send(content: body.lengthPrefixed(), completion: .contentProcessed { error in
            completion?(error)
        })
    }

    /// Caller holds `sendLock`.
    private func sealLocked(_ frame: Data) -> Data? {
        guard var cipher = sending else { return frame }
        defer { sending = cipher }
        return try? cipher.seal(frame)
    }

    /// Stops holding sends. `keys` nil leaves the connection plaintext.
    private func releaseSends(sealingWith cipher: FrameCipher?) {
        sendLock.lock()
        defer { sendLock.unlock() }
        sending = cipher
        holdsSends = false
        let held = heldSends
        heldSends = []
        for (frame, completion) in held { writeLocked(frame, completion: completion) }
    }

    private static func split(_ framed: Data) -> [Data] {
        var frames: [Data] = []
        var index = framed.startIndex
        while framed.endIndex - index >= LengthPrefix.size,
              let length = LengthPrefix.length(in: framed[index...]) {
            let start = index + LengthPrefix.size
            let end = start + Int(length)
            guard end <= framed.endIndex else { break }
            frames.append(Data(framed[start..<end]))
            index = end
        }
        return frames
    }

    // MARK: Receive loop

    private var receiveLimit: Int {
        if case .plaintext = phase { return maximumFrameLength }
        return maximumFrameLength + FrameCipher.overhead
    }

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: LengthPrefix.size, maximumLength: LengthPrefix.size) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { return self.end(.transportFailed(error)) }
            guard let data, let length = LengthPrefix.length(in: data) else {
                return self.end(.closedByPeer)
            }
            guard length <= self.receiveLimit else {
                return self.end(.protocolViolation(.frameTooLarge(announced: length, limit: self.receiveLimit)))
            }
            if length == 0 {
                self.receiveLength()
                return
            }
            self.receiveBody(Int(length))
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { return self.end(.transportFailed(error)) }
            guard let data, data.count == length else { return self.end(.closedByPeer) }
            guard self.handleBody(data) else { return }
            self.receiveLength()
        }
    }

    /// `false` once the connection has ended.
    private func handleBody(_ data: Data) -> Bool {
        switch phase {
        case .plaintext:
            return deliver(data)
        case .sealed:
            guard var cipher = receiving else { return false }
            do {
                let opened = try cipher.open(data)
                receiving = cipher
                return deliver(opened)
            } catch {
                end(.secureChannelFailed(.integrity))
                return false
            }
        case .clientHandshake(let client):
            handshakeTimer?.cancel(); handshakeTimer = nil
            guard let reply = SecureHandshakeMessage.parse(data) else {
                end(.secureChannelFailed(.malformed))
                return false
            }
            do {
                let keys = try client.finish(reply)
                enterSealed(keys)
                onReady?()
                return !ended
            } catch let error as SecureChannelError {
                end(.secureChannelFailed(error))
                return false
            } catch {
                end(.secureChannelFailed(.malformed))
                return false
            }
        case .hostFirstFrame:
            guard case .host(let storedSecret, let allowsPlaintext) = security else { return false }
            if let hello = SecureHandshakeMessage.parse(data), hello.type == .hello {
                switch SecureChannelHost.accept(hello, storedSecret: storedSecret) {
                case .accepted(let reply, let keys):
                    // The accept goes out in the clear, ahead of anything held.
                    connection.send(content: reply.encoded().lengthPrefixed(), completion: .contentProcessed { _ in })
                    enterSealed(keys)
                    onReady?()
                    return !ended
                case .rejected(let reply, let error):
                    // End once the reject has left, so the client can tell "pair again" from a drop.
                    connection.send(content: reply.encoded().lengthPrefixed(), completion: .contentProcessed { [weak self] _ in
                        self?.queue.async { self?.end(.secureChannelFailed(error)) }
                    })
                    return false
                }
            }
            guard allowsPlaintext else {
                end(.secureChannelFailed(.plaintextRefused))
                return false
            }
            phase = .plaintext
            releaseSends(sealingWith: nil)
            onReady?()
            return deliver(data)
        }
    }

    private func enterSealed(_ keys: SecureChannelKeys) {
        phase = .sealed
        receiving = keys.receiving
        stateLock.withLock {
            _isEncrypted = true
            _secureDeviceID = keys.deviceID
        }
        releaseSends(sealingWith: keys.sending)
    }

    private func deliver(_ data: Data) -> Bool {
        do {
            onFrame?(try FrameDecoder.classify(data))
        } catch let violation as FrameDecoderError {
            end(.protocolViolation(violation))
            return false
        } catch {
            end(.closedByPeer)
            return false
        }
        return !ended
    }

    private func end(_ reason: PhorosConnectionEnd) {
        guard !ended else { return }
        ended = true
        handshakeTimer?.cancel(); handshakeTimer = nil
        connection.cancel()
        onEnd?(reason)
    }
}
