# Wire format

Protocol version 1. All multi-byte integers are big-endian. All JSON is UTF-8.

## Transport

One reliable, ordered byte stream per session (TCP in the reference apps). The host listens on a fixed port. The client connects. Discovery of the host is outside the protocol (Bonjour in the reference apps).

Since 1.4.2 a host may additionally offer a UDP transport that carries media and input once it connects. This document describes the byte stream, which every peer speaks. The UDP wire and the two messages that set it up are in [realtime.md](realtime.md).

The stream carries **frames**. A frame is a 4-byte length followed by that many bytes:

```
offset  size  field
     0     4  length of what follows, UInt32
     4     …  frame body
```

A frame body is one of:

- a **packet**: a `PacketHeader` and its payload
- a bare **JSON message**: a `PairingMessage` or `ControlMessage` with no packet header

Receivers tell them apart by the first four bytes. A packet starts with the magic `0x4245414D` ("BEAM"). No JSON document can. The host sends every frame as a packet. The client sends JSON bare and wraps only binary payloads (controller reports). Both forms are valid in both directions. The asymmetry is historical.

Receivers must check the frame length against a limit before they allocate. `FrameDecoder` does this.

## Encrypted connections

Since 1.7.0 a connection can be encrypted. A client opens with a `secure_hello` only to a host that advertised `supportsEncryption`. An older host does not know the message and ignores it. The first two frames are bare JSON in the clear:

```
client → host   {"type":"secure_hello","mode":"authenticate","deviceID":"…","key":"<X25519 public key, base64>","nonce":"<32 bytes, base64>"}
host → client   {"type":"secure_accept","key":"…","nonce":"…","proof":"<HMAC-SHA256, base64>"}
            or  {"type":"secure_reject","error":"unknown_device"}
```

`mode` is `pair` for a client that has no secret yet, and then `deviceID` is absent. Every later frame in both directions has its body sealed with AES-256-GCM. The length prefix stays in the clear and counts the sealed body:

```
offset  size  field
     0     4  length of what follows, UInt32 (plaintext length + 16)
     4     …  ciphertext
     …    16  GCM tag
```

The nonce is never sent. It is four zero bytes followed by a UInt64 frame counter, one counter per direction, starting at 0. A frame that does not open ends the connection. That includes a frame that was dropped, replayed or reordered.

Keys:

```
transcript = "phoros-secure/1" ‖ mode ‖ UInt32(len(deviceID)) ‖ deviceID ‖ clientKey ‖ clientNonce ‖ hostKey ‖ hostNonce
ikm        = X25519(client, host) ‖ sharedSecret        (the 32 secret bytes; omitted when mode is pair)
okm        = HKDF-SHA256(ikm, salt: SHA-256(transcript), info: "phoros-secure/1 keys", 96 bytes)
             client→host key = okm[0..<32], host→client key = okm[32..<64], confirm key = okm[64..<96]
proof      = HMAC-SHA256(confirm key, "phoros-secure/1 host")
```

The client checks `proof` before it sends anything sealed. Inside the sealed connection the session runs exactly as on a plaintext one: `hello`, `code_verify`, `auth_request` and the rest, unchanged. `SecureChannelTests.testKeySchedulePinned` pins these bytes.

## Packet header

Ten bytes.

```
offset  size  field
     0     4  magic, 0x4245414D
     4     1  packet type
     5     1  flags, meaning depends on type
     6     4  payload length, UInt32
    10     …  payload
```

### Packet types

| id | name | direction | payload | flags |
|---:|---|---|---|---|
| `0x01` | `video` | host → client | `VideoFragmentHeader` + bitstream | 0 |
| `0x02` | `audio` | host → client | `AudioChunkHeader` + audio | low nibble: `AudioCodecID` id |
| `0x03` | `control` | host → client | JSON `ControlMessage` or `PairingMessage` | 0 |
| `0x04` | `heartbeat` | either | empty | 0 |
| `0x05` | `parameterSets` | host → client | codec parameter sets | low nibble: `VideoCodecID` id |
| `0x06` | `videoKeyframe` | host → client | `VideoFragmentHeader` + bitstream | 0 |
| `0x07` | `input` | client → host | `ControllerReport` | bit 0: controller attached |

Ids are never reused. `PacketHeader.parse` rejects unassigned ids.

The high nibble of `flags` is reserved on every type. Senders write zero. Receivers mask it off.

## Video

`.video` and `.videoKeyframe` payloads start with sixteen bytes:

