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
    /// Where a new link starts, if the ceiling is above it. The link's
    /// capacity is unknown until the first round trips, and a queue built
    /// in the first second takes many seconds to drain. Zero starts at the
    /// ceiling.
    public var initialBitrate: Int
    /// Multiplied into the bitrate on a clear verdict before the first
    /// congestion verdict, and how often. Slow start: the link has shown no
    /// limit yet, so climb fast.
    public var startFactor: Double
    public var startInterval: TimeInterval
    /// Queueing delay above which one cut halves the rate instead of
    /// taking `decreaseFactor`: the queue is already seconds of video and
    /// every step spent on the way down is another second of it.
    public var severeAbove: TimeInterval
    /// Congested samples in a row before a cut. Wi-Fi shows single round
    /// trips of 30 to 50 ms with nothing queued (a scan, a retry); one
    /// sample is a spike, two are a queue.
    public var samplesBeforeCut: Int
    /// A high round trip counts as congestion only when the transport held
    /// at least this many unsent or unacknowledged bytes at the time. A
    /// radio that sleeps between packets or an access point that scans
    /// delays a ping just as much as a queue does, but leaves nothing
    /// waiting on the sender; cutting the bitrate then costs quality and
    /// buys nothing. Zero counts every high round trip.
    public var backlogForCongestion: Int

    public init(
        minimumBitrate: Int = 1_000_000,
        congestedAbove: TimeInterval = 0.020,
        clearBelow: TimeInterval = 0.008,
        decreaseFactor: Double = 0.7,
        increaseFactor: Double = 1.15,
        decreaseInterval: TimeInterval = 0.3,
        increaseInterval: TimeInterval = 2,
        floorWindow: TimeInterval = 20,
        initialBitrate: Int = 4_000_000,
        startFactor: Double = 1.5,
        startInterval: TimeInterval = 0.6,
        severeAbove: TimeInterval = 0.15,
        samplesBeforeCut: Int = 2,
        backlogForCongestion: Int = 8 * 1024
    ) {
        self.minimumBitrate = minimumBitrate
        self.congestedAbove = congestedAbove
        self.clearBelow = clearBelow
        self.decreaseFactor = decreaseFactor
        self.increaseFactor = increaseFactor
        self.decreaseInterval = decreaseInterval
        self.increaseInterval = increaseInterval
        self.floorWindow = floorWindow
        self.initialBitrate = initialBitrate
        self.startFactor = startFactor
        self.startInterval = startInterval
        self.severeAbove = severeAbove
        self.samplesBeforeCut = samplesBeforeCut
        self.backlogForCongestion = backlogForCongestion
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
    private var everCongested = false
    private var congestedRun = 0

    public init(maximum: Int, policy: BitrateControllerPolicy = BitrateControllerPolicy()) {
        self.policy = policy
        self.maximum = maximum
        self.current = policy.initialBitrate > 0 ? min(maximum, max(policy.minimumBitrate, policy.initialBitrate)) : maximum
    }

    /// A new ceiling, for a preset change. The current bitrate follows it
    /// down and is not raised above it.
    public mutating func setMaximum(_ bitrate: Int) {
        maximum = bitrate
        current = min(current, maximum)
    }

    /// One measured round trip of a control message on the media connection.
    /// `transportBacklog` is what the transport held when the ping went out
    /// (the kernel's unacknowledged bytes on TCP); pass `Int.max` when the
    /// transport cannot say, and every high round trip counts.
    public mutating func observe(roundTrip: TimeInterval, transportBacklog: Int = Int.max, now: Date = Date()) {
        samples.append((now, roundTrip))
        let cutoff = now.addingTimeInterval(-policy.floorWindow)
        samples.removeAll { $0.at < cutoff }
        let floor = samples.map(\.roundTrip).min() ?? roundTrip
        self.floor = floor
        previousQueueDelay = queueDelay
        queueDelay = max(0, roundTrip - floor)
        if queueDelay > policy.congestedAbove, transportBacklog < policy.backlogForCongestion {
            // Delay with nothing waiting on our side: the link, not our queue.
            congested = false
            congestedRun = 0
            clearSince = nil
        } else if queueDelay > policy.congestedAbove {
            congestedRun += 1
            // A queue that is already draining needs no second cut: the last
            // one is working, and cutting again on the same backlog ends far
            // below what the link carries. Cut when the delay holds or grows,
            // and only once it has been seen enough times to be a queue.
            congested = congestedRun >= policy.samplesBeforeCut && queueDelay >= previousQueueDelay * 0.9
            clearSince = nil
        } else if queueDelay < policy.clearBelow {
            congestedRun = 0
            if clearSince == nil { clearSince = now }
        } else {
            congestedRun = 0
            clearSince = nil
        }
    }

    /// The bitrate to apply now, or `nil` when it has not changed. Call after
    /// each observation, or on a timer.
    public mutating func evaluate(now: Date = Date()) -> Int? {
        if congested {
            congested = false
            everCongested = true
            guard now.timeIntervalSince(lastDecrease) >= policy.decreaseInterval else { return nil }
            let factor = queueDelay > policy.severeAbove ? min(0.5, policy.decreaseFactor) : policy.decreaseFactor
            let next = max(policy.minimumBitrate, Int(Double(current) * factor))
            lastDecrease = now
            guard next != current else { return nil }
            current = next
            return current
        }
        let interval = everCongested ? policy.increaseInterval : policy.startInterval
        let factor = everCongested ? policy.increaseFactor : policy.startFactor
        if let clearSince, now.timeIntervalSince(clearSince) >= interval, current < maximum {
            self.clearSince = now
            let next = min(maximum, max(current + 1, Int(Double(current) * factor)))
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
        congestedRun = 0
        clearSince = nil
        lastDecrease = .distantPast
        everCongested = false
        current = policy.initialBitrate > 0 ? min(maximum, max(policy.minimumBitrate, policy.initialBitrate)) : maximum
    }
}
