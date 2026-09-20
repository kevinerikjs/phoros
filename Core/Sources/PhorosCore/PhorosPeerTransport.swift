import Foundation
import Phoros
import PhorosSession

public enum PeerTransportEnd: Error { case disconnected }

/// `PhorosRealtimeTransport` over a `RealtimePeer`: video, audio and input on the realtime
/// data channel (unordered, 50 ms lifetime, no head-of-line blocking between frames),
/// control and parameter sets on the reliable one. Frames larger than the channel's message
/// limit are fragmented with the v1 `VideoFragmentHeader` and reassembled by the v1
/// `FrameAssembler`, which tolerates any order.
///
/// This is the BEAM-54 spike: the same seam the TCP transport implements, so the harness
/// compares the two on one table. RTP media is the next step; SCTP messages are enough to
/// measure what UDP, DTLS and partial reliability do to the loop.
public final class PhorosPeerTransport: PhorosRealtimeTransport {
    public var onInbound: ((RealtimeInbound) -> Void)?
    public var onReady: (() -> Void)?
    public var onEnd: ((Error) -> Void)?
    public var onKeyframeNeeded: (() -> Void)?
    public var onBitrateChange: ((Int) -> Void)?
    public var onTrace: ((RealtimeTrace) -> Void)?
    public private(set) var metrics = RealtimeMetrics()

    public let peer: RealtimePeer
    private let queue: DispatchQueue
    private var assembler = FrameAssembler()
    private var frameNumber: UInt32 = 0
    private var audioSequence: UInt32 = 0
    private var ready = false
    /// Largest message on the realtime channel. SCTP's default remote limit is 64 KB;
    /// stay under it with room for the tag and header.
    public var maximumMessageLength = 48 * 1024

    private enum Tag: UInt8 { case video = 1, parameterSets = 2, control = 3, input = 4, audio = 5 }

    public init(peer: RealtimePeer, queue: DispatchQueue = DispatchQueue(label: "phoros.peer.transport", qos: .userInteractive)) {
        self.peer = peer
        self.queue = queue
        peer.onData = { [weak self] channel, bytes in self?.handle(Data(bytes)) }
        peer.onVideo = { [weak self] frame in
            guard let self else { return }
            let number = self.receivedFrames
            self.receivedFrames &+= 1
            if !frame.contiguous { self.onKeyframeNeeded?() }
            self.onInbound?(.video(AssembledFrame(frameNumber: number, presentationTimestamp: frame.presentationTimestamp, isKeyframe: frame.isKeyframe, bitstream: frame.annexB)))
        }
        peer.onEvent = { [weak self] event in
            guard let self else { return }
            if case .connected = event, !self.ready { self.ready = true; self.onReady?() }
            if case .disconnected = event { self.onEnd?(PeerTransportEnd.disconnected) }
            if case .bandwidth(let bps) = event {
                // TWCC says what the link carries; the encoder follows, capped by the preset.
                let next = min(self.maximumBitrate, max(500_000, bps))
                if next != self.metrics.bitrate { self.metrics.bitrate = next; self.onBitrateChange?(next) }
            }
        }
    }
    private var receivedFrames: UInt32 = 0
    private var maximumBitrate = Int.max
    /// RTP video, or the data channels (the first spike). RTP is the path.
    public var videoOverRTP = true
    public var codec: VideoCodecID = .h264

    public func start() {}
    public func cancel() { peer.destroy() }
    public func setStreaming(_ enabled: Bool) {}
    public func setSendPolicy(_ policy: SendPolicy) {}
    public var acceptsVideoFrame: Bool { true }
    public func setMaximumBitrate(_ bitsPerSecond: Int) {
        maximumBitrate = bitsPerSecond
        peer.setDesiredBitrate(bitsPerSecond)
        onBitrateChange?(min(bitsPerSecond, max(metrics.bitrate, 500_000)))
    }
    public func dropQueuedVideo() {}

    /// Messages the association's send buffer could not take yet, oldest first, with the
    /// time they were queued. Realtime messages older than `maximumQueueAge` are dropped
    /// unsent; reliable ones wait.
    private var outbox: [(channel: Int, message: Data, at: Date)] = []
    private var retryScheduled = false
    public var maximumQueueAge: TimeInterval = 0.1

    private func send(_ tag: Tag, _ payload: Data, realtime: Bool) {
        var message = Data([tag.rawValue])
        message.append(payload)
        queue.async { [self] in
            outbox.append((realtime ? 1 : 0, message, Date()))
            flush()
        }
    }

