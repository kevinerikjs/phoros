import Foundation
import Network
import Phoros
import PhorosSession

/// Tunables for `PhorosLegacyTransport`. The defaults are what the reference
/// host and client ship with.
public struct LegacyTransportOptions: Sendable {
    public enum Role: Sendable { case host, client }

    /// Host or client. Decides how control messages go on the wire: a host
    /// wraps them in `.control` packets, a client sends them bare.
    public var role: Role
    /// Largest media payload per packet.
    public var maximumPayloadLength: Int
    public var sendPolicy: SendPolicy
    public var bitratePolicy: BitrateControllerPolicy
    /// Seconds between link probes (a `.ping` on the media connection). Zero
    /// disables the probe and the bitrate controller. Hosts probe.
    public var probeInterval: TimeInterval
    /// Seconds between `.heartbeat` packets while nothing else went out. Zero
    /// disables. Hosts send them.
    public var heartbeatInterval: TimeInterval
    /// A `.heartbeat` every this many seconds while no video went out in the
    /// same span keeps a phone's Wi-Fi radio out of power save. Zero disables.
    public var keepAwakeInterval: TimeInterval
    /// Read the kernel's unacknowledged bytes into the scheduler before each
    /// video decision. Off, the scheduler sees only its own queue.
    public var readsLinkBacklog: Bool

    public init(
        role: Role,
        maximumPayloadLength: Int = 1400,
        sendPolicy: SendPolicy = SendPolicy(),
        bitratePolicy: BitrateControllerPolicy = BitrateControllerPolicy(),
        probeInterval: TimeInterval = 0.2,
        heartbeatInterval: TimeInterval = 5,
        keepAwakeInterval: TimeInterval = 0.02,
        readsLinkBacklog: Bool = true
    ) {
        self.role = role
        self.maximumPayloadLength = maximumPayloadLength
        self.sendPolicy = sendPolicy
        self.bitratePolicy = bitratePolicy
        self.probeInterval = role == .host ? probeInterval : 0
        self.heartbeatInterval = role == .host ? heartbeatInterval : 0
        self.keepAwakeInterval = role == .host ? keepAwakeInterval : 0
        self.readsLinkBacklog = readsLinkBacklog
    }
}

/// The v1 wire over one TCP connection: `PhorosRealtimeTransport` as Beam 3
/// and Beacon 1.4 speak it, byte for byte.
///
/// Owns the framing (`PhorosConnection`), fragmentation and reassembly, the
/// `SendScheduler`, the link probe and `BitrateController`, the kernel
/// backlog reading, heartbeats and the radio keep-awake. The application
/// keeps pairing, capture, codecs, input replay and policy.
///
/// ```swift
/// let transport = PhorosLegacyTransport(accepting: connection, options: .init(role: .host))
/// transport.onInbound = { inbound in … }
/// transport.onKeyframeNeeded = { encoder.requestKeyframe() }
/// transport.onBitrateChange = { encoder.setBitrate($0) }
/// transport.start()
/// encoder.onFrame = { annexB, pts, key in transport.sendVideo(annexB, presentationTimestamp: pts, isKeyframe: key) }
/// ```
public final class PhorosLegacyTransport: PhorosRealtimeTransport, @unchecked Sendable {
    public var onInbound: ((RealtimeInbound) -> Void)?
    public var onReady: (() -> Void)?
    public var onEnd: ((Error) -> Void)?
    public var onKeyframeNeeded: (() -> Void)?
    public var onBitrateChange: ((Int) -> Void)?
    public var onTrace: ((RealtimeTrace) -> Void)?

    public let options: LegacyTransportOptions
    /// The framed connection underneath, for what the seam does not cover
    /// (path information, for one).
    public let link: PhorosConnection
    private let queue: DispatchQueue

    private var scheduler: SendScheduler
    private var bitrate: BitrateController
    private var probe = RoundTripProbe(staleAfter: 1)
    private var assembler = FrameAssembler()
    private var videoFrameNumber: UInt32 = 0
    private var audioSequenceNumber: UInt32 = 0
    private var probeTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    private var keepAwakeTimer: DispatchSourceTimer?
    private var keyframeBurstUntil = Date.distantPast
    private var pingSentAt = Date.distantPast
    private var pingBacklog = Int.max
    private var lastVideoWriteAt = Date.distantPast
    private var lastWriteAt = Date.distantPast
    private var bytesAccepted = 0
    private var lastLinkSample: (at: Date, accepted: Int, unacked: Int)?
    private var linkRate: Double = 0
    private var holdRetryScheduled = false
    private var started = false
    private var streaming = false
    private var lastRoundTrip: TimeInterval?