```
offset  size  field
     0     4  frameNumber, UInt32, +1 per encoded frame
     4     2  fragmentIndex, UInt16, from 0
     6     2  fragmentCount, UInt16
     8     8  presentationTimestamp, Int64, microseconds
    16     …  bitstream
```

The sender splits a frame into `fragmentCount` fragments and sends them in order. The reference host keeps each payload at or under 1400 bytes, so a keyframe cannot hold audio behind it for long. Receivers collect fragments by `frameNumber` and decode when all fragments arrived. A new `frameNumber` before the previous frame completed means the previous frame is lost. Discard it.

The bitstream is Annex B (start-code delimited NAL units) for both H.264 and HEVC. Frames carry no codec id. They decode against the format description built from the most recent `.parameterSets` packet.

`.videoKeyframe` is a keyframe (IDR). A receiver that lost data waits for one before decoding again.

### Parameter sets

The `.parameterSets` payload is the parameter set NAL units in Annex B form. For H.264 that is SPS and PPS. For HEVC it is VPS, SPS and PPS. The codec is in the packet flags:

| flags & 0x0F | codec | name in JSON |
|---:|---|---|
| `0` | H.264 High profile | `h264` |
| `1` | HEVC Main profile | `hevc` |

The host sends parameter sets before the first frame of a session, and again whenever the encoder restarts (quality change, codec change, resume after pause). A receiver that reads an unknown id must not build a format description. It drops the packet and logs.

### Timestamps

`presentationTimestamp` is microseconds on the sender's media clock, shared by video and audio. It is for A/V alignment. It is not wall-clock time and may start at any value.

## Audio

`.audio` payloads start with twelve bytes:

```
offset  size  field
     0     4  sequenceNumber, UInt32, +1 per chunk, resets on encoder restart
     4     8  presentationTimestamp, Int64, microseconds
    12     …  audio
```

Audio is never fragmented. The codec is in the packet flags:

| flags & 0x0F | codec | name in JSON | payload after header |
|---:|---|---|---|
| `0` | PCM | `pcm_f32le` | interleaved Float32 samples, native byte order |
| `1` | AAC-LC | `aac_lc` | exactly one raw access unit (1024 frames), no ADTS or LATM |

An AAC access unit is at most `AudioCodecID.maxAccessUnitBytes` (1536) bytes. Sample rate and channel count come from `ControlMessage.audioFormatChanged`, sent before the first chunk and on every change.

A receiver that reads an unknown id drops the chunk. It must not fall through to the PCM path.

## Controller reports

`.input` payloads are fourteen bytes:

```
offset  size  field
     0     4  buttons, UInt32 bit set
     4     2  leftX, Int16, right positive
     6     2  leftY, Int16, up positive
     8     2  rightX, Int16
    10     2  rightY, Int16
    12     1  leftTrigger, 0…255
    13     1  rightTrigger, 0…255
```

Buttons, bit 0 upward: A, B, X, Y, left shoulder, right shoulder, left thumbstick, right thumbstick, D-pad up, down, left, right, menu, options, home.

Two more bytes may follow (since 1.4.2):

```
offset  size  field
    14     2  sequence, UInt16, wrapping, +1 per report
```

A client that sends the same report on two transports at once numbers them, so the host can play the first copy to arrive and drop the second. A payload of exactly fourteen bytes has no sequence and is what every client before 1.4.2 sends. `ControllerReport.parse` reads the field only when the payload is long enough, and `ControllerReport.isNewer(_:than:)` compares two wrapping values.

Packet flags bit 0 set means a controller is attached. A report with the bit clear is neutral and tells the host to release its virtual device. The client sends reports at up to 60 Hz. A host that cannot replay input recognises the type and drops it.

A host that can replay input says so with `supportsControllerInput` in `pair_success` and `auth_success`. A client should not sample a controller for a host that did not. `PhorosInput` has both ends: `ControllerSampler` for the client and `VirtualGamepad` for a macOS host. See [input.md](input.md).

## Handshake messages

JSON object. `type` is required. Every other key is optional and omitted when not applicable.

```json
{"type": "auth_request", "deviceID": "…", "sharedSecret": "…", "supportedAudioCodecs": ["aac_lc", "pcm_f32le"]}
```

### Types

| `type` | direction | purpose |
|---|---|---|
| `hello` | client → host | start pairing |
| `challenge` | host → client | the host shows a code. Type it |
| `code_verify` | client → host | the typed code |
| `pair_success` | host → client | paired. Here is the secret |
| `pair_failed` | host → client | wrong code |
| `auth_request` | client → host | every later connection. Secret plus capabilities |
| `auth_success` | host → client | authenticated. Host capabilities and session choices |
| `auth_failed` | host → client | secret rejected or device unknown |
| `unpaired` | host → client | device was removed on the host. Forget the secret |

