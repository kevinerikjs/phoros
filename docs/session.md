# Building a host and a client

`PhorosSession` holds the decisions a peer has to make during a session. `PhorosNetwork` moves the bytes. Neither knows about your UI, your Keychain or your capture source. This page walks a host and a client from connection to media, naming the type for each step.

Every `PhorosSession` type is a value type with no locking. Own one per connection and touch it from one queue.

## The connection

Both sides use `PhorosConnection`. It reads the four-byte length and checks it against `maximumFrameLength` before it allocates. Then it reads the body and classifies it as a packet or a bare JSON message.

```swift
let link = PhorosConnection(to: endpoint)              // client
let link = PhorosConnection(accepting: nwConnection)   // host, from an NWListener

link.onReady = { … }
link.onWaiting = { error in … }   // no route right now. Start a timer and cancel() if it expires
link.onFrame = { frame in … }
link.onEnd = { reason in … }      // closedByPeer, transportFailed, protocolViolation, cancelled
link.start()

link.send(bytes)                  // adds the length prefix
```

A frame is `.packet(DecodedPacket)` or `.message(Data)`. The host sends everything as a packet. The client sends JSON bare and wraps only binary payloads. Handle both forms on both sides.

## Pairing, once

The person reads a six-digit code from the host's screen and types it on the client. The code never crosses the wire.

**Client**

```swift
let me = ClientCapabilities(deviceName: UIDevice.current.name, deviceID: stableID)
link.send(try encoder.encode(me.hello()))

// on a frame:
switch PairingClient.interpret(message) {
case .codeRequested(let hostName): showCodeEntry(for: hostName)
case .paired(let secret, let host, let hostName): keychain.store(secret, for: hostName); remember(host.remoteHosts)
case .failed(let reason): show(reason)
default: break
}

// when the person types the code:
link.send(try encoder.encode(me.codeVerify(typed)))
```

**Host**

```swift
var pairing = PairingHost(capabilities: myCapabilities)

// on hello:
if let (challenge, code) = pairing.begin(hello: message) {
    showCode(code)                                     // on screen, for the person
    send(challenge)
}

// on codeVerify:
switch pairing.verify(message) {
case .paired(let secret, let reply): keychain.store(secret, for: pairing.peerDeviceID!); send(reply); hideCode()
case .rejected(let reply): send(reply)                 // the attempt stays open for another try
case .ignored: break                                   // expired or not a codeVerify
}
```

`PairingHost.begin` accepts a `validFor` interval (default five minutes). `verify` ignores a code after that interval.

## Authentication, every time

**Client**

```swift
link.send(try encoder.encode(me.authRequest(secret: storedSecret)))

// on the reply:
if case .authenticated(let host, _, _, _) = PairingClient.interpret(message) {
    canPauseVideo = host.supportsVideoHold
    canToggleAudio = host.supportsAudioToggle
    buttons = host.controls
}
```

`host` is a `PeerCapabilities`. Every absent field has already been given its conservative meaning.

**Host**

```swift
switch HostAuthenticator.authenticate(message, storedSecret: keychain.secret(for:), capabilities: myCapabilities) {
case .authenticated(let session):
    send(session.reply)
    audioCodec = session.audioCodec      // .aacLC only if the client listed it
    videoCodec = session.videoCodec      // .hevc only if the client listed it
    wantsAudio = session.peer.wantsAudio
case .rejected(let reply):
    send(reply); link.cancel()
}
```

Pass `audioPreferences: [.pcmFloat32]` to force PCM for a session, for example from a "safe mode" default.

## The transport seam

Since 1.4.0 an application does not have to assemble the pieces below by hand. `PhorosRealtimeTransport` (in `PhorosSession`) is the seam between an application and the wire: it sends and receives the units the application thinks in (a whole video frame, an audio chunk, a controller report, a control message) and owns framing, fragmentation, reassembly, scheduling, shedding, the link probe, bitrate control, heartbeats and the radio keep-awake. `PhorosLegacyTransport` (in `PhorosNetwork`) is the v1 TCP wire behind it, byte for byte what Beam 3 and Beacon 1.4 speak. A later transport implements the same protocol and the application does not change.

