import Foundation

/// Tunables for `BitrateController`.
public struct BitrateControllerPolicy: Equatable, Sendable {
    /// The controller never goes below this, whatever the link says.
    public var minimumBitrate: Int
    /// Queueing delay (round trip minus its recent floor) above which the
    /// link is judged to be holding video back.
    public var congestedAbove: TimeInterval
    /// Queueing delay below which the link is judged to have room.
    public var clearBelow: TimeInterval
    /// Multiplied into the bitrate on a congested verdict.
    public var decreaseFactor: Double
    /// Multiplied into the bitrate on a clear verdict.
    public var increaseFactor: Double
    /// Two decreases are at least this far apart: the link needs time to
    /// drain what the old rate queued before the delay can show the effect.
    public var decreaseInterval: TimeInterval
    /// The link must read clear for this long before one increase.
    public var increaseInterval: TimeInterval
    /// Round trips older than this no longer count toward the floor.
    public var floorWindow: TimeInterval

    public init(
        minimumBitrate: Int = 1_000_000,
        congestedAbove: TimeInterval = 0.020,
        clearBelow: TimeInterval = 0.008,
        decreaseFactor: Double = 0.7,
        increaseFactor: Double = 1.1,
        decreaseInterval: TimeInterval = 0.3,
        increaseInterval: TimeInterval = 2,
        floorWindow: TimeInterval = 20
    ) {
        self.minimumBitrate = minimumBitrate
        self.congestedAbove = congestedAbove
        self.clearBelow = clearBelow
        self.decreaseFactor = decreaseFactor
        self.increaseFactor = increaseFactor
        self.decreaseInterval = decreaseInterval
        self.increaseInterval = increaseInterval
        self.floorWindow = floorWindow
    }
}

/// Sets the video bitrate from what the link is doing, not from what the
/// peer reports.
///
/// The transport is a byte stream. When the encoder produces more than the
/// link carries, nothing is lost: the bytes wait in the sender's socket
/// buffer, then in the access point, and every frame arrives late by that
/// much. The peer sees a smooth stream and reports it healthy. The one
/// signal that does show the queue is the round trip of a small control
/// message sent on the same connection, because it waits behind the same
/// bytes. This controller keeps a floor of recent round trips, reads the
/// excess over that floor as queueing delay, and steps the bitrate down
/// fast and up slowly. Multiplicative decrease, small multiplicative
/// increase, both rate limited.
///
/// Feed it every round trip with `observe(roundTrip:now:)`, then ask
/// `evaluate(now:)` for a new bitrate. `maximum` is the preset's bitrate;
/// the controller only ever sits between `policy.minimumBitrate` and that.
public struct BitrateController: Sendable {
    public var policy: BitrateControllerPolicy

    /// The ceiling, normally the active preset's bitrate.
    public private(set) var maximum: Int
    /// The bitrate the controller currently wants.
    public private(set) var current: Int
    /// Round trip minus the recent floor, from the last observation.
    public private(set) var queueDelay: TimeInterval = 0
    /// The recent floor of the round trip: propagation, no queue.
    public private(set) var floor: TimeInterval?

    private var samples: [(at: Date, roundTrip: TimeInterval)] = []
    private var lastDecrease = Date.distantPast
    private var clearSince: Date?
    private var congested = false
    private var previousQueueDelay: TimeInterval = 0

    public init(maximum: Int, policy: BitrateControllerPolicy = BitrateControllerPolicy()) {
        self.policy = policy
        self.maximum = maximum
        self.current = maximum
    }

    /// A new ceiling, for a preset change. The current bitrate follows it
    /// down and is not raised above it.
    public mutating func setMaximum(_ bitrate: Int) {
        maximum = bitrate
        current = min(current, maximum)
    }

    /// One measured round trip of a control message on the media connection.
    public mutating func observe(roundTrip: TimeInterval, now: Date = Date()) {
        samples.append((now, roundTrip))
        let cutoff = now.addingTimeInterval(-policy.floorWindow)
        samples.removeAll { $0.at < cutoff }
        let floor = samples.map(\.roundTrip).min() ?? roundTrip
        self.floor = floor
        previousQueueDelay = queueDelay
        queueDelay = max(0, roundTrip - floor)
        if queueDelay > policy.congestedAbove {
            // A queue that is already draining needs no second cut: the last
            // one is working, and cutting again on the same backlog ends far
            // below what the link carries. Cut when the delay holds or grows.
            congested = queueDelay >= previousQueueDelay * 0.9
            clearSince = nil
        } else if queueDelay < policy.clearBelow {
            if clearSince == nil { clearSince = now }
        } else {
            clearSince = nil
        }
    }

    /// The bitrate to apply now, or `nil` when it has not changed. Call after
    /// each observation, or on a timer.
    public mutating func evaluate(now: Date = Date()) -> Int? {
        if congested {
            congested = false
            guard now.timeIntervalSince(lastDecrease) >= policy.decreaseInterval else { return nil }
            let next = max(policy.minimumBitrate, Int(Double(current) * policy.decreaseFactor))
            lastDecrease = now
            guard next != current else { return nil }
            current = next
            return current
        }
        if let clearSince, now.timeIntervalSince(clearSince) >= policy.increaseInterval, current < maximum {
            self.clearSince = now
            let next = min(maximum, max(current + 1, Int(Double(current) * policy.increaseFactor)))
            current = next
            return current
        }
        return nil
    }

    /// Forget the link: a new connection has a new floor.
    public mutating func reset() {
        samples.removeAll()
        floor = nil
        queueDelay = 0
        congested = false
        clearSince = nil
        lastDecrease = .distantPast
        current = maximum
    }
}
