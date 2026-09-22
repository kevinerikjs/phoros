<p align="center">
  <img src="docs/assets/phoros-mark.png" width="160" alt="Phoros mark: an amber loop carrying four packets across a dark tile">
</p>

<h1 align="center">Phoros</h1>

<p align="center">
  Real-time media and input transport for Apple platforms.<br>
  One device sends video and audio, the other sends control back. Two devices, no server, no account.
</p>

<p align="center">
  <a href="https://github.com/kevinerikjs/phoros/releases"><img alt="Release" src="https://img.shields.io/github/v/release/kevinerikjs/phoros?display_name=tag&color=F09A1E&labelColor=0A0A0A"></a>
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F09A1E?labelColor=0A0A0A">
  <img alt="Platforms" src="https://img.shields.io/badge/iOS%2015%20%7C%20macOS%2012%20%7C%20tvOS%2015%20%7C%20visionOS%201-F09A1E?labelColor=0A0A0A">
  <img alt="SwiftPM" src="https://img.shields.io/badge/SwiftPM-compatible-F09A1E?labelColor=0A0A0A">
  <a href="https://swiftpackageindex.com/kevinerikjs/phoros"><img alt="Swift Package Index" src="https://img.shields.io/badge/Swift%20Package%20Index-listed-F09A1E?labelColor=0A0A0A">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-F09A1E?labelColor=0A0A0A">
</p>

<br>

Phoros is a Swift package for streaming video, audio and input between two Apple devices you control, over the local network or a private overlay. It is the wire protocol and the layers directly above it: pairing, framing, codec negotiation, hardware encode and decode, send scheduling, bitrate control, clock sync, a virtual game controller, keyboard and click replay.

It does not capture a screen, draw a frame, play audio or own your UI. Those stay in your app.

```
Mac game       →  iPad, controller input back
iPhone camera  →  Apple TV monitor
Mac desktop    →  Vision Pro, clicks and keys back
iPad app       →  Mac, touch and text back
```

## What it implements

**Transport, v1 (`PhorosNetwork`)**
- Length-prefixed framing over one TCP connection, with a bounded frame size and a 10-byte packet header.
- Video fragmentation and reassembly at a configurable MTU (1400 bytes by default).
- A send scheduler with three lanes (control, audio, video). Video is shed by queue age and by a byte budget derived from the kernel's unacknowledged bytes. Audio is never shed for longer than one second.
- Bitrate control from the round trip of a probe on the media connection, which is the one signal that sees both the sender's socket buffer and the access point.
- Heartbeats, and a 20 ms keep-awake write that holds a phone's Wi-Fi radio out of power save while video is paused.

**Transport, v2 (`PhorosCore`)**

This is WebRTC's transport, and calling it anything else would be dishonest. It is ICE, DTLS, SRTP, RTP and SCTP data channels, driven by [str0m](https://github.com/algesten/str0m), a sans-IO WebRTC implementation in Rust by Martin Algesten. What Phoros leaves out is the part that makes WebRTC heavy for two devices you own: no SDP, no signalling server, no browser peer connection, no media engine, no TURN. The offer is three lines of text in a control message on a connection that is already authenticated.