```swift
// host
let transport = PhorosLegacyTransport(accepting: connection, options: LegacyTransportOptions(role: .host))
transport.onInbound = { inbound in
    switch inbound {
    case .message(let json): handlePairing(json)                 // hello, code_verify, auth_request
    case .control(let message): handle(message)                  // pings and pongs are already answered
    case .input(let report, let connected): gamepad.handle(report, connected: connected)
    case .unknownControl: break                                  // a newer peer; see compatibility.md
    default: break
    }
}
transport.onKeyframeNeeded = { encoder.requestKeyframe() }
transport.onBitrateChange = { encoder.setBitrate($0) }
transport.start()
// after auth_success
transport.setSendPolicy(audioCodec == .pcmFloat32 ? .pcmAudio : SendPolicy())
transport.setMaximumBitrate(preset.bitrate)
transport.setStreaming(true)
capture.onFrame = { frame in if transport.acceptsVideoFrame { encoder.encode(frame) } }
encoder.onParameterSets = { transport.sendVideoParameterSets($0, codec: $1) }
encoder.onFrame = { annexB, pts, key in transport.sendVideo(annexB, presentationTimestamp: pts, isKeyframe: key) }

// client
let transport = PhorosLegacyTransport(to: endpoint)
transport.onInbound = { inbound in
    switch inbound {
    case .video(let frame): decode(frame)
    case .videoParameterSets(let sets, let codec): rebuildDecoder(sets, codec)
    case .audio(let header, let body, let codec): play(header, body, codec)
    case .message(let json): handlePairing(json)
    case .control(let message): handle(message)
    default: break
    }
}
transport.start()
transport.sendMessage(authRequestJSON)
transport.sendInput(report, connected: true)     // latest value, never queued behind video
```

`metrics` is a snapshot (round trip, queueing delay, bitrate, drain rate, pending video bytes, drops) safe from any thread. `onTrace` reports the points a harness stamps. What follows is what the transport does inside, for an application that needs its own transport.

## Sending media

The host owns one `SendScheduler` per connection.

```swift
var scheduler = SendScheduler()                      // or SendPolicy.pcmAudio for a PCM-only client

// capture, before the encoder sees the frame
guard scheduler.admitCapture() else { return }       // the link is behind: skip it, no reference breaks
encoder.encode(captured)

// video, from the encoder callback
guard scheduler.admitVideo(isKeyframe: isKeyframe) else { return }
let packets = VideoFragmentHeader.fragment(annexB, frameNumber: n, presentationTimestamp: pts, maximumPayloadLength: 1400)
    .map { Packet.encode(isKeyframe ? .videoKeyframe : .video, payload: $0).lengthPrefixed() }
scheduler.enqueueVideoFrame(packets, isKeyframe: isKeyframe)   // one write per frame

// audio, from the encoder callback
guard scheduler.admitAudio() else { return }
let chunk = AudioChunkHeader(sequenceNumber: seq, presentationTimestamp: pts).serialized() + accessUnit
scheduler.enqueue(Packet.encode(.audio, flags: codec.packetFlags, payload: chunk).lengthPrefixed(), lane: .audio)

// control
scheduler.enqueue(Packet.encode(.control, payload: json).lengthPrefixed(), lane: .control)

// drain, after every enqueue and every completion
while let write = scheduler.dequeue() {
    link.connection.send(content: write.data, completion: .contentProcessed { _ in
        scheduler.completed(write)
        drain()
    })
}
```