    /// Queue only. Writes what the association takes, keeps the rest for a retry.
    private func flush() {
        while let next = outbox.first {
            if next.channel == 1, Date().timeIntervalSince(next.at) > maximumQueueAge {
                outbox.removeFirst()
                metrics.droppedVideoFrames += 1
                continue
            }
            let status = peer.send(channel: next.channel, next.message)
            if status == 0 { outbox.removeFirst(); continue }
            if status == CoreError.busy.rawValue { break }
            outbox.removeFirst()   // any other error: the message is not going to go
        }
        if !outbox.isEmpty, !retryScheduled {
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.flush()
            }
        }
    }

    public func sendVideoParameterSets(_ data: Data, codec: VideoCodecID) {
        self.codec = codec
        var payload = Data([codec.packetFlags])
        payload.append(data)
        send(.parameterSets, payload, realtime: false)
    }

    public func sendVideo(_ annexB: Data, presentationTimestamp: Int64, isKeyframe: Bool) {
        let number = frameNumber
        frameNumber &+= 1
        onTrace?(.videoQueued(frame: number, presentationTimestamp: presentationTimestamp, bytes: annexB.count))
        if videoOverRTP {
            let status = peer.sendVideo(annexB, presentationTimestamp: presentationTimestamp, codec: codec == .hevc ? 1 : 0, isKeyframe: isKeyframe)
            if status != 0 { metrics.droppedVideoFrames += 1; if !isKeyframe { onKeyframeNeeded?() } }
            onTrace?(.videoHandedToLink(frame: number, linkBacklog: 0))
            return
        }
        // A keyframe goes on the reliable channel: it is the frame every later one depends
        // on, and a 300 KB keyframe in 48 KB messages with a 50 ms lifetime loses a fragment
        // whenever the association's window is small. Deltas go realtime: a late one is worth
        // nothing, and the next keyframe repairs the chain.
        for fragment in VideoFragmentHeader.fragment(annexB, frameNumber: number, presentationTimestamp: presentationTimestamp, maximumPayloadLength: maximumMessageLength) {
            var payload = Data([isKeyframe ? 1 : 0])
            payload.append(fragment)
            send(.video, payload, realtime: !isKeyframe)
        }
        onTrace?(.videoHandedToLink(frame: number, linkBacklog: 0))
    }

    public func sendAudio(_ accessUnit: Data, codec: AudioCodecID, presentationTimestamp: Int64) {
        let sequence = audioSequence
        audioSequence &+= 1
        var payload = Data([codec.packetFlags])
        payload.append(AudioChunkHeader(sequenceNumber: sequence, presentationTimestamp: presentationTimestamp).serialized())
        payload.append(accessUnit)
        send(.audio, payload, realtime: true)
    }

    public func sendInput(_ report: ControllerReport, connected: Bool) {
        var payload = Data([connected ? ControllerReport.connectedFlag : 0])
        payload.append(report.serialized())
        send(.input, payload, realtime: true)
    }

    public func sendControl(_ message: ControlMessage) {
        guard let json = try? JSONEncoder().encode(message) else { return }
        send(.control, json, realtime: false)
    }

    public func sendMessage(_ json: Data) { send(.control, json, realtime: false) }

    private func handle(_ message: Data) {
        guard let tag = message.first.flatMap(Tag.init(rawValue:)) else { return }
        let body = message.dropFirst()
        switch tag {
        case .video:
            guard let flag = body.first else { return }
            if let frame = assembler.receive(Data(body.dropFirst()), isKeyframe: flag != 0) { onInbound?(.video(frame)) }
        case .parameterSets:
            guard let flag = body.first, let codec = VideoCodecID(packetFlags: flag) else { return }
            onInbound?(.videoParameterSets(Data(body.dropFirst()), codec: codec))
        case .audio:
            guard let flag = body.first, let codec = AudioCodecID(packetFlags: flag),
                  let header = AudioChunkHeader.parse(from: Data(body.dropFirst())) else { return }
            onInbound?(.audio(header, Data(body.dropFirst(1 + AudioChunkHeader.size)), codec: codec))
        case .input:
            guard let flag = body.first, let report = ControllerReport.parse(from: Data(body.dropFirst())) else { return }
            onInbound?(.input(report, connected: flag & ControllerReport.connectedFlag != 0))
        case .control:
            let json = Data(body)
            if let control = try? JSONDecoder().decode(ControlMessage.self, from: json) { onInbound?(.control(control)) }
            else { onInbound?(.message(json)) }
        }
    }
}
