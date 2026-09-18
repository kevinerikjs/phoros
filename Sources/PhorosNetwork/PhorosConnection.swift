import Foundation
import Network
import Phoros

/// Why a `PhorosConnection` ended.
public enum PhorosConnectionEnd: Error, Sendable {
    /// The peer closed the connection.
    case closedByPeer
    /// The transport failed.
    case transportFailed(NWError)
    /// The peer sent something the framing cannot parse. See `FrameDecoderError`.
    case protocolViolation(FrameDecoderError)
    /// `cancel()` was called.
    case cancelled
}

/// One length-prefixed Phoros connection over Network.framework.
///
/// Wraps an `NWConnection` with the receive loop every peer otherwise
/// hand-writes: read a four-byte length, bound it, read the body, classify it
/// as a packet or a JSON message, repeat. Sends are ordinary writes with the
/// length prefix added.
///
/// ```swift
/// let link = PhorosConnection(to: endpoint)          // or PhorosConnection(accepting: incoming)
/// link.onFrame = { frame in … }
/// link.onEnd = { reason in … }
/// link.start()
/// link.send(Packet.encode(.control, payload: json))
/// ```
///
/// Callbacks arrive on `queue`. The connection does not interpret frames; pair
/// it with `PhorosSession` types or your own handling.
public final class PhorosConnection: @unchecked Sendable {
    /// Called for every complete frame.
    public var onFrame: ((Frame) -> Void)?
    /// Called once the transport is ready to send.
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

    public let connection: NWConnection
    private let queue: DispatchQueue
    private var ended = false

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
        maximumFrameLength: Int = 8 << 20,
        queue: DispatchQueue = DispatchQueue(label: "phoros.connection", qos: .userInteractive)
    ) {
        connection = NWConnection(to: endpoint, using: parameters)
        self.maximumFrameLength = maximumFrameLength
        self.queue = queue
    }

    /// An inbound connection handed over by an `NWListener`.
    public init(
        accepting connection: NWConnection,
        maximumFrameLength: Int = 8 << 20,
        queue: DispatchQueue = DispatchQueue(label: "phoros.connection", qos: .userInteractive)
    ) {
        self.connection = connection
        self.maximumFrameLength = maximumFrameLength
        self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.receiveLength()
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

    /// Sends one frame. `frame` is a packet or a bare JSON message; the length
    /// prefix is added here. `completion` runs when the transport has taken
    /// the bytes, with the error if it failed.
    public func send(_ frame: Data, completion: ((NWError?) -> Void)? = nil) {
        connection.send(content: frame.lengthPrefixed(), completion: .contentProcessed { error in
            completion?(error)
        })
    }

    // MARK: Receive loop

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: LengthPrefix.size, maximumLength: LengthPrefix.size) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { return self.end(.transportFailed(error)) }
            guard let data, let length = LengthPrefix.length(in: data) else {
                return self.end(.closedByPeer)
            }
            guard length <= self.maximumFrameLength else {
                return self.end(.protocolViolation(.frameTooLarge(announced: length, limit: self.maximumFrameLength)))
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
            do {
                self.onFrame?(try FrameDecoder.classify(data))
            } catch let violation as FrameDecoderError {
                return self.end(.protocolViolation(violation))
            } catch {
                return self.end(.closedByPeer)
            }
            self.receiveLength()
        }
    }

    private func end(_ reason: PhorosConnectionEnd) {
        guard !ended else { return }
        ended = true
        connection.cancel()
        onEnd?(reason)
    }
}