### Fields

| key | type | sent on | meaning |
|---|---|---|---|
| `deviceName` | string | hello, challenge, pair_success, auth_success | display name of the sender |
| `deviceID` | string | hello, code_verify, auth_request | client's stable UUID |
| `code` | string | code_verify | the six digits the person typed |
| `sharedSecret` | string | pair_success, auth_request | hex of 32 random bytes |
| `error` | string | pair_failed, auth_failed | text the client may show |
| `tailscaleHosts` | [string] | pair_success, auth_success | host's remote addresses (Swift: `remoteHosts`) |
| `supportsRemoteAccess` | bool | pair_success, auth_success | always `true` when present. Absence means the host predates remote access |
| `supportsVideoHold` | bool | pair_success, auth_success | host resumes video correctly after `video_pause` |
| `selectedAudioCodec` | string | auth_success | codec name chosen for the session. Informational |
| `selectedVideoCodec` | string | auth_success | codec name chosen for the session. Informational |
| `supportsAudioToggle` | bool | auth_success | host acts on `audio_enable_request` |
| `supportsWindowSelection` | bool | auth_success | host answers `window_list_request` |
| `phoneControls` | [ControlButton] | auth_success | buttons the client should render (Swift: `controls`) |
| `supportsControllerInput` | bool | pair_success, auth_success | host replays `input` packets into a virtual game controller. Added in package 1.1.0 |
| `preferredAudioSampleRate` | number | auth_request | client's hardware rate |
| `supportedAudioCodecs` | [string] | hello, auth_request | codec names the client decodes, preferred first |
| `supportedVideoCodecs` | [string] | hello, auth_request | codec names the client decodes, preferred first |
| `wantsAudio` | bool | auth_request | absent means `true` |
| `maximumFrameRate` | number | auth_request | the highest video frame rate the client wants, normally its display's refresh rate. A host raises a 60 fps preset toward the lower of this and its own display. Absent means the preset's rate. Added in package 1.4.0 |
| `supportsClockSync` | bool | auth_success | host answers `clock_probe` with `clock_reply`. Added in package 1.4.0 |
| `supportsPointer` | bool | pair_success, auth_success | host acts on `media_key.pointer` and `click.count`. Absent means the client sends single clicks only. Added in package 1.5.0 |
| `maximumVideoDimension` | number | pair_success, auth_success | the longest pixel edge of the display the host streams. A client hides presets bigger than this. Absent means the client assumes 1920 and offers nothing above 1080p. Added in package 1.6.0 |
| `supportsEncryption` | bool | pair_success, auth_success | host accepts `secure_hello`. A client that has seen it should remember it for that host and refuse plaintext from then on. Added in package 1.7.0 |

Codec lists are strings, not enums. An unknown future codec then cannot fail decoding of the message that carries the credentials. Receivers ignore unknown names.

### ControlButton

```json
{"id": "…", "symbol": "playpause", "label": "Play", "prominent": true, "promptsForText": true, "textPrompt": "Say…", "mode": "text", "modifier": "cmd"}
```

`mode` values: `tap` (default), `text`, `keyboard`, `click`, `click_left`, `click_right`, `modifier`. Clients treat unknown values as `tap`.

## Control messages

JSON object with `type` and, for some types, `payload`. The client sends it bare. The host sends it inside a `.control` packet.

```json
{"type": "quality_request", "payload": {"preset": "720p60"}}
```

