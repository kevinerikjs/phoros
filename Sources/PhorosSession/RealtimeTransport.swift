import Foundation
import Phoros

/// What arrives from the peer through a `PhorosRealtimeTransport`, already
/// reassembled into the unit the application works with.
public enum RealtimeInbound: Sendable {
    /// One whole video frame, in order.
    case video(AssembledFrame)
    /// The host's parameter sets for the codec that follows.
    case videoParameterSets(Data, codec: VideoCodecID)
    /// One audio chunk with its header parsed. `codec` is what the packet
    /// flags said; a client must not decode it as anything else.
    case audio(AudioChunkHeader, Data, codec: AudioCodecID)
    /// A controller report. `connected` false is a detach.
    case input(ControllerReport, connected: Bool)
    /// A control message this version understands.
    case control(ControlMessage)
    /// A control message with a type this version does not know. Ignore it;
    /// see docs/compatibility.md.
    case unknownControl(type: String)
    /// A JSON message that is not a control message: pairing and auth.
    case message(Data)
    /// A liveness packet. The transport already counted it as heard.
    case heartbeat
}

/// Numbers a transport keeps about the link. Every field is a best effort:
/// zero or nil where the transport cannot know.
public struct RealtimeMetrics: Equatable, Sendable {
    /// The round trip of the last probe, seconds.
    public var roundTrip: TimeInterval?
    /// Round trip minus its recent floor: what the link is queueing, seconds.
    public var queueDelay: TimeInterval
    /// The video bitrate the transport wants right now, bits per second.
    public var bitrate: Int
    /// Bytes per second the link was last seen to drain.
    public var drainRate: Double
    /// Video bytes between the encoder and the peer as far as the transport can see.
    public var videoBytesPending: Int
    /// Video frames refused or shed since the transport started.
    public var droppedVideoFrames: Int
    /// Captured frames refused before an encode since the transport started.
    public var skippedCaptureFrames: Int

    public init(roundTrip: TimeInterval? = nil, queueDelay: TimeInterval = 0, bitrate: Int = 0, drainRate: Double = 0,
                videoBytesPending: Int = 0, droppedVideoFrames: Int = 0, skippedCaptureFrames: Int = 0) {
        self.roundTrip = roundTrip
        self.queueDelay = queueDelay
        self.bitrate = bitrate
        self.drainRate = drainRate
        self.videoBytesPending = videoBytesPending
        self.droppedVideoFrames = droppedVideoFrames
        self.skippedCaptureFrames = skippedCaptureFrames
    }
}

/// Points in a transport's send path a measurement harness can stamp. The
/// transport reports them; it never blocks on them.
public enum RealtimeTrace: Sendable {
    /// A video frame was queued: its number, presentation timestamp and size.
    case videoQueued(frame: UInt32, presentationTimestamp: Int64, bytes: Int)
    /// A video frame was handed to the link, with the bytes the link still held.
    case videoHandedToLink(frame: UInt32, linkBacklog: Int)
    /// The link took a video frame.
    case videoAcceptedByLink(frame: UInt32)
    /// A probe came back. `counted` is false for one that waited behind a keyframe.
    case probe(roundTrip: TimeInterval, queueDelay: TimeInterval, bitrate: Int, counted: Bool)
    /// A sample of what the link held, taken before a probe went out.
    case linkSample(backlog: Int, queuedVideoBytes: Int, drainRate: Double, budget: Int)
}

/// The seam between an application and the wire: what a peer sends and
/// receives, in the units it thinks in, with the transport owning framing,
/// fragmentation, reassembly, scheduling, shedding and link adaptation.
///
/// Every method is safe from any thread. Callbacks arrive on the
/// transport's queue. The v1 TCP path is `PhorosLegacyTransport` in
/// `PhorosNetwork`; a later transport implements the same protocol and the
/// application does not change.
public protocol PhorosRealtimeTransport: AnyObject {
    /// Everything that arrives from the peer.
    var onInbound: ((RealtimeInbound) -> Void)? { get set }
    /// The transport is ready to carry frames.
    var onReady: (() -> Void)? { get set }
    /// The transport ended, once.
    var onEnd: ((Error) -> Void)? { get set }
    /// The transport dropped or shed a delta frame; the peer's decoder needs
    /// a keyframe. Ask the encoder for one.
    var onKeyframeNeeded: (() -> Void)? { get set }
    /// The link adaptation wants the encoder at this bitrate.
    var onBitrateChange: ((Int) -> Void)? { get set }
    /// Measurement points, for a harness. Nil costs nothing.
    var onTrace: ((RealtimeTrace) -> Void)? { get set }

    var metrics: RealtimeMetrics { get }

    func start()
    func cancel()
    /// Media may flow: probes, heartbeats and keep-awake run only while this
    /// is true. Set it after authentication, clear it for a video hold.
    func setStreaming(_ enabled: Bool)
    /// The scheduler's tunables, for a peer whose audio needs a different
    /// budget (`SendPolicy.pcmAudio`). Takes effect at once.
    func setSendPolicy(_ policy: SendPolicy)

    // MARK: Video (host to client)

    /// Whether the transport has room for another encoded frame. Ask before
    /// encoding: a frame skipped here costs nothing.
    var acceptsVideoFrame: Bool { get }
    /// The ceiling for link adaptation, normally the preset's bitrate. The
    /// transport reports what it wants through `onBitrateChange`.
    func setMaximumBitrate(_ bitsPerSecond: Int)
    func sendVideoParameterSets(_ data: Data, codec: VideoCodecID)
    /// One whole encoded frame. The transport fragments it, schedules it and
    /// may refuse or shed it; a keyframe is never refused.
    func sendVideo(_ annexB: Data, presentationTimestamp: Int64, isKeyframe: Bool)
    /// Discard video not yet sent, for a pause: it is stale by the resume.
    func dropQueuedVideo()

    // MARK: Audio (host to client)

    func sendAudio(_ accessUnit: Data, codec: AudioCodecID, presentationTimestamp: Int64)

    // MARK: Input (client to host): latest value wins, never queued behind video

    func sendInput(_ report: ControllerReport, connected: Bool)

    // MARK: Reliable

    func sendControl(_ message: ControlMessage)
    /// A JSON message that is not a control message: pairing and auth.
    func sendMessage(_ json: Data)
}
