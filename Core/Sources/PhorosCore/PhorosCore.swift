import Foundation
import PhorosCoreFFI

/// What the core wants done next.
public enum CorePoll: Equatable {
    case idle
    /// Send these bytes. The buffer is the core's; use it before the next call.
    case transmit(UnsafeRawBufferPointer)
    /// Poll again by this time (caller's clock, microseconds).
    case timeout(atMicros: Int64)

    public static func == (lhs: CorePoll, rhs: CorePoll) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.transmit(let a), .transmit(let b)): return a.count == b.count && a.baseAddress == b.baseAddress
        case (.timeout(let a), .timeout(let b)): return a == b
        default: return false
        }
    }
}

public enum CoreError: Int32, Error {
    case null = 1, tooLarge = 2, panic = 3, poisoned = 4, destroyed = 5, busy = 6
    case unknown = -1
}

public enum CoreEvent: Equatable {
    /// The core took `bytes` bytes.
    case fed(bytes: Int64)
    /// The handle is going away; `datagrams` were fed in its life.
    case destroying(datagrams: Int64)
}

/// One realtime core. Not thread-safe by contract: drive it from one queue, the way the
/// transport does. The core itself takes a lock, so misuse cannot corrupt it, only serialize.
public final class RealtimeCore {
    private var handle: OpaquePointer?
    private let box: Box
    public var onEvent: ((CoreEvent) -> Void)? {
        get { box.onEvent }
        set { box.onEvent = newValue }
    }

    private final class Box { var onEvent: ((CoreEvent) -> Void)? }

    public static var version: String { String(cString: phoros_core_version()) }
    public static var liveHandles: Int { phoros_core_live_handles() }

    public init() {
        box = Box()
        let user = Unmanaged.passUnretained(box).toOpaque()
        handle = phoros_core_create(user) { user, kind, value in
            guard let user else { return }
            let box = Unmanaged<Box>.fromOpaque(user).takeUnretainedValue()
            switch kind {
            case UInt32(PHOROS_EVENT_FED): box.onEvent?(.fed(bytes: value))
            case UInt32(PHOROS_EVENT_DESTROYING): box.onEvent?(.destroying(datagrams: value))
            default: break
            }
        }
    }

    deinit { destroy() }

    /// Idempotent. After it, every call throws `.destroyed`.
    public func destroy() {
        guard let handle else { return }
        self.handle = nil
        phoros_core_destroy(handle)
    }

    private func check(_ status: Int32) throws {
        guard status != Int32(PHOROS_OK) else { return }
        throw CoreError(rawValue: status) ?? .unknown
    }

    /// Bytes from the network. The core copies what it keeps before returning.
    public func feed(_ bytes: UnsafeRawBufferPointer, nowMicros: Int64) throws {
        guard let handle else { throw CoreError.destroyed }
        try check(phoros_core_feed(handle, bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, nowMicros))
    }

    /// `feed` for a `Data`, which costs the one copy Data makes to give a contiguous pointer
    /// (none when it is already contiguous).
    public func feed(_ data: Data, nowMicros: Int64) throws {
        try data.withUnsafeBytes { try feed($0, nowMicros: nowMicros) }
    }

    public func poll(nowMicros: Int64) throws -> CorePoll {
        guard let handle else { throw CoreError.destroyed }
        var out = PhorosPoll(kind: PhorosPollIdle, buffer: nil, len: 0, at_us: 0)
        try check(phoros_core_poll(handle, nowMicros, &out))
        switch out.kind {
        case PhorosPollTransmit: return .transmit(UnsafeRawBufferPointer(start: out.buffer, count: out.len))
        case PhorosPollTimeout: return .timeout(atMicros: out.at_us)
        default: return .idle
        }
    }

    /// Test hooks.
    public func _testPanic() -> Int32 {
        guard let handle else { return Int32(PHOROS_ERR_DESTROYED) }
        return phoros_core_test_panic(handle)
    }
}
