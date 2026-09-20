# Wire format

Protocol version 1. All multi-byte integers are big-endian. All JSON is UTF-8.

## Transport

One reliable, ordered byte stream per session (TCP in the reference apps). The host listens on a fixed port. The client connects. Discovery of the host is outside the protocol (Bonjour in the reference apps).

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
| `bitrate_cap_request` | client → host | `{"bitsPerSecond": int}` or `{}` to lift. Video never exceeds it, whatever the preset. Since 1.4.1; older hosts ignore it |
| `window_list_request` | client → host | none |
| `window_list` | host → client | `{"windows": [{"id", "title", "app"}]}` |
| `window_select_request` | client → host | `{"windowID": id}`, `0` for full display |
| `capture_mode_changed` | host → client | `{"windowMode", "windowID"?, "title"?, "app"?}` |
| `media_key` | client → host | see below |
| `clock_probe` | client → host | `{"id", "sentAt"}`. Only if host `supportsClockSync`. Added in package 1.4.0 |
| `clock_reply` | host → client | `{"id", "sentAt", "receivedAt", "repliedAt"}`. Added in package 1.4.0 |

Preset names: `auto`, `360p30`, `480p30`, `720p30`, `720p60`, `1080p30`, `1080p60`.

### clock_probe and clock_reply

One exchange samples the offset between the two clocks, as in NTP. `sentAt` is the client's clock when the probe left. The host echoes `id` and `sentAt`, adds `receivedAt` (its clock when the probe arrived) and `repliedAt` (its clock when the reply left). All four are microseconds of each peer's monotonic clock, the clock video presentation timestamps use, so the client can read a frame's timestamp as an age. `PhorosSession.ClockSync` does the arithmetic and keeps the sample with the shortest round trip.

### media_key

```json
{"key": "play_pause", "controlID": "…", "text": "…", "keystroke": "a", "keystrokeModifiers": 256, "click": {"x": 0.5, "y": 0.5, "button": "left"}}
```

`key` is required. Values: `play_pause`, `next`, `previous`, `seek_backward`, `seek_forward`. The other fields are optional and extend the message into a general input path:

- `controlID` names an advertised button and takes precedence over `key`.
- `text` is typed by the host, followed by Return.
- `keystroke` is typed as-is. `"\n"` is Return and `"\u0008"` is Backspace. `keystrokeModifiers` is a chord in the host's native mask.
- `click` is a tap at a normalised point on the frame the client shows.

A receiver rejects a whole message when its `type` is unknown, or its payload is missing or has the wrong shape. Receivers ignore rejected messages and keep the session.
