<p align="center">
  <img src="docs/assets/phoros-mark.png" width="160" alt="Phoros mark: an amber loop carrying four packets across a dark tile">
</p>

<h1 align="center">Phoros</h1>

<p align="center">
  Real-time media and input transport for Apple platforms.<br>
  One device sends video and audio, the other sends control back. No server, no account, no WebRTC.<br>
  <em>Greek for "bearer": the part that carries the picture, and carries your hand back.</em>
</p>

<p align="center">
  <a href="https://github.com/kevinerikjs/phoros/releases"><img alt="Release" src="https://img.shields.io/github/v/release/kevinerikjs/phoros?display_name=tag&color=F09A1E&labelColor=0A0A0A"></a>
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F09A1E?labelColor=0A0A0A">
  <img alt="Platforms" src="https://img.shields.io/badge/iOS%2015%20%7C%20macOS%2012%20%7C%20tvOS%2015%20%7C%20visionOS%201-F09A1E?labelColor=0A0A0A">
  <img alt="SwiftPM" src="https://img.shields.io/badge/SwiftPM-compatible-F09A1E?labelColor=0A0A0A">
  <a href="https://swiftpackageindex.com/kevinerikjs/phoros"><img alt="Swift Package Index" src="https://img.shields.io/badge/Swift%20Package%20Index-listed-F09A1E?labelColor=0A0A0A"></a>
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-F09A1E?labelColor=0A0A0A"></a>
</p>

<br>

Phoros is a Swift package for real-time streaming between Apple devices: video and audio in one direction, input in the other. It covers the wire protocol and the layers above it. Pairing, framing, codec negotiation, hardware encoders, a virtual game controller, keyboard and click replay: the parts every such app rebuilds, done once and versioned.

```
Mac game       →  iPad, controller input back
iPhone camera  →  Apple TV monitor
Mac desktop    →  Vision Pro remote display, clicks and keys back
iPad app       →  Mac, touch and text back
```

