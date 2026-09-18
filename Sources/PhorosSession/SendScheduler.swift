import Foundation

/// Which queue a frame goes on. Order matters because everything shares one
/// connection: a write queued behind a 100 KB keyframe waits for all of it.
public enum SendLane: Equatable, Sendable {
    /// Small and latency-critical. Sent before anything else and never dropped.
    case control
    /// Sent before video, so audio never inherits a keyframe's delay.
    case audio
    /// Bulk. Sent last and dropped first.
    case video
}

/// Tunables for `SendScheduler`. The defaults are what the reference host
/// ships with.
public struct SendPolicy: Equatable, Sendable {
    /// Total bytes handed to the transport and not yet written, above which
    /// non-keyframe video is dropped instead of queued. About one second at
    /// 1.5 Mbps and a quarter second at 6 Mbps.
    public var maximumQueuedBytes: Int

    /// Audio bytes in flight above which audio chunks are dropped. Checked
    /// against audio bytes only: video's own gate parks the shared total near
    /// `maximumQueuedBytes`, so a shared check would drop audio forever.
    public var maximumQueuedAudioBytes: Int

    /// Audio is never dropped for longer than this, whatever the counters say.
    /// Admitting one chunk onto a saturated link cannot cause a latency runaway,
    /// and it makes "audio dead for the rest of the session" impossible.
    public var maximumAudioSilence: TimeInterval

    /// Writes handed to the transport at once. One made the send path
    /// stop-and-wait and collapsed throughput on a LAN; eight keeps the
    /// pipeline full while audio still goes first.
    public var maximumConcurrentWrites: Int

    /// A delta frame still waiting in the queue this long after it was
    /// enqueued is dropped instead of sent: on a link slower than the
    /// encoder every queued frame is delivered late, and a newer one is
    /// worth more than an old one delivered in full. The host then asks the
    /// encoder for a keyframe (`needsKeyframe`) so the decoder recovers at
    /// once instead of showing broken references until the next periodic one.
    public var maximumVideoQueueAge: TimeInterval

    /// How long the video already handed to the transport may take to drain,
    /// at the rate the link was last seen to drain it. `maximumQueuedBytes` is
    /// the same idea for a link whose rate is not known yet: 192 KB is 25 ms
    /// on a fast LAN but 150 ms on a 10 Mbps link, and every frame waits
    /// behind it. Once the scheduler has measured the drain rate the budget
    /// is the smaller of the two. Zero disables the time budget.
    public var maximumQueueDelay: TimeInterval

    /// Floor for the time budget in bytes, so a momentarily slow link cannot
    /// shrink the budget below one typical frame and starve the stream.
    public var minimumQueuedBytes: Int

    public init(
        maximumQueuedBytes: Int = 192 * 1024,
        maximumQueuedAudioBytes: Int = 64 * 1024,
        maximumAudioSilence: TimeInterval = 1.0,
        maximumConcurrentWrites: Int = 8,
        maximumVideoQueueAge: TimeInterval = 0.1,
        maximumQueueDelay: TimeInterval = 0.03,
        minimumQueuedBytes: Int = 24 * 1024
    ) {
        self.maximumQueuedBytes = maximumQueuedBytes
        self.maximumQueuedAudioBytes = maximumQueuedAudioBytes
        self.maximumAudioSilence = maximumAudioSilence
        self.maximumConcurrentWrites = maximumConcurrentWrites
        self.maximumVideoQueueAge = maximumVideoQueueAge
        self.maximumQueueDelay = maximumQueueDelay
        self.minimumQueuedBytes = minimumQueuedBytes
    }

    /// Defaults for a client that decodes only PCM: audio is 2.8 Mbps instead
    /// of 128 kbps, so its ceiling must be higher or it sheds constantly.
    public static let pcmAudio = SendPolicy(maximumQueuedAudioBytes: 288 * 1024)
}