- A UDP peer built on str0m: ICE, DTLS 1.2, SRTP, SCTP.
- Video as RTP ([RFC 3550](https://www.rfc-editor.org/rfc/rfc3550)) with H.264 ([RFC 6184](https://www.rfc-editor.org/rfc/rfc6184)) and H.265 ([RFC 7798](https://www.rfc-editor.org/rfc/rfc7798)) packetization, retransmission ([RFC 4588](https://www.rfc-editor.org/rfc/rfc4588)), generic NACK and PLI ([RFC 4585](https://www.rfc-editor.org/rfc/rfc4585)), and transport-wide congestion control feedback.
- A NACK that fires every 5 ms instead of the usual RTT-derived interval, and a 6-frame receive hold-back, both tuned for a one-hop link where the round trip is under 3 ms.
- Datagram-level XOR parity: one repair datagram per 8 media datagrams, applied to SRTP ciphertext, so a single loss inside a frame is repaired without a retransmission round trip.
- Three SCTP lanes ([RFC 8831](https://www.rfc-editor.org/rfc/rfc8831)): reliable and ordered for parameter sets and control, unordered with a 50 ms lifetime for input, unordered with a 400 ms lifetime and receive-side reordering for audio.
- No signalling server. The offer and answer travel as two control messages on the v1 transport, which also carries input while the peer connects and takes media back on fallback.

**Session logic (`PhorosSession`)**
- Pairing and authentication state machines, capability negotiation, frame reassembly, audio sequencing, send policy, bitrate control, clock sync, and `PhorosRealtimeTransport`, the seam both transports implement.
- Value types, no locking, no I/O. One per connection, touched from one queue.

**Media (`PhorosMedia`)**
- H.264 and HEVC through VideoToolbox, hardware only, real-time mode, no frame reordering, with the low-latency rate control mode where the hardware offers it.
- AAC-LC through AudioToolbox, with the 2112-frame priming delay cancelled at the sender so audio and video stay aligned.
- Annex B, parameter sets and `CMSampleBuffer` bridging in both directions.

**Input (`PhorosInput`)**
- A virtual HID gamepad on a macOS host, presented as an Xbox Wireless Controller or a DualShock 4, with analog triggers and both sticks.
- Controller sampling on the client, keyboard, text, media keys, and clicks mapped from the client's view back to screen coordinates.

## Products

| Product | Contents | Depends on |
|---|---|---|
| **`Phoros`** | The wire contract: packet framing, media headers, handshake and control messages, codec ids. | Foundation |
| **`PhorosSession`** | Session logic and the transport seam. No I/O. | `Phoros` |
| **`PhorosNetwork`** | The v1 TCP wire, and framed connections over `Network.framework`. | `Phoros`, `PhorosSession` |
| **`PhorosMedia`** | Encoders and decoders shaped for the wire. | `Phoros`, VideoToolbox, AudioToolbox |
| **`PhorosInput`** | Input replay on the host, sampling on the client. | `Phoros`, GameController, IOKit, CoreGraphics |
| **`PhorosCore`** | The v2 UDP peer and its transport. Ships as a prebuilt XCFramework. | `Phoros`, `PhorosSession` |

`PhorosCore` is the only product with a binary dependency. Its Rust core is built for macOS (arm64, x86_64), iOS and the iOS simulator, published as a release asset, and pinned by checksum in `Package.swift`. You do not need a Rust toolchain to depend on it.

It vendors [str0m](https://github.com/algesten/str0m) 0.23.1 (MIT, Martin Algesten) with two patches, both in `Core/phoros-core/vendor/str0m` and both aimed at a single Wi-Fi hop rather than the internet:

- `set_nack_min_interval`, so the retransmission request can fire every 5 ms instead of at an RTT-derived interval.
- The pacer never holds a packet. Smoothing a congestion-controlled stream is right across a wide-area path and wrong across one hop, where it added 100 to 1000 ms of jitter.

Everything else in that directory is upstream. Cryptography is `str0m-apple-crypto`, which uses CommonCrypto and Security, so nothing links OpenSSL.

## Requirements

| | |
|---|---|
| Swift | 5.9 |
| Platforms | iOS 15, macOS 12, tvOS 15, visionOS 1 |
| Xcode | 15 or newer |
| Dependencies | None outside Apple's SDKs, plus the prebuilt core for `PhorosCore` |

## Install

```swift
dependencies: [
    .package(url: "https://github.com/kevinerikjs/phoros.git", exact: "1.4.2")
],
targets: [
    .target(name: "MyHost", dependencies: [
        .product(name: "Phoros", package: "phoros"),
        .product(name: "PhorosSession", package: "phoros"),
        .product(name: "PhorosNetwork", package: "phoros"),
        .product(name: "PhorosMedia", package: "phoros"),
        .product(name: "PhorosInput", package: "phoros"),
        .product(name: "PhorosCore", package: "phoros"),   // optional, the v2 transport
    ])
]
```

Pin an exact version. Two apps that ship on different schedules must not float on a shared wire protocol.

## A host

`PhorosLegacyTransport` owns framing, fragmentation, scheduling, shedding, probing and bitrate. You own capture, codecs and policy.

```swift
import Phoros, PhorosSession, PhorosNetwork, PhorosMedia

let transport = PhorosLegacyTransport(accepting: connection, options: .init(role: .host))
let encoder = VideoEncoder(configuration: .init(width: 1920, height: 1080, frameRate: 60, codec: .hevc))

// The transport asks for what only the encoder can give.
transport.onKeyframeNeeded = { encoder.requestKeyframe() }
transport.onBitrateChange = { encoder.setBitrate($0) }

// Authenticate, then start encoding what the client said it can decode.
transport.onInbound = { inbound in
    guard case .message(let json) = inbound,
          let request = try? JSONDecoder().decode(PairingMessage.self, from: json) else { return }
    switch HostAuthenticator.authenticate(request, storedSecret: keychain.secret(for:), capabilities: myCapabilities) {
    case .authenticated(let session):
        transport.sendMessage(try! JSONEncoder().encode(session.reply))
        transport.setStreaming(true)
        try? encoder.start()
    case .rejected(let reply):
        transport.sendMessage(try! JSONEncoder().encode(reply))
    }
}

encoder.onParameterSets = { sets, codec in transport.sendVideoParameterSets(sets, codec: codec) }
encoder.onFrame = { annexB, pts, isKeyframe in
    transport.sendVideo(annexB, presentationTimestamp: pts.phorosMicroseconds, isKeyframe: isKeyframe)
}
transport.start()

// Ask before you encode. A frame the link cannot take is cheaper never encoded.
screenCapture.onFrame = { sample in
    guard transport.acceptsVideoFrame else { return }
    encoder.encode(sampleBuffer: sample)
}
```

## A client

```swift
let transport = PhorosLegacyTransport(to: endpoint)
transport.onReady = { transport.sendMessage(try! JSONEncoder().encode(me.authRequest(secret: stored))) }
transport.onInbound = { inbound in
    switch inbound {
    case .videoParameterSets(let sets, let codec):
        description = VideoFormat.makeDescription(parameterSets: sets, codec: codec)
    case .video(let frame):
        guard let description else { return }
        // Stamp with the receiver's own clock. The sender's timestamps are on the sender's clock.
        let sample = VideoFormat.makeSampleBuffer(annexB: frame.bitstream, formatDescription: description,
                                                  presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
        displayLayer.enqueue(sample)
    case .audio(let header, let body, let codec):
        play(body, codec: codec, at: header.presentationTimestamp)
    case .message(let json):
        handleAuthReply(json)
    default: break
    }
}
transport.start()
```

[docs/session.md](docs/session.md) covers pairing, the full handshake and both sides in order. [docs/realtime.md](docs/realtime.md) adds the v2 transport on top of this, in about thirty lines.

## Measured

Method: a harness on the client presses a virtual controller button, the host replays it into its virtual gamepad, a window under the pointer flips black to white, the encoder and the wire carry that frame, and the client's decoder reports the luma flip. Both ends stamp a shared monotonic clock, so the number is press to decoded frame with no display added. Source in the reference host's `tools/latency-harness`.

Reference host: Mac mini (M4), 1080p, hardware HEVC. Client: iPhone 13 Pro Max, 120 Hz. One 5 GHz Wi-Fi hop, no wired path, AWDL off.

| Scenario | p50 | p90 | p95 | p99 |
|---|---:|---:|---:|---:|
| v1 (TCP), 6 Mbps | 24.5 | 26.0 | 27.0 | 29.0 |
| v2 (UDP), 6 Mbps | 23.9 | 28.8 | 30.0 | 32.0 |
| v1 (TCP), 10 Mbps | 36.0 | 44.0 | 62.0 | 75.0 |
| v2 (UDP), 10 Mbps | 30.7 | 37.7 | 38.1 | 46.3 |
| v1 (TCP), 2.5% loss | 30-34 | | 45-152 | 151-294 |
| v2 (UDP), 2.5% loss | 27.0 | 30.0 | 30.0 | 35.0 |

Milliseconds. The same harness measured 78 ms p50 on this pair before the 1.4.0 work, at 60 fps with no bitrate control and no capture gate.

Two results worth stating plainly, because they shape the defaults:

- **Bitrate is an input-latency control on iPhone.** Above roughly 7 Mbps of sustained downlink, an iPhone adds 6 to 9 ms to everything it transmits, on any protocol. Reproduced with a bulk UDP sender to a closed port during an unrelated TCP video session. An app that wants the tightest input response caps video rather than spending the link.
- **UDP wins where the link is lossy, not where it is clean.** On an idle network the two transports are within a millisecond. Under 2.5% loss the v1 tail goes to a quarter of a second while v2 stays at 35 ms, because a repaired datagram does not stall the frames behind it.

## Alternatives

| | What it costs you |
|---|---|
| **AirPlay** | Apple's, and closed. No control channel back, no codec or latency knobs, no say in what it does. |
| **A browser WebRTC stack** | A signalling server, SDP, TURN and a large dependency, to reach a device on the same Wi-Fi as you. Media goes through the browser's engine, so the encoder settings that matter here are not yours to set. |
| **A WebRTC SDK (LiveKit, Daily, Agora)** | A hosted SFU and a per-minute bill, for a one-to-one link over the local network. Built for many participants over the internet, which is the opposite problem. |
| **Moonlight and Sunshine** | Excellent at exactly one thing, PC game streaming, and shaped around NVIDIA's protocol. Not a library, and not Apple-native on the host side. |
| **Rolling your own** | The work in this repository: framing, fragmentation, codec negotiation, a pairing flow, encoder settings that do not add latency, an AAC clock that stays in sync, and a compatibility story for two apps that update separately. |

Phoros is narrower than all of them on purpose: two Apple devices, one owner, one network.

## Who ships it

[Beam](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962) (iOS, App Store) and [Beacon](https://github.com/kevinerikjs/beacon-macos) (macOS, open source) are a screen-streaming pair built entirely on this package: pairing, both transports, controller passthrough, click and keyboard replay. Beacon is the reference host and its source is public, including the latency harness that produced the table above.

## Compatibility

Two apps built on this protocol update on different schedules, in both directions. Four rules follow, and the package enforces them where it can:

1. **Add, never change.** A new feature is a new optional JSON field, a new capability flag or a new packet type. Existing bytes and keys keep their meaning forever.
2. **Absence is never optimistic.** A peer that did not advertise a capability does not have it. `PeerCapabilities` applies that reading once so application code never sees a raw optional.
3. **The packet is the authority for media.** Negotiation says what a host may send. The flags on each packet say what it did send. Codec id 0 is the original codec forever.
4. **Unknown means drop.** An unknown packet type, codec id, message type or payload shape is discarded and the session continues.

The handshake carries no version number. Ask about the feature, not the version. [docs/compatibility.md](docs/compatibility.md) has the rules in full, with the production incident behind each one.

## Documentation

| | |
|---|---|
| [docs/wire-format.md](docs/wire-format.md) | Every byte and every JSON field, both transports. |
| [docs/session.md](docs/session.md) | Building a host and a client, in order. |
| [docs/realtime.md](docs/realtime.md) | The v2 UDP transport: offer, answer, lanes, loss repair, fallback. |
| [docs/media.md](docs/media.md) | Encoders and decoders, and the settings they lock in. |
| [docs/input.md](docs/input.md) | Controller, keyboard, text, media keys and clicks. |
| [docs/compatibility.md](docs/compatibility.md) | The rules, and the incidents behind them. |
| [Core/README.md](Core/README.md) | The Rust core: its C ABI, its guarantees, how it is built and released. |

## Tests

```bash
swift test
```

136 tests, no network and no hardware required.

| Suite | Tests | What it pins |
|---|---:|---|
| `PhorosTests` | 45 | The exact bytes of every header and the exact JSON of every message, as shipped peers write them. A wire break fails here first. |
| `PhorosSessionTests` | 42 | Pairing and auth state machines, capability defaults, reassembly, audio sequencing, scheduling and shedding, clock sync. Each incident in the compatibility doc has a test. |
| `PhorosInputTests` | 17 | The HID report descriptor byte for byte, the wire-report to HID mapping, and the tap-to-source geometry. |
| `PhorosMediaTests` | 15 | A real format description from real SPS/PPS bytes, and an audio round trip through the AAC encoder and decoder. |
| `PhorosCoreTests` | 13 | The C ABI boundary: null and oversize arguments, poisoning after a panic, a two-peer loopback, and the XOR repair. |
| `PhorosNetworkTests` | 4 | Frame decoding, length bounds and the transport options. |

The Rust core has its own suite (`cd Core/phoros-core && cargo test`), including an ICE-to-media loopback between two peers in one process.

Before you release an app built on this package, test three real-device combinations: new client with new host, new client with the previous host, previous client with new host. The last two find the bugs.

## Contributing

Open an issue before you propose a wire change, and include the compatibility story: what an older peer sees, what a newer peer sees, and a fixture for each. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

<sub>Phoros, φόρος, Greek for "bearer": the thing that carries.</sub>
