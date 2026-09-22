# The realtime transport (v2)

`PhorosCore` is a second implementation of `PhorosRealtimeTransport`, over UDP instead of TCP. An application that already talks to the seam switches by constructing a different object.

It exists for one reason: on a reliable, ordered byte stream, a lost packet stops every packet behind it until the retransmission arrives. On a clean network that costs nothing and the v1 transport is a millisecond faster. On a network with real loss it is the difference between a 35 ms tail and a 294 ms one. See [the measurements in the README](../README.md#measured).

The v1 transport does not go away. It carries pairing, authentication and control, it carries input while the peer is connecting, and it takes media back when the peer fails.

## Shape

```
           ┌──────────────── TCP (v1) ────────────────┐
client ────┤ pairing, auth, control, transport offer  ├──── host
           │ input while the peer connects            │
           └──────────────────────────────────────────┘
           ┌──────────────── UDP (v2) ────────────────┐
           │ RTP: video, with RTX, NACK, PLI, XOR FEC │
           │ SCTP lane 0: parameter sets, control     │
           │ SCTP lane 1: input, 50 ms lifetime       │
           │ SCTP lane 2: audio, 400 ms lifetime      │
           └──────────────────────────────────────────┘
```

There is no signalling server and no SDP. ICE credentials and the DTLS fingerprint travel as one string in a control message on the connection that is already authenticated.

## Offer and answer

**Host**, after `auth_success`:

```swift
import PhorosCore

guard let peer = RealtimePeer(isHost: true, localAddress: "\(localIP):7981") else { return }
let media = PhorosPeerTransport(peer: peer, queue: stateQueue)
media.codec = negotiatedVideoCodec
media.onReady = { [self] in rtcReady = true }                    // media moves to the peer here
media.onEnd = { [self] _ in fallBack(reason: "peer ended") }
media.onKeyframeNeeded = { encoder.requestKeyframe() }           // the receiver sent a PLI
media.onLinkStateChange = { up in if !up { fallBack(reason: "ice down") } }
guard peer.runOwnSocket() == 0 else { return }                   // the core owns the socket and its thread

tcp.sendControl(.transportOffer(TransportOffer(
    kind: "rtc2",
    address: "\(localIP):7981",
    info: peer.localInfo,                                        // "ufrag\npass\nsha-256 fingerprint"
    hostMicros: CMClockGetTime(CMClockGetHostTimeClock()).phorosMicroseconds
)))
```

**Client**, on `.transportOffer` where `kind == "rtc2"`:

```swift
guard let peer = RealtimePeer(isHost: false, localAddress: "\(myIP):7982") else { return }
let media = PhorosPeerTransport(peer: peer, queue: queue)
media.hostTimeReference = offer.hostMicros                       // see "Timestamps" below
media.onInbound = { inbound in … }                               // the same switch as the v1 transport
media.onEnd = { _ in tcp.sendControl(.transportFallback) }
guard peer.runOwnSocket() == 0 else { return }
peer.setRemote(info: offer.info, address: offer.address, nowMicros: 0)
tcp.sendControl(.transportAnswer(TransportOffer(kind: "rtc2", address: "\(myIP):7982", info: peer.localInfo)))
```

**Host**, on `.transportAnswer`: `peer.setRemote(info:address:nowMicros:)`. ICE, DTLS and SCTP complete from there, `onReady` fires on both sides, and the host starts sending media to `media` instead of `tcp`.

A client that does not implement this ignores an unknown control message and stays on TCP, which is rule 4 of [compatibility.md](compatibility.md) doing its job. `kind` is checked so a future third transport can use the same two messages.

## Lanes

Video is RTP on its own SSRC, not a data channel. Everything else is SCTP, in three pre-negotiated channels with the same ids on both sides:

| Lane | Id | Reliability | Carries |
|---|---:|---|---|
| reliable | 0 | reliable, ordered | parameter sets, control messages, keyframes |
| realtime | 1 | unordered, 50 ms lifetime | input reports, frame acknowledgements |
| audio | 2 | unordered, 400 ms lifetime | audio chunks |

The lifetimes are the point. An input report that is 50 ms old has been replaced by a newer one, so delivering it is worse than dropping it. An audio chunk that is 300 ms old still fits inside the receiver's buffer, and a hole in the sound is worse than a late chunk, so audio gets eight times the lifetime and its own lane rather than queueing behind video.

The audio lane is unordered, so a chunk can overtake the one before it. `PhorosPeerTransport` holds an out-of-order chunk for `audioReorderHold` (30 ms) waiting for the one it passed, then releases what it has in order. Receivers that step a sequence counter, which is every shipped Phoros client, would otherwise drop the overtaken chunk as a duplicate.

## Loss repair

Three mechanisms, cheapest first:

1. **XOR parity.** After every 8 media datagrams the sender emits one repair datagram carrying their XOR. One loss in a group is reconstructed on arrival with no round trip. The parity is computed over the SRTP ciphertext, so the core does not need the keys and the repaired datagram decrypts like any other. `PHOROS_FEC=<k>` changes the group size, `PHOROS_FEC=0` turns it off.
2. **NACK and RTX.** Two losses in a group need a retransmission. The generic NACK fires on a 5 ms timer rather than an RTT-derived interval, because on a one-hop link the round trip is under 3 ms and the standard interval wastes most of the budget waiting.
3. **PLI.** A frame that arrives with an unrepaired gap is not decodable. The receiver asks for a keyframe over RTCP, the core raises a keyframe-request event, and the host encodes one. This is the last resort: a 1080p keyframe is a quarter of a second of a 6 Mbps link.

The receiver holds 6 frames before delivering, which is the window a NACK has to land in. `PHOROS_HOLD_FRAMES` changes it.

## Timestamps

RTP carries a presentation timestamp as 32 bits of 90 kHz ticks, which wraps every 13 hours and 15 minutes. Audio chunks carry the full 64-bit microsecond timestamp the rest of the protocol uses. A receiver that anchors audio to video has to put them on the same timeline.

`hostTimeReference` is that anchor. It is set from `TransportOffer.hostMicros` at the start and refreshed from every audio chunk, and `PhorosPeerTransport` unwraps each frame's reduced timestamp to the nearest cycle of it before delivering. A transport with no reference delivers the reduced value, which is what 1.4.2 clients saw before the field existed: an apparent offset of up to 15 minutes between audio and video.

## Fallback

The peer can fail in ways ICE does not notice, so the host watches the media itself:

```swift
// every 250 ms while streaming on the peer
if media.isStalled(threshold: 0.7) { fallBack(reason: "no frame acks") }

func fallBack(reason: String) {
    rtcReady = false
    media.cancel()                             // full teardown: callbacks cleared, socket closed, peer destroyed
    tcp.sendControl(.transportFallback)        // the client stops expecting media on the peer
    requestKeyframeForRecovery()               // the first TCP frame after the switch must be decodable
}
```

The receiver acknowledges each assembled frame on the realtime lane, and `isStalled` is true when the last acknowledgement is older than the threshold. 700 ms is long enough that a Wi-Fi stall does not trigger it and short enough that a person reads the recovery as a stutter rather than a freeze.

`transportFallback` carries no payload and is safe for an older peer to ignore, but a peer old enough to ignore it never accepted the offer in the first place.

Fallback is one-way within a session. The host does not re-offer, because a peer that failed once on this link will usually fail again, and a stream that flips transports repeatedly is worse than one that settles.

## Building the core

You do not need to. `Package.swift` pins a prebuilt XCFramework published as a release asset, by checksum. To work on the Rust side:

```bash
Core/build.sh                       # four Apple targets, lipo, xcframework, prints the SwiftPM checksum
PHOROS_CORE_LOCAL=1 swift test      # links what you just built instead of the release artifact
cd Core/phoros-core && cargo test   # the Rust suite, including a two-peer ICE-to-media loopback
```

The crate vendors [str0m](https://github.com/algesten/str0m) with two changes: a configurable minimum NACK interval, and a pacer that never holds a packet. The pacer exists to smooth a congestion-controlled stream across a wide-area path. On one Wi-Fi hop it added 100 to 1000 ms of jitter for no benefit.

[Core/README.md](../Core/README.md) documents the C ABI and what it guarantees at the boundary.

## Switches

The core reads a handful of environment variables, for experiments and for the reference host's latency harness. They are not API and they can change.

| Variable | Default | Effect |
|---|---|---|
| `PHOROS_FEC` | 8 | Media datagrams per repair datagram. 0 disables parity. |
| `PHOROS_NACK_MS` | 5 | Minimum interval between NACKs. |
| `PHOROS_HOLD_FRAMES` | 6 | Frames held at the receiver before delivery. |
| `PHOROS_MTU` | 1400 | Target datagram size. |
| `PHOROS_NO_RTX` | off | Disables retransmission, leaving parity and PLI. |
| `PHOROS_BWE` | off | Enables the transport-wide congestion controller and its pacer. |
| `PHOROS_DROP` | 0 | Drops this percentage of outbound datagrams, for testing repair. |
| `PHOROS_DELAY_US` | 0 | Holds every outbound datagram this long, for testing one-way delay. |
| `PHOROS_STOP_AFTER_MS` | off | Stops the socket loop after this long, for testing the fallback path. |