/// Decides what to send, in what order, and what to drop, for one connection
/// that carries control, audio and video together.
///
/// The transport is a byte stream that never drops, so once the encoder
/// outpaces the link every frame queues and latency grows without bound. This
/// scheduler keeps latency bounded by refusing video when the backlog is high,
/// keeps audio ahead of video, and never lets an accounting slip silence a
/// stream: counters re-anchor to zero whenever nothing is in flight.
///
/// Usage, from one queue:
///
/// ```swift
/// // Capture side: skip the frame before it costs an encode. The encoder
/// // never saw it, so the reference chain stays whole.
/// if scheduler.shouldEncodeVideo() { encoder.encode(captured) }
/// // Encoder output
/// if scheduler.admitVideo(isKeyframe: key) {
///     scheduler.enqueueVideoFrame(packets, isKeyframe: key)
/// }
/// // Drain
/// while let write = scheduler.dequeue() {
///     connection.send(write.data) { scheduler.completed(write) ; drain() }
/// }
/// ```
///
/// Value type, no locking. Wrap it in whatever synchronisation the transport
/// callbacks need.
public struct SendScheduler: Sendable {
    /// A buffer the scheduler handed out. Pass it back to `completed`.
    public struct Write: Equatable, Sendable {
        public let data: Data
        public let lane: SendLane

        public init(data: Data, lane: SendLane) {
            self.data = data
            self.lane = lane
        }
    }

    public var policy: SendPolicy

    /// One video frame in the queue: its packets, already framed, and when it
    /// arrived. Sent as one write so the transport sees whole frames.
    private struct QueuedFrame {
        var data: Data
        var isKeyframe: Bool
        var enqueuedAt: Date
    }

    private var control: [Data] = []
    private var audio: [Data] = []
    private var video: [QueuedFrame] = []
    private var queuedVideoBytes = 0

    /// Set when the scheduler dropped a delta frame the peer will now be
    /// missing. Read it after draining and ask the encoder for a keyframe;
    /// it clears itself once a keyframe is enqueued.
    public private(set) var needsKeyframe = false

    private var bytesInFlight = 0
    private var audioBytesInFlight = 0
    private var writesInFlight = 0
    private var lastAudioAdmitted = Date.distantPast

    public private(set) var droppedVideoFrames = 0
    public private(set) var droppedAudioChunks = 0
    /// Captured frames `shouldEncodeVideo` refused. Cheap drops: no encode, no
    /// broken reference.
    public private(set) var skippedCaptureFrames = 0

    /// Bytes per second the transport drained while it had a backlog, as an
    /// exponential average over completions. Zero until measured.
    public private(set) var drainRate: Double = 0
    private var drainWindowStart: Date?
    private var drainWindowBytes = 0

    public init(policy: SendPolicy = SendPolicy()) {
        self.policy = policy
    }

    /// Bytes handed to the transport and not yet confirmed written.
    public var backlog: (total: Int, audio: Int) { (bytesInFlight, audioBytesInFlight) }

    /// Frames queued and not yet handed to the transport.
    public var queuedCount: Int { control.count + audio.count + video.count }

    /// Video bytes queued and not yet handed to the transport.
    public var queuedVideo: (bytes: Int, frames: Int) { (queuedVideoBytes, video.count) }

    /// Age of the oldest queued video frame, or zero when none is queued.
    public func oldestQueuedVideoAge(now: Date = Date()) -> TimeInterval {
        video.first.map { now.timeIntervalSince($0.enqueuedAt) } ?? 0
    }

    // MARK: Admission

    /// Whether a video frame should be sent now. Keyframes are always admitted:
    /// dropping one strands the decoder until the next, which is a worse
    /// artefact than a skipped delta frame.
    public mutating func admitVideo(isKeyframe: Bool) -> Bool {
        if isKeyframe { return true }
        if needsKeyframe {
            // The peer cannot decode a delta until the keyframe arrives. Sending
            // it would only delay that keyframe.
            droppedVideoFrames += 1
            return false
        }
        if bytesInFlight + queuedVideoBytes <= videoByteBudget { return true }
        droppedVideoFrames += 1
        needsKeyframe = true
        return false
    }

    /// Whether a captured frame is worth encoding now. False while the
    /// transport is behind: a frame skipped here costs nothing, while a frame
    /// dropped after encoding breaks the reference chain and forces a keyframe
    /// that is larger than everything it replaced. Gate captures with this and
    /// `admitVideo` becomes the exception path.
    public func shouldEncodeVideo() -> Bool {
        bytesInFlight + queuedVideoBytes <= videoByteBudget
    }

    /// `shouldEncodeVideo` with the skip counted.
    public mutating func admitCapture() -> Bool {
        if shouldEncodeVideo() { return true }
        skippedCaptureFrames += 1
        return false
    }

    /// Bytes of video the transport may hold before the scheduler sheds:
    /// `maximumQueuedBytes`, or less once the drain rate says that many bytes
    /// would take longer than `maximumQueueDelay` to send.
    public var videoByteBudget: Int {
        guard policy.maximumQueueDelay > 0, drainRate > 0 else { return policy.maximumQueuedBytes }
        let timed = Int(drainRate * policy.maximumQueueDelay)
        return min(policy.maximumQueuedBytes, max(policy.minimumQueuedBytes, timed))
    }