| `type` | direction | payload |
|---|---|---|
| `ping` | either | none |
| `pong` | either | none |
| `stream_request` | client → host | none |
| `stream_stop` | client → host | none |
| `quality_feedback` | client → host | `{"quality": 0…1}` |
| `quality_request` | client → host | `{"preset": name}` |
| `quality_changed` | host → client | `{"preset": name}` |
| `viewport_lock_request` | client → host | `{"locked", "x", "y", "width", "height"}`, normalised 0…1 |
| `video_pause` | client → host | none. Only if host `supportsVideoHold` |
| `video_resume` | client → host | none |
| `audio_format_changed` | host → client | `{"sampleRate", "channels"}` |
| `audio_enable_request` | client → host | `{"enabled": bool}`. Only if host `supportsAudioToggle` |
| `bitrate_cap_request` | client → host | `{"bitsPerSecond": int}` or `{}` to lift. Video never exceeds it, whatever the preset. Since 1.4.1. Older hosts ignore it |
| `window_list_request` | client → host | none |
| `window_list` | host → client | `{"windows": [{"id", "title", "app"}]}` |
| `window_select_request` | client → host | `{"windowID": id}`, `0` for full display |
| `capture_mode_changed` | host → client | `{"windowMode", "windowID"?, "title"?, "app"?}` |
| `media_key` | client → host | see below |
| `clock_probe` | client → host | `{"id", "sentAt"}`. Only if host `supportsClockSync`. Added in package 1.4.0 |
| `clock_reply` | host → client | `{"id", "sentAt", "receivedAt", "repliedAt"}`. Added in package 1.4.0 |
| `transport_offer` | host → client | `{"kind", "address", "info", "hostMicros"?}`. A second transport the client may accept. Added in package 1.4.2 |
| `transport_answer` | client → host | the same shape, the client's side of it. Added in package 1.4.2 |
| `transport_fallback` | host → client | none. Media and input are back on this connection. Added in package 1.4.2 |

Preset names: `auto`, `360p30`, `480p30`, `720p30`, `720p60`, `1080p30`, `1080p60`, and since 1.6.0 `1440p30`, `1440p60`, `2160p30`, `2160p60`, `native30` and `native60`. A native preset streams at the host display's own resolution. Which presets `auto` moves between is up to the host; Beacon keeps it at 1080p or below.

### clock_probe and clock_reply

One exchange samples the offset between the two clocks, as in NTP. `sentAt` is the client's clock when the probe left. The host echoes `id` and `sentAt`, adds `receivedAt` (its clock when the probe arrived) and `repliedAt` (its clock when the reply left). All four are microseconds of each peer's monotonic clock, the clock video presentation timestamps use, so the client can read a frame's timestamp as an age. `PhorosSession.ClockSync` does the arithmetic and keeps the sample with the shortest round trip.

### transport_offer, transport_answer and transport_fallback

```json
{"type": "transport_offer", "payload": {"kind": "rtc2", "address": "192.168.1.2:7981", "info": "ufrag\npass\nfingerprint", "hostMicros": 1758484812345678}}
```

`kind` names the transport. `rtc2` is the UDP peer in `PhorosCore`. A client that does not know the kind ignores the message and the session continues on this connection, which is rule 4.

`address` is where to send. `info` is the peer's ICE credentials and DTLS fingerprint, three lines. `hostMicros` is the host's media clock when the offer left, which lets the receiver put the offered transport's reduced timestamps back on the full timeline.

`transport_answer` is the client's half, with its own address and info. `transport_fallback` has no payload and means the host has stopped using the offered transport for this session. See [realtime.md](realtime.md).

### media_key

```json
{"key": "play_pause", "controlID": "…", "text": "…", "keystroke": "a", "keystrokeModifiers": 256, "specialKey": "leftArrow", "click": {"x": 0.5, "y": 0.5, "button": "left", "count": 2}, "pointer": {"phase": "move", "x": 0.5, "y": 0.5, "button": "left"}}
```

`key` is required. Values: `play_pause`, `next`, `previous`, `seek_backward`, `seek_forward`. The other fields are optional and extend the message into a general input path:

- `controlID` names an advertised button and takes precedence over `key`.
- `text` is typed by the host, followed by Return.
- `keystroke` is typed as-is. `"\n"` is Return and `"\u0008"` is Backspace. `keystrokeModifiers` is a chord in the host's native mask.
- `specialKey` is a named desktop key: `escape`, `tab`, `leftArrow`, `upArrow`, `downArrow`, `rightArrow`, `home`, `end`, `pageUp`, `pageDown`, `forwardDelete`, or `f1` through `f12`. It is an optional string so older peers ignore it and newer peers can ignore values they do not recognize. When present, hosts post the real key with `keystrokeModifiers` and do not insert text into the client's input responder.
- `click` is a tap at a normalised point on the frame the client shows. `count` is 2 or 3 for the second or third click of a series, so the host can post a double- or triple-click. Absent means 1.
- `pointer` is one step of a press, drag or scroll, at a normalised point. `phase` is `down`, `move`, `up` or `scroll`. A drag is `down`, then `move` any number of times, then `up`. `scroll` carries `dx` and `dy` in points: a positive `dy` moves the content down. `phase` is a string, so a host ignores a phase it does not know. A client sends `pointer` and `count` only to a host that set `supportsPointer`, because an older host would click at every drag step.

A receiver rejects a whole message when its `type` is unknown, or its payload is missing or has the wrong shape. Receivers ignore rejected messages and keep the session.
