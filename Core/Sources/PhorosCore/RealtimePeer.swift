import Foundation
import Network
import PhorosCoreFFI

public enum PeerEvent: Equatable {
    case connected
    case channelOpen(Int)
    case iceState(Int)
    case disconnected
}

/// One str0m peer: ICE (lite on the host), DTLS, SCTP and two data channels, reliable and
/// realtime. Either the caller owns the UDP socket and drives `feed`/`poll` (design A, here
/// with Network.framework), or the core binds its own and runs its own thread (design B).
public final class RealtimePeer {
    /// Every call takes this lock: destroy from one thread while another polls is a
    /// use-after-free otherwise. The core has its own lock inside; this one guards the handle.
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private let box: Box
    private final class Box {
        var onEvent: ((PeerEvent) -> Void)?
        var onData: ((Int, UnsafeRawBufferPointer) -> Void)?
    }
    public var onEvent: ((PeerEvent) -> Void)? { get { box.onEvent } set { box.onEvent = newValue } }
    /// Called with each message; the bytes are valid for the call only.
    public var onData: ((Int, UnsafeRawBufferPointer) -> Void)? { get { box.onData } set { box.onData = newValue } }

    public let localAddress: String
    public let isHost: Bool

    public init?(isHost: Bool, localAddress: String) {
        box = Box()
        self.localAddress = localAddress
        self.isHost = isHost
        let user = Unmanaged.passUnretained(box).toOpaque()
        handle = phoros_peer_create(user, { user, kind, value in
            guard let user else { return }
            let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
            switch kind {
            case UInt32(PHOROS_PEER_EVENT_CONNECTED): box.onEvent?(.connected)
            case UInt32(PHOROS_PEER_EVENT_CHANNEL_OPEN): box.onEvent?(.channelOpen(Int(value)))
            case UInt32(PHOROS_PEER_EVENT_ICE_STATE): box.onEvent?(.iceState(Int(value)))
            case UInt32(PHOROS_PEER_EVENT_DISCONNECTED): box.onEvent?(.disconnected)
            default: break
            }
        }, { user, channel, bytes, len in
            guard let user else { return }
            let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
            box.onData?(Int(channel), UnsafeRawBufferPointer(start: bytes, count: len))
        }, isHost, localAddress)
        if handle == nil { return nil }
    }

    deinit { destroy() }

    public func destroy() {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        self.handle = nil
        phoros_peer_destroy(handle)
    }

    /// "ufrag\npass\nfingerprint", what the bootstrap carries to the other side.
    public var localInfo: String {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return "" }
        var buffer = [CChar](repeating: 0, count: 512)
        let n = phoros_peer_local_info(handle, &buffer, buffer.count)
        return n > 0 ? String(cString: buffer) : ""
    }

    @discardableResult
    public func setRemote(info: String, address: String, nowMicros: Int64) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return Int32(PHOROS_ERR_DESTROYED) }
        return phoros_peer_set_remote(handle, info, address, nowMicros)
    }

    public func feed(_ bytes: UnsafeRawBufferPointer, from source: String?, nowMicros: Int64) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return Int32(PHOROS_ERR_DESTROYED) }
        return phoros_peer_feed(handle, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, source, nowMicros)
    }

    public func poll(nowMicros: Int64) -> CorePoll {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return .idle }
        var out = PhorosPoll(kind: PhorosPollIdle, buffer: nil, len: 0, at_us: 0)
        guard phoros_peer_poll(handle, nowMicros, &out) == Int32(PHOROS_OK) else { return .idle }
        switch out.kind {
        case PhorosPollTransmit: return .transmit(UnsafeRawBufferPointer(start: out.buffer, count: out.len))
        case PhorosPollTimeout: return .timeout(atMicros: out.at_us)
        default: return .idle
        }
    }

    @discardableResult
    public func send(channel: Int, _ bytes: UnsafeRawBufferPointer) -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return Int32(PHOROS_ERR_DESTROYED) }
        return phoros_peer_send(handle, UInt32(channel), bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    @discardableResult
    public func send(channel: Int, _ data: Data) -> Int32 {
        data.withUnsafeBytes { send(channel: channel, $0) }
    }

    /// Design B: the core binds `localAddress` and runs its own thread.
    @discardableResult
    public func runOwnSocket() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return Int32(PHOROS_ERR_DESTROYED) }
        return phoros_peer_run_own_socket(handle)
    }
}

/// Design A: Network.framework owns the UDP socket and feeds the peer. One connected
/// `NWConnection` to the remote address; the peer's transmits go out on it, its receives go
/// in. Everything on one queue, the way a transport would do it.
public final class NetworkDrivenPeer {
    public let peer: RealtimePeer
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?
    private let remote: String
    private let start = DispatchTime.now().uptimeNanoseconds

    private var nowMicros: Int64 { Int64((DispatchTime.now().uptimeNanoseconds - start) / 1000) }

    public init(peer: RealtimePeer, remoteHost: String, remotePort: UInt16, localPort: UInt16, serviceClass: NWParameters.ServiceClass? = nil, queue: DispatchQueue) {
        self.peer = peer
        self.queue = queue
        self.remote = "\(remoteHost):\(remotePort)"
        let parameters = NWParameters.udp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: localPort)!)
        parameters.allowLocalEndpointReuse = true
        if let serviceClass { parameters.serviceClass = serviceClass }
        connection = NWConnection(host: NWEndpoint.Host(remoteHost), port: NWEndpoint.Port(rawValue: remotePort)!, using: parameters)
    }

    public func start(remoteInfo: String) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            self.peer.setRemote(info: remoteInfo, address: self.remote, nowMicros: self.nowMicros)
            self.receive()
            self.pump()
        }
        connection.start(queue: queue)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(5), leeway: .microseconds(200))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        timer = t
    }

    /// Stops on the peer's own queue, so no poll is running when the handle goes away.
    public func stop() {
        queue.sync {
            timer?.cancel(); timer = nil
            connection.cancel()
            peer.destroy()
        }
    }

    /// Sends on the peer's queue and pumps at once, so the transmit does not wait for the
    /// next timer.
    public func send(channel: Int, _ data: Data) {
        queue.async { [self] in
            _ = peer.send(channel: channel, data)
            pump()
        }
    }

    /// Runs the state machine until it asks for a timeout, sending every transmit, then
    /// arms the timer for exactly when str0m wants to run again.
    public func pump() {
        while true {
            switch peer.poll(nowMicros: nowMicros) {
            case .transmit(let buffer):
                connection.send(content: Data(buffer), completion: .contentProcessed { _ in })
            case .timeout(let at):
                let delay = max(100, at - nowMicros)
                timer?.schedule(deadline: .now() + .microseconds(Int(delay)), leeway: .microseconds(200))
                return
            case .idle:
                return
            }
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data {
                data.withUnsafeBytes { _ = self.peer.feed($0, from: self.remote, nowMicros: self.nowMicros) }
                self.pump()
            }
            self.receive()
        }
    }
}