Screen mirroring is one use, not the definition. Phoros ships inside [Beam](https://github.com/kevinerikjs/beam-ios) and [Beacon](https://github.com/kevinerikjs/beacon-macos), an iPhone and Mac pair on the App Store. It is published so you can build a different pair without repeating what they learned in production. Five products, take what you need:

| Product | What it is | Depends on |
|---|---|---|
| **`Phoros`** | The wire contract: packet framing, media headers, handshake and control messages, codec negotiation. | Foundation |
| **`PhorosSession`** | The logic on top: pairing and auth state machines, frame reassembly, audio sequencing, send scheduling, link-driven bitrate, clock sync, quality adaptation, and the transport seam. No I/O. | `Phoros` |
| **`PhorosNetwork`** | The transport: the v1 TCP wire behind the seam, or one call for a framed, size-bounded connection over `Network.framework`. | `Phoros`, `PhorosSession`, Network |
| **`PhorosMedia`** | The codecs, shaped for the wire: H.264/HEVC via VideoToolbox, AAC-LC via AudioToolbox, parameter sets, Annex B, sample buffers. | `Phoros`, VideoToolbox, AudioToolbox |
| **`PhorosInput`** | Input back to the host: controller sampling, a virtual HID gamepad, keyboard, text, media-key and click replay, and tap-to-source geometry. | `Phoros`, GameController, IOKit, CoreGraphics |

## Why

You are writing two apps that talk to each other directly. A Mac that streams a game to an iPad and takes the controller back. An iPhone camera watched on an Apple TV. A Mac desktop on a Vision Pro with clicks going home. The usual options cost more than they look:

- **AirPlay** belongs to Apple. You cannot change what it does.
- **WebRTC** brings a signalling server, ICE, DTLS, SDP and a 40 MB dependency to a problem that lives on one Wi-Fi network.
- **Your own protocol** needs packet framing, codec negotiation, a pairing flow and a versioning story. It also needs an encoder that does not add latency and an AAC clock that stays in sync. You find out in production which part you got wrong.

Phoros is the third option with the production lessons already applied. You bring the source (`ScreenCaptureKit`, a camera, a Metal view), the UI, and the Keychain.

## Install

```swift
dependencies: [
    .package(url: "https://github.com/kevinerikjs/phoros.git", exact: "1.4.1")
],
targets: [
    .target(name: "MyHost", dependencies: [
        .product(name: "Phoros", package: "phoros"),
        .product(name: "PhorosSession", package: "phoros"),
        .product(name: "PhorosNetwork", package: "phoros"),
        .product(name: "PhorosMedia", package: "phoros"),
        .product(name: "PhorosInput", package: "phoros"),
    ])
]
```

Pin an exact version. Two apps that ship on different schedules must not float on a shared wire protocol.

## A host in one screen

```swift
import Phoros, PhorosSession, PhorosNetwork, PhorosMedia

// 1. Accept a connection and frame it.
let link = PhorosConnection(accepting: nwConnection)
var scheduler = SendScheduler()

// 2. Authenticate the client and learn what it can decode.
link.onFrame = { frame in
    guard case .message(let json) = frame,
          let request = try? JSONDecoder().decode(PairingMessage.self, from: json) else { return }
    switch HostAuthenticator.authenticate(request, storedSecret: keychain.secret(for:), capabilities: myCapabilities) {
    case .authenticated(let session):
        send(.control, try! JSONEncoder().encode(session.reply))
        startEncoding(video: session.videoCodec, audio: session.audioCodec)
    case .rejected(let reply):
        send(.control, try! JSONEncoder().encode(reply))
    }
}

// 3. Encode what you capture. The encoder emits exactly what the wire carries.
let encoder = VideoEncoder(configuration: .init(width: 1280, height: 720, frameRate: 60, codec: .hevc))
encoder.onParameterSets = { sets, codec in send(.parameterSets, sets, flags: codec.packetFlags) }
encoder.onFrame = { annexB, pts, isKeyframe in
    guard scheduler.admitVideo(isKeyframe: isKeyframe) else { return }   // drop late frames, never keyframes
    for payload in VideoFragmentHeader.fragment(annexB, frameNumber: next(), presentationTimestamp: pts.phorosMicroseconds, maximumPayloadLength: 1400) {
        enqueue(.video, Packet.encode(isKeyframe ? .videoKeyframe : .video, payload: payload))
    }
}
try encoder.start()
screenCapture.onFrame = encoder.encode

// 4. Send in priority order: control, then audio, then video.
func drain() {
    while let write = scheduler.dequeue() {
        link.connection.send(content: write.data, completion: .contentProcessed { _ in scheduler.completed(write); drain() })
    }
}
```

The client side is the mirror: `PhorosConnection(to:)`, `ClientCapabilities.authRequest(secret:)`, `PairingClient.interpret`, `FrameAssembler`, `VideoFormat.makeDescription`, `VideoFormat.makeSampleBuffer`, `AACDecoder`. [docs/session.md](docs/session.md) walks both sides.

## What the production lessons are

Every type in `PhorosSession` exists because a shipped build got something wrong once:

| Type | The incident it prevents |
|---|---|
| `PeerCapabilities` | A client that never said it could decode AAC was sent AAC. It played compressed bytes as samples: white noise into headphones. Absence of a capability is now never read as "probably fine". |
| `VideoHold` | A client paused video during warm-up. The host dropped the keyframe and never re-sent parameter sets. Black stream for the rest of the session. Resume now always repairs both. |
| `AudioSequenceGuard` | One backwards sequence number muted audio for the whole session, because the drop path never advanced the counter. A restart now re-anchors instead of latching. |
| `SendScheduler` | TCP never drops, so an encoder faster than the link built a backlog that grew forever: two frames a second, ten seconds late. Late video is dropped, audio goes first, counters re-anchor when the link drains. |
| `RoundTripProbe` | One lost pong left the "probe outstanding" flag set forever and RTT was never measured again. |
| `ControlMessage` (typed by `type`) | A shape-based decoder matched an all-optional payload against any JSON object and misread every message after it in the list. |
| `AACEncoder` (priming clock) | AAC's 2112-frame priming delay is a permanent A/V offset unless the encoder stamps each unit earlier by exactly that much. The decoder must not compensate again. |

[docs/compatibility.md](docs/compatibility.md) tells each story in full and states the rules that follow.

## The rules that keep old and new peers talking

1. **Add, never change.** A new feature is a new optional JSON field, a new capability flag or a new packet type. Existing bytes and keys keep their meaning forever.
2. **Absence is never optimistic.** A peer that did not advertise something cannot do it. `PeerCapabilities` makes the conservative reading the default.
3. **The packet is the authority for media.** Negotiation says what a host may send. The flags on each packet say what it did send. Codec id 0 is the original codec forever.
4. **Unknown means drop.** Reject an unknown codec id, message type or payload shape, and keep the session.

## Documentation

- [docs/wire-format.md](docs/wire-format.md): every byte and every JSON field.
- [docs/session.md](docs/session.md): building a host and a client with `PhorosSession` and `PhorosNetwork`.
- [docs/media.md](docs/media.md): the encoders and decoders, and what they lock in.
- [docs/input.md](docs/input.md): input back to the host: game controller, keyboard, text, media keys, clicks.
- [docs/compatibility.md](docs/compatibility.md): the rules, and the incidents behind them.

## Testing

```bash
swift test
```

123 tests. The `Phoros` suite pins the exact bytes of every header and the exact JSON of every message as shipped peers send them. A wire break fails here first. The `PhorosSession` suite replays the incidents above. The `PhorosMedia` suite builds a real H.264 format description from real SPS/PPS bytes and round-trips audio through the AAC encoder and decoder. The `PhorosInput` suite pins the HID report descriptor, the mapping from a wire report to HID bytes, and the tap-to-source geometry.

Before you release an app built on Phoros, also test on real devices in three combinations:

- new client with new host
- new client with the previous host
- previous client with new host

## Contributing

Open an issue before you propose a wire change. Include the compatibility story: what an older peer sees, what a newer peer sees, and a fixture for each. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