`admitCapture` and `admitVideo` refuse when the video between the encoder and the peer is above the budget: bytes queued here, bytes handed to the transport, and bytes the transport reports it still holds (`transportBacklog`, the kernel's unacknowledged bytes on TCP; a write completes when the kernel takes it, not when the peer has it). The budget is `policy.maximumQueuedBytes`, or less once the drain rate says that many bytes would take longer than `policy.maximumQueueDelay` to send. Refuse at capture when you can: a skipped capture costs nothing, while a frame dropped after encoding breaks the reference chain, so `admitVideo` then refuses every delta until a keyframe is enqueued and sets `needsKeyframe` for you to ask the encoder. A keyframe is never refused. Queued delta frames older than `policy.maximumVideoQueueAge` are shed at `dequeue`. `admitAudio` refuses only on the audio backlog and never for longer than `policy.maximumAudioSilence`. `dequeue` returns control first, then audio, then video, and holds at `policy.maximumConcurrentWrites` outstanding writes.

### Bitrate from the link

The transport never drops, so when the encoder produces more than the link carries, nothing is lost: the bytes wait in the sender's socket buffer and the access point, and every frame arrives late by that much. The peer sees a smooth stream and reports it healthy. The one signal that shows the queue is the round trip of a small control message on the same connection, because it waits behind the same bytes. `BitrateController` reads it.

```swift
var bitrate = BitrateController(maximum: preset.bitrate)   // starts at 4 Mbps and climbs

// five times a second while streaming
if probe.shouldSend() { pingSentAt = now; send(.ping) }

// on pong
if let rtt = probe.receivedPong(), pingSentAt > lastKeyframeBurstEnd {   // a ping behind a keyframe measures the keyframe
    bitrate.observe(roundTrip: rtt)
    if let next = bitrate.evaluate() { encoder.setBitrate(next) }       // live, no restart
}
```

The controller cuts 0.7x once the queueing delay (round trip minus its recent floor) has held or grown for two samples (one high sample is a Wi-Fi spike, two are a queue), 0.5x above 150 ms, and climbs 1.15x every two seconds once it is clear. A new link starts at 4 Mbps and climbs 1.5x every 0.6 s until the first cut. `setMaximum` follows a preset change. The `QualityLadder` below stays the structural fallback for a link that cannot carry the preset at all.

## Pause and resume

```swift
var hold = VideoHold()

case .videoPause:
    hold.pause()
    scheduler.dropQueuedVideo()
case .videoResume:
    for action in hold.resume() {
        switch action {
        case .resendParameterSets: send(.parameterSets, cachedSets, flags: codec.packetFlags)
        case .requestKeyframe: encoder.requestKeyframe()
        }
    }
```

Send video only while `hold.isHeld` is false. A client sends `.videoPause` only to a host whose `supportsVideoHold` is true.

## Receiving media

```swift
var assembler = FrameAssembler()
var sequenceGuard = AudioSequenceGuard()

case .parameterSets:
    guard let codec = VideoCodecID(packetFlags: packet.flags) else { return }          // unknown: drop
    formatDescription = VideoFormat.makeDescription(parameterSets: packet.payload, codec: codec)

case .video, .videoKeyframe:
    if let frame = assembler.receive(packet.payload, isKeyframe: packet.type == .videoKeyframe) {
        display(VideoFormat.makeSampleBuffer(annexB: frame.bitstream, formatDescription: formatDescription, presentationTime: hostNow))
    }

case .audio:
    guard let codec = AudioCodecID(packetFlags: packet.flags),                          // unknown: drop
          let header = AudioChunkHeader.parse(from: packet.payload) else { return }
    switch sequenceGuard.accept(header.sequenceNumber) {
    case .duplicate: return
    case .restarted: player.resync()
    case .accept: break
    }
    play(packet.payload.dropFirst(AudioChunkHeader.size), codec: codec, at: header.presentationTimestamp)
```

## Liveness

```swift
var probe = RoundTripProbe()
var heartbeat = HeartbeatMonitor(timeout: 30)

// on a timer
if probe.shouldSend() { send(.ping) }
if heartbeat.isTimedOut() { link.cancel() }

// on any inbound frame
heartbeat.heard()

// on pong
if let rtt = probe.receivedPong() { showLinkQuality(rtt) }
```

## Frame rate

A client sends the highest frame rate it wants, normally its display's refresh rate, and the host captures at that rate when its own display can supply it. A client that sends nothing gets the preset's rate.

```swift
// client
ClientCapabilities(deviceName: name, deviceID: id, maximumFrameRate: Double(screen.maximumFramesPerSecond))

// host, when a client joins or leaves, and on every preset change
let rate = sessions.map { $0.peer.videoFrameRate(preset: preset.frameRate, hostRefreshRate: display.refreshRate) }.min()
```

Only the 60 fps presets are raised. A 165 Hz Mac and a 120 Hz phone give 120 fps; each frame the host adds is a fresher frame at the phone's next refresh. Measured on the reference host, button to decoded frame at 1080p60 went from 27.5/32.9 ms (p50/p95) at 60 fps to 19.1/25.0 at 120.

## Clock sync

The host stamps every frame with its capture time on its own clock. A client that wants to know how old a frame is when it arrives needs the offset between the two clocks.

```swift
// client
var clock = ClockSync()
// four times a second, if host.supportsClockSync
send(.clockProbe(clock.probe(now: nowMicros())))
// on reply
case .clockReply(let reply): clock.reply(reply, now: nowMicros())
// on every assembled frame
if let age = clock.age(ofPresentationTimestamp: frame.presentationTimestamp, now: nowMicros()) { meter.record(age) }

// host
case .clockProbe(let probe):
    send(.clockReply(ClockReply(id: probe.id, sentAt: probe.sentAt, receivedAt: nowMicros(), repliedAt: nowMicros())))
```

`ClockSync` keeps the offset from the sample with the shortest recent round trip, so queueing on the way makes an estimate worse only until a clean sample arrives. Times are microseconds of `CMClockGetHostTimeClock`, the clock the reference host stamps video with.

## Quality adaptation

The host owns a `QualityLadder` with the presets it is willing to move between, lowest first.

```swift
var ladder = QualityLadder(tiers: [.p360_30, .p480_30, .p720_30, .p1080_30])

case .qualityFeedback(let quality): ladder.feedback(quality)
case .qualityRequest(let preset):
    if preset == .auto { autoTimer.start() } else { autoTimer.stop(); apply(preset) }

// every two seconds while in auto
if let next = ladder.evaluate() { apply(next) }

func apply(_ preset: QualityPreset) {
    encoder.reconfigure { $0.width = Int32(preset.width); $0.height = Int32(preset.height); $0.frameRate = preset.frameRate }
    send(.qualityChanged(preset))
}
```
