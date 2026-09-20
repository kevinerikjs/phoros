import Foundation
import Phoros

/// Estimates the offset between this peer's clock and the other peer's from
/// `ClockProbe` / `ClockReply` exchanges, so a video timestamp stamped on the
/// host's clock can be read as an age on the client's.
///
/// One exchange gives four times: the probe left the client at `t1`, reached
/// the host at `t2`, the reply left the host at `t3` and arrived at `t4`.
/// Then `offset = ((t2 - t1) + (t3 - t4)) / 2` and `roundTrip = (t4 - t1) -
/// (t3 - t2)`, as in NTP. The estimate is the offset of the sample with the
/// shortest round trip in the recent window: queueing delays only ever make
/// a round trip longer, so the shortest one saw the least of them.
///
/// All times are microseconds of each peer's monotonic clock, the clock the
/// host stamps video presentation timestamps with.
public struct ClockSync: Sendable {
    /// Samples older than this fall out of the window.
    public var window: TimeInterval

    /// Host clock minus client clock, in microseconds, from the best recent
    /// sample. `nil` until the first reply.
    public private(set) var offset: Int64?
    /// The round trip of the sample the offset came from, in microseconds.
    public private(set) var bestRoundTrip: Int64?
    /// The most recent round trip, in microseconds.
    public private(set) var lastRoundTrip: Int64?

    private var samples: [(at: Date, offset: Int64, roundTrip: Int64)] = []
    private var nextID: UInt32 = 1
    private var outstanding: [UInt32: Int64] = [:]

    public init(window: TimeInterval = 30) {
        self.window = window
    }

    /// The probe to send now. `now` is the client's clock in microseconds.
    public mutating func probe(now: Int64) -> ClockProbe {
        let id = nextID
        nextID &+= 1
        outstanding[id] = now
        if outstanding.count > 16 { outstanding.removeValue(forKey: outstanding.keys.min()!) }
        return ClockProbe(id: id, sentAt: now)
    }

    /// Records a reply. `now` is the client's clock when it arrived. Returns
    /// the sample's round trip, or `nil` for a reply to no probe of ours.
    @discardableResult
    public mutating func reply(_ reply: ClockReply, now: Int64, at date: Date = Date()) -> Int64? {
        guard let sentAt = outstanding.removeValue(forKey: reply.id), sentAt == reply.sentAt else { return nil }
        let roundTrip = (now - sentAt) - (reply.repliedAt - reply.receivedAt)
        let offset = ((reply.receivedAt - sentAt) + (reply.repliedAt - now)) / 2
        samples.append((date, offset, roundTrip))
        let cutoff = date.addingTimeInterval(-window)
        samples.removeAll { $0.at < cutoff }
        if let best = samples.min(by: { $0.roundTrip < $1.roundTrip }) {
            self.offset = best.offset
            bestRoundTrip = best.roundTrip
        }
        lastRoundTrip = roundTrip
        return roundTrip
    }

    /// A host timestamp read on the client's clock, or `nil` without an offset.
    public func localTime(forHost hostTime: Int64) -> Int64? {
        offset.map { hostTime - $0 }
    }

    /// How old a frame stamped `presentationTimestamp` (host clock) is at
    /// `now` (client clock), in microseconds. `nil` without an offset.
    public func age(ofPresentationTimestamp presentationTimestamp: Int64, now: Int64) -> Int64? {
        localTime(forHost: presentationTimestamp).map { now - $0 }
    }

    public mutating func reset() {
        samples.removeAll()
        outstanding.removeAll()
        offset = nil
        bestRoundTrip = nil
        lastRoundTrip = nil
    }
}
