# Compatibility

Two apps built on this protocol are installed and updated separately. A phone app arrives from an app store on the user's schedule. A Mac app updates itself on its own schedule. At any moment, some pairs in the world run versions released a year apart, in both directions. Nothing in the protocol can assume the other side is current.

This document lists the rules that follow from that, and the incident behind each rule. Every incident below happened to a shipped build. Code enforces the rules where it can: `PeerCapabilities` applies them to every handshake, and the test suite pins every byte and every JSON key that a shipped peer depends on.

## Rule 1: add, never change

New behaviour is one of these:

- a new optional JSON field
- a new capability flag
- a new control message type
- a new packet type at the next free id

Existing fields, ids and meanings are permanent. A retired field stays in the documentation as retired. Its key never gets a new meaning.

The handshake has no version number, on purpose. A version number invites `if version >= 3` logic. That is a capability flag with worse ergonomics, and it is often wrong about what a version shipped. Ask about the feature, not the version.

## Rule 2: absence is never optimistic

When a peer does not say it can do something, it cannot. It gets the original behaviour.

`PeerCapabilities` holds this rule. It reads the handshake once and answers every capability question with the conservative default applied. Application code never reads the raw optionals.

**The incident.** Video pause let a client hold video during warm-up to save bandwidth. Hosts accepted the `video_pause` message from the first version. A later host fix made resume work. In between, a client that paused video on an unfixed host broke its own decoder. The host dropped every frame encoded during the hold, including the keyframe that opened the session. The host had already set its "parameter sets sent" flag, so it never sent them again. The stream stayed black for the rest of the session, with no error anywhere.

The fix was a `supportsVideoHold` flag from the host. Its absence means "do not pause video on this host". That is a different fact from "this host does not understand `video_pause`". Warm-up is an optimisation. A black stream is not an acceptable price for it.

The same shape repeats:

- `supportsRemoteAccess` is always `true` when present. Its absence tells the client that the host predates remote access. The client can then say "update the Mac app" instead of "install a VPN on the Mac". An empty address list alone cannot tell those apart.
- `supportsAudioToggle` absent: the host keeps sending audio whatever the client asks. The client mutes locally instead.
- `wantsAudio` absent: an older client that always wants audio.

## Rule 3: the packet is the authority for media

Codec negotiation in the handshake decides what a host may send. The flags byte on each media packet says what the host did send. Receivers decode from the flags. They never decode from what they remember negotiating, because a host may fall back mid-session if its encoder fails.

Codec id 0 is the original codec, forever. Every sender ever shipped wrote a zero flags byte. Every receiver ever shipped ignored it. That is the only reason the flags byte can carry a codec id today. An old sender still writes zero, and zero still means PCM or H.264, so nothing old had to change.

**The incident.** AAC audio was added to cut bandwidth. The audio header is a fixed twelve bytes. Every receiver skips it by absolute offset, so a codec field there would break all of them. The codec went in the flags. A host that sends AAC to a client that expects PCM makes that client play compressed bytes as Float32 samples. The result is full-scale white noise, directly into someone's headphones. So:

- A host sends a non-zero codec id only to a client that listed that codec in `supportedAudioCodecs` on the current connection. Not on a remembered connection. The client may have been reinstalled or downgraded since.
- A missing `supportedAudioCodecs` means a client from before negotiation existed. It decodes PCM only. An empty list means the same. Neither means "anything goes".
- A receiver that reads a codec id it does not know drops the packet. A receiver that falls through to the PCM path makes the same white noise by another route.

Video followed the same design when HEVC was added. The codec id is on the parameter-sets packet, because the parameter sets decide whether the receiver builds an H.264 or an HEVC decoder. An HEVC stream to an H.264-only client never yields a format description. The picture never appears, with no error, which is worse than a loud failure.

## Rule 4: unknown means drop

Reject these units and keep the session:

- a packet with an unknown type
- a media packet with an unknown codec id
- a control message with an unknown `type`
- a payload that does not have the shape its `type` requires

Never coerce a rejected unit into the nearest thing that parses.

**The incident.** The first control-message decoder did not dispatch on `type`. It tried each known payload shape in turn and took the first that decoded. Then a payload was added whose fields were all optional. It decoded from any JSON object, so the decoder misread every message that followed it in the list as that one. The fix at the time was to make one of its fields required and leave a warning comment. The fix now is that `ControlMessage` dispatches on `type`, and a payload of the wrong shape is an error.

Codec lists in the handshake are strings, not enums, for the same reason seen from the other side. An unknown enum value would fail decoding of the whole handshake message. That message carries the credentials, so authentication itself would break because a client learned a new codec.

## Rule 5: never grow a fixed header

`PacketHeader` is ten bytes. `VideoFragmentHeader` is sixteen. `AudioChunkHeader` is twelve. `ControllerReport` is fourteen. Shipped receivers skip them by constant offset. New per-packet information goes in the flags byte or in a new packet type, never in a longer header.

A field appended after a fixed header is a different thing and is allowed, because every offset before it is unchanged. `ControllerReport.sequence` (1.4.2) is two bytes after the fourteen. A sender adds them only when it has a reason to, a receiver reads them only when the payload is long enough, and an older receiver reaches the end of what it knows and stops. The test that pins the fourteen-byte form still passes unchanged, which is the check that this was an append and not a growth.

## Rule 6: private data stays inside the authenticated session

Window titles are as private as the screen itself. The host sends the window list only over an authenticated session, never on the pairing channel. The pairing code itself never crosses the wire. It goes through the person, from one screen to the other.

## Rule 7: a second transport is a capability, not a fork

A host may offer a different wire for media (`transport_offer`, since 1.4.2). Four things keep that from splitting the protocol in two:

- The offer is a control message on the authenticated connection. A client that does not know the message ignores it and the session runs unchanged, which is rule 4.
- The offered transport carries the same units, framed the same way, behind the same seam. Nothing on it is exclusive to it.
- Pairing, authentication and control stay on the base connection for the whole session, so there is one source of truth for session state.
- The host can withdraw the offer at any moment with `transport_fallback` and continue on the base connection. A transport is an optimisation. Losing it must never lose the session.

**The incident.** The first version of the offer carried no clock reading. RTP reduces a presentation timestamp to 32 bits of 90 kHz ticks, so video arrived on a timeline that restarts every thirteen hours while audio kept the full microsecond value. A client that anchors audio to video measured an offset of about fifteen minutes and resynchronised twice a second, discarding its audio queue each time. `hostMicros` on the offer is the reading that puts them back together. The rule it teaches: when a transport changes the units a receiver compares, say so in the message that introduces it.

## Rule 8: a package version is not a protocol version

This package follows semantic versioning for its Swift API. A major release of the package means Swift code needs changes. It does not mean the wire changed. A wire change is a separate, deliberate event, recorded in `Phoros.protocolVersion`. It has not happened. If it does, the host must return an actionable error to an older client instead of letting it fail silently.

## Before you ship

The test suite proves that this package still writes the bytes that shipped peers expect. It cannot prove that your app still behaves. Before you release either side, run three real-device combinations:

1. new client, new host
2. new client, the previous host release
3. the previous client release, new host

The second and third combinations find the bugs.