    /// Whether an audio chunk should be sent now.
    public mutating func admitAudio(now: Date = Date()) -> Bool {
        if audioBytesInFlight > policy.maximumQueuedAudioBytes,
           now.timeIntervalSince(lastAudioAdmitted) <= policy.maximumAudioSilence {
            droppedAudioChunks += 1
            return false
        }
        lastAudioAdmitted = now
        return true
    }

    // MARK: Queue

    public mutating func enqueue(_ data: Data, lane: SendLane) {
        switch lane {
        case .control: control.append(data)
        case .audio: audio.append(data)
        case .video: enqueueVideoFrame([data], isKeyframe: true)   // legacy path: never age-dropped
        }
    }

    /// Queue one video frame as its already-framed packets. They go to the
    /// transport as one write, in order, so a frame is either wholly queued,
    /// wholly in flight or wholly dropped.
    public mutating func enqueueVideoFrame(_ packets: [Data], isKeyframe: Bool, now: Date = Date()) {
        var data = Data()
        for packet in packets { data.append(packet) }
        video.append(QueuedFrame(data: data, isKeyframe: isKeyframe, enqueuedAt: now))
        queuedVideoBytes += data.count
        if isKeyframe { needsKeyframe = false }
    }

    /// The next buffer to write, or `nil` when the queue is empty or the
    /// concurrent-write window is full. Control first, then audio, then video.
    public mutating func dequeue(now: Date = Date()) -> Write? {
        guard writesInFlight < policy.maximumConcurrentWrites else { return nil }
        shedStaleVideo(now: now)
        let write: Write
        if !control.isEmpty {
            write = Write(data: control.removeFirst(), lane: .control)
        } else if !audio.isEmpty {
            write = Write(data: audio.removeFirst(), lane: .audio)
        } else if !video.isEmpty {
            let frame = video.removeFirst()
            queuedVideoBytes -= frame.data.count
            write = Write(data: frame.data, lane: .video)
        } else {
            return nil
        }
        writesInFlight += 1
        bytesInFlight += write.data.count
        if write.lane == .audio { audioBytesInFlight += write.data.count }
        if drainWindowStart == nil { drainWindowStart = now }
        return write
    }

    /// The transport finished (or failed) a write handed out by `dequeue`.
    public mutating func completed(_ write: Write, now: Date = Date()) {
        writesInFlight -= 1
        bytesInFlight -= write.data.count
        if write.lane == .audio { audioBytesInFlight -= write.data.count }
        drainWindowBytes += write.data.count
        // A window that starts at a write and ends at a completion, with the
        // transport never idle inside it, measures the link and not the
        // producer. Sample once the window is long enough to mean something,
        // and whenever the backlog empties.
        if let start = drainWindowStart {
            let elapsed = now.timeIntervalSince(start)
            let idle = writesInFlight <= 0
            if drainWindowBytes >= 16 * 1024, elapsed >= (idle ? 0.005 : 0.05) {
                let sample = Double(drainWindowBytes) / elapsed
                drainRate = drainRate == 0 ? sample : drainRate * 0.7 + sample * 0.3
                drainWindowStart = idle ? nil : now
                drainWindowBytes = 0
            } else if idle {
                drainWindowStart = nil
                drainWindowBytes = 0
            }
        }
        if writesInFlight <= 0 {
            // Nothing outstanding: any drift from a lost completion is erased
            // here, so the counters can never latch above a threshold.
            writesInFlight = 0
            bytesInFlight = 0
            audioBytesInFlight = 0
        }
    }

    /// Discard queued video, for example when the peer pauses video: what is
    /// queued is stale by the time it resumes.
    public mutating func dropQueuedVideo() {
        video.removeAll()
        queuedVideoBytes = 0
    }

    /// Drop delta frames that waited longer than `maximumVideoQueueAge`.
    /// Keyframes stay: the decoder needs the next one whatever its age.
    private mutating func shedStaleVideo(now: Date) {
        while let first = video.first, !first.isKeyframe,
              now.timeIntervalSince(first.enqueuedAt) > policy.maximumVideoQueueAge {
            video.removeFirst()
            queuedVideoBytes -= first.data.count
            droppedVideoFrames += 1
            needsKeyframe = true
        }
    }
}