    /// An outbound connection (client).
    public convenience init(
        to endpoint: NWEndpoint,
        options: LegacyTransportOptions = LegacyTransportOptions(role: .client),
        queue: DispatchQueue = DispatchQueue(label: "phoros.transport", qos: .userInteractive)
    ) {
        self.init(link: PhorosConnection(to: endpoint, parameters: PhorosConnection.parameters(), queue: queue), options: options, queue: queue)
    }

    /// An inbound connection handed over by an `NWListener` (host).
    public convenience init(
        accepting connection: NWConnection,
        options: LegacyTransportOptions = LegacyTransportOptions(role: .host),
        queue: DispatchQueue = DispatchQueue(label: "phoros.transport", qos: .userInteractive)
    ) {
        self.init(link: PhorosConnection(accepting: connection, queue: queue), options: options, queue: queue)
    }

    public init(link: PhorosConnection, options: LegacyTransportOptions, queue: DispatchQueue) {
        self.link = link
        self.options = options
        self.queue = queue
        scheduler = SendScheduler(policy: options.sendPolicy)
        bitrate = BitrateController(maximum: 6_000_000, policy: options.bitratePolicy)
    }

    // MARK: Lifecycle

    public func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            link.onReady = { [weak self] in self?.onReady?() }
            link.onEnd = { [weak self] reason in
                guard let self else { return }
                self.stopTimers()
                self.onEnd?(reason)
            }
            link.onFrame = { [weak self] frame in self?.handle(frame) }
            link.start()
            if options.probeInterval > 0 { startProbe() }
            if options.heartbeatInterval > 0 { startHeartbeat() }
            if options.keepAwakeInterval > 0 { startKeepAwake() }
        }
    }

    public func cancel() {
        queue.async { [self] in
            stopTimers()
            link.cancel()
        }
    }

    public func setStreaming(_ enabled: Bool) {
        queue.async { [self] in streaming = enabled }
    }

    public func setSendPolicy(_ policy: SendPolicy) {
        queue.async { [self] in scheduler.policy = policy }
    }

    private func stopTimers() {
        probeTimer?.cancel(); probeTimer = nil
        heartbeatTimer?.cancel(); heartbeatTimer = nil
        keepAwakeTimer?.cancel(); keepAwakeTimer = nil
    }

    /// A snapshot, safe from any thread including the transport's own callbacks.
    public var metrics: RealtimeMetrics {
        metricsLock.withLock { metricsSnapshot }
    }
    private var metricsSnapshot = RealtimeMetrics()
    private let metricsLock = NSLock()

    /// Transport queue only.
    private func publishMetrics() {
        let m = RealtimeMetrics(
            roundTrip: lastRoundTrip, queueDelay: bitrate.queueDelay, bitrate: bitrate.current,
            drainRate: scheduler.drainRate, videoBytesPending: scheduler.videoBytesPending,
            droppedVideoFrames: scheduler.droppedVideoFrames, skippedCaptureFrames: scheduler.skippedCaptureFrames
        )
        metricsLock.withLock { metricsSnapshot = m }
    }

    // MARK: Inbound

    private func handle(_ frame: Frame) {
        switch frame {
        case .packet(let packet):
            switch packet.type {
            case .video, .videoKeyframe:
                if let assembled = assembler.receive(packet.payload, isKeyframe: packet.type == .videoKeyframe) {
                    onInbound?(.video(assembled))
                }
            case .parameterSets:
                guard let codec = VideoCodecID(packetFlags: packet.header.flags) else { return }
                onInbound?(.videoParameterSets(packet.payload, codec: codec))
            case .audio:
                guard let codec = AudioCodecID(packetFlags: packet.header.flags),
                      let header = AudioChunkHeader.parse(from: packet.payload) else { return }
                onInbound?(.audio(header, packet.payload.dropFirst(AudioChunkHeader.size), codec: codec))
            case .input:
                guard let report = ControllerReport.parse(from: packet.payload) else { return }
                onInbound?(.input(report, connected: packet.header.flags & ControllerReport.connectedFlag != 0))
            case .heartbeat:
                onInbound?(.heartbeat)
            case .control:
                handleJSON(packet.payload)
            }
        case .message(let json):
            handleJSON(json)
        }
    }

    private func handleJSON(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(ControlMessage.self, from: data)
            switch message {
            case .pong:
                handlePong()
            case .ping:
                sendControl(.pong)
            default:
                break
            }
            onInbound?(.control(message))
        } catch ControlMessageError.unknownType(let name) {
            // A JSON object with a "type" the control set does not know: either a pairing
            // message (those types are disjoint) or a newer peer's control message.
            if PairingMessageType(rawValue: name) != nil {
                onInbound?(.message(data))
            } else {
                onInbound?(.unknownControl(type: name))
            }
        } catch {
            onInbound?(.message(data))
        }
    }

    // MARK: Video

    public var acceptsVideoFrame: Bool {
        queue.sync {
            refreshLinkBacklog()
            return scheduler.admitCapture()
        }
    }

    public func setMaximumBitrate(_ bitsPerSecond: Int) {
        queue.async { [self] in
            bitrate.setMaximum(bitsPerSecond)
            publishMetrics()
            onBitrateChange?(bitrate.current)
        }
    }

    public func sendVideoParameterSets(_ data: Data, codec: VideoCodecID) {
        queue.async { [self] in
            scheduler.enqueue(Packet.encode(.parameterSets, flags: codec.packetFlags, payload: data).lengthPrefixed(), lane: .video)
            drain()
        }
    }

    public func sendVideo(_ annexB: Data, presentationTimestamp: Int64, isKeyframe: Bool) {
        queue.async { [self] in
            refreshLinkBacklog()
            guard scheduler.admitVideo(isKeyframe: isKeyframe) else { drain(); return }
            let frameNumber = videoFrameNumber
            videoFrameNumber &+= 1
            let packets = VideoFragmentHeader.fragment(
                annexB, frameNumber: frameNumber, presentationTimestamp: presentationTimestamp, maximumPayloadLength: options.maximumPayloadLength
            ).map { Packet.encode(isKeyframe ? .videoKeyframe : .video, payload: $0).lengthPrefixed() }
            scheduler.enqueueVideoFrame(packets, isKeyframe: isKeyframe, tag: Int(frameNumber) + 1)
            if isKeyframe {
                // A probe that leaves behind this keyframe measures the keyframe, not the link.
                let bytes = Double(packets.reduce(0) { $0 + $1.count })
                let seconds = scheduler.drainRate > 0 ? bytes / scheduler.drainRate : 0.2
                keyframeBurstUntil = Date().addingTimeInterval(min(2, max(0.1, seconds * 1.5)))
            }
            onTrace?(.videoQueued(frame: frameNumber, presentationTimestamp: presentationTimestamp, bytes: annexB.count))
            drain()
        }
    }

    public func dropQueuedVideo() {
        queue.async { [self] in scheduler.dropQueuedVideo() }
    }

    // MARK: Audio

    public func sendAudio(_ accessUnit: Data, codec: AudioCodecID, presentationTimestamp: Int64) {
        queue.async { [self] in
            guard scheduler.admitAudio() else { return }
            let sequence = audioSequenceNumber
            audioSequenceNumber &+= 1
            var payload = AudioChunkHeader(sequenceNumber: sequence, presentationTimestamp: presentationTimestamp).serialized()
            payload.append(accessUnit)
            // Audio has no fragmentation path; an over-cap payload would be mis-framed.
            guard payload.count <= options.maximumPayloadLength else { return }
            scheduler.enqueue(Packet.encode(.audio, flags: codec.packetFlags, payload: payload).lengthPrefixed(), lane: .audio)
            drain()
        }
    }

    // MARK: Input and reliable

    public func sendInput(_ report: ControllerReport, connected: Bool) {
        // Latest value: straight to the link, ahead of anything queued, never scheduled.
        link.send(Packet.encode(.input, flags: connected ? ControllerReport.connectedFlag : 0, payload: report.serialized()))
    }

    public func sendControl(_ message: ControlMessage) {
        guard let json = try? JSONEncoder().encode(message) else { return }
        switch options.role {
        case .host: enqueueControl(Packet.encode(.control, payload: json))
        case .client: link.send(json)
        }
    }

    public func sendMessage(_ json: Data) {
        switch options.role {
        case .host: enqueueControl(Packet.encode(.control, payload: json))
        case .client: link.send(json)
        }
    }

    private func enqueueControl(_ packet: Data) {
        queue.async { [self] in
            scheduler.enqueue(packet.lengthPrefixed(), lane: .control)
            drain()
        }
    }

    // MARK: Link

    /// The kernel holds unacknowledged bytes the scheduler cannot otherwise see: a write
    /// completes when the kernel takes it. Read them before every video decision.
    private func refreshLinkBacklog() {
        guard options.readsLinkBacklog,
              let tcp = link.connection.metadata(definition: NWProtocolTCP.definition) as? NWProtocolTCP.Metadata else { return }
        scheduler.transportBacklog = Int(tcp.availableSendBuffer)
    }

    /// Link rate from what the kernel accepted minus what it still holds, over a window in
    /// which the kernel was never empty.
    private func sampleLinkRate(now: Date) {
        let unacked = scheduler.transportBacklog
        defer { lastLinkSample = (now, bytesAccepted, unacked) }
        guard let last = lastLinkSample, last.unacked > 0 else { return }
        let drained = (bytesAccepted - last.accepted) - (unacked - last.unacked)
        let dt = now.timeIntervalSince(last.at)
        guard drained > 0, dt > 0.05 else { return }
        let sample = Double(drained) / dt
        linkRate = linkRate == 0 ? sample : linkRate * 0.7 + sample * 0.3
        scheduler.reportDrainRate(linkRate)
    }

    private func startProbe() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + options.probeInterval, repeating: options.probeInterval, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self, self.streaming, self.probe.shouldSend() else { return }
            self.pingSentAt = Date()
            self.refreshLinkBacklog()
            self.sampleLinkRate(now: self.pingSentAt)
            self.pingBacklog = self.scheduler.transportBacklog + self.scheduler.backlog.total
            self.onTrace?(.linkSample(backlog: self.scheduler.transportBacklog, queuedVideoBytes: self.scheduler.queuedVideo.bytes,
                                      drainRate: self.scheduler.drainRate, budget: self.scheduler.videoByteBudget))
            self.sendControl(.ping)
        }
        timer.resume()
        probeTimer = timer
    }

    private func handlePong() {
        guard let rtt = probe.receivedPong() else { return }
        lastRoundTrip = rtt
        let counted = pingSentAt > keyframeBurstUntil
        if counted {
            bitrate.observe(roundTrip: rtt, transportBacklog: pingBacklog)
            publishMetrics()
            if let next = bitrate.evaluate() { publishMetrics(); onBitrateChange?(next) }
        }
        onTrace?(.probe(roundTrip: rtt, queueDelay: bitrate.queueDelay, bitrate: bitrate.current, counted: counted))
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + options.heartbeatInterval, repeating: options.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.streaming else { return }
            self.scheduler.enqueue(Packet.encode(.heartbeat).lengthPrefixed(), lane: .control)
            self.drain()
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func startKeepAwake() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: options.keepAwakeInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.streaming, Date().timeIntervalSince(self.lastWriteAt) > self.options.keepAwakeInterval else { return }
            self.scheduler.enqueue(Packet.encode(.heartbeat).lengthPrefixed(), lane: .control)
            self.drain()
        }
        timer.resume()
        keepAwakeTimer = timer
    }

    // MARK: Drain

    private func drain() {
        defer { publishMetrics(); if scheduler.needsKeyframe { onKeyframeNeeded?() } }
        refreshLinkBacklog()
        defer {
            if scheduler.queuedVideo.frames > 0, !holdRetryScheduled {
                holdRetryScheduled = true
                queue.asyncAfter(deadline: .now() + .milliseconds(4)) { [weak self] in
                    guard let self else { return }
                    self.holdRetryScheduled = false
                    self.drain()
                }
            }
        }
        while let write = scheduler.dequeue() {
            lastWriteAt = Date()
            if write.lane == .video { lastVideoWriteAt = lastWriteAt }
            if write.tag > 0 { onTrace?(.videoHandedToLink(frame: UInt32(write.tag - 1), linkBacklog: scheduler.transportBacklog)) }
            link.connection.send(content: write.data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.queue.async {
                    if write.tag > 0 { self.onTrace?(.videoAcceptedByLink(frame: UInt32(write.tag - 1))) }
                    self.scheduler.completed(write)
                    self.bytesAccepted += write.data.count
                    if error != nil { self.link.cancel(); return }
                    self.drain()
                }
            })
        }
    }
}
