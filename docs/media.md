# Encoders and decoders

`PhorosMedia` produces and consumes exactly what the wire carries. It wraps VideoToolbox and AudioToolbox. The settings that took production time to get right are the defaults. The parts that are easy to get subtly wrong (Annex B, parameter sets, AAC timing) are one call.

Nothing here captures a screen, plays audio or draws a frame. Those are yours.

## Video

### `VideoEncoder`

A hardware H.264 or HEVC session. It emits Annex B frames flagged keyframe or not, and its parameter sets once per session.

```swift
let encoder = VideoEncoder(configuration: VideoEncoderConfiguration(
    width: 1920, height: 1080, frameRate: 30, bitrateBitsPerSecond: 6_000_000, codec: .hevc
))
encoder.onParameterSets = { annexB, codec in … }   // codec may be .h264 after an HEVC fallback
encoder.onFrame = { annexB, pts, isKeyframe in … }
encoder.onError = { status in … }
try encoder.start()
encoder.encode(sampleBuffer)                         // CVPixelBuffer-backed, from any source
encoder.requestKeyframe()                            // next frame is an IDR
encoder.reconfigure { $0.width = 1280; $0.height = 720 }
encoder.setBitrate(3_000_000)                        // live, no restart, no keyframe (1.4.0)
encoder.onFrameDropped = { … }                       // VideoToolbox chose not to emit a frame (1.4.0)
```

Locked in, because each one cost a release to learn:

| Setting | Value | Why |
|---|---|---|
| Real-time mode | on | Otherwise the encoder buffers for quality and adds frames of latency. |
| Frame reordering | off | B-frames add a frame of delay and break the keyframe-or-not packet split. |
| Profile | H.264 High, HEVC Main, automatic level | Widest hardware decode support at the quality this needs. |
| Data rate limit | twice the target bitrate | Bounds keyframe bursts so one keyframe cannot flood a slow link. |
| Keyframe interval | two seconds | A joining or recovering client waits at most this long for a picture. |
| Hardware only | required | A software encoder cannot keep up with a live screen and would mask a missing encoder as a slow one. |

`VideoEncoderConfiguration.latency` (1.4.0) holds the knobs the latency harness measured. `lowLatencyRateControl` asks for the hardware's low-latency rate-control mode (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`): on the reference host it cut encode time from 12.8 to 6.6 ms per 1080p frame and holds the target bitrate on busy content where the default mode overshoots it by half. The session falls back to a normal one when the encoder refuses it. `maxFrameDelayCount`, `prioritizeSpeed` and `h264Profile = .baseline` measured no gain and stay off by default. `keyframeInterval` is on the configuration; the reference host raises it to ten seconds when a link is slow, because a 1080p keyframe is a quarter second of a 6 Mbps link.

If the hardware has no HEVC encoder the session starts as H.264 and says so through `onParameterSets`. `VideoEncoder.isHEVCSupported` probes once for the capability advertisement.

### `VideoFormat`

Bridges parameter sets to `CMVideoFormatDescription` in both directions, and wraps a frame in a `CMSampleBuffer` for `AVSampleBufferDisplayLayer` or `VTDecompressionSession`.

```swift
let description = VideoFormat.makeDescription(parameterSets: payload, codec: codec)     // receiver
let payload = VideoFormat.parameterSets(from: encoderDescription, codec: codec)        // sender
let sample = VideoFormat.makeSampleBuffer(annexB: frame, formatDescription: description, presentationTime: hostNow)
```

Stamp sample buffers with the receiver's own clock. The sender's timestamps are on the sender's clock. Scheduling against them displays nothing.

### `AnnexB`

The wire carries Annex B (start-code delimited). VideoToolbox produces and consumes length-prefixed NAL units. `AnnexB.toLengthPrefixed`, `fromLengthPrefixed`, `nalUnits(in:)` and `join` convert without touching the NAL bytes.

## Audio

### `PCMChunk`

Normalises a captured `CMSampleBuffer` (Float32 or Int16, interleaved or planar) into interleaved Float32. That is the wire form of `AudioCodecID.pcmFloat32` and the input to `AACEncoder`.

```swift
guard let chunk = PCMChunk(sampleBuffer: captured) else { return }
sendPCM(chunk.samples, at: chunk.presentationTime)      // legacy clients
for unit in try aac.encode(chunk) { sendAAC(unit) }      // clients that advertised aac_lc
```

### `AACEncoder`

Encodes to raw AAC-LC access units, one per packet, with timestamps that stay in sync with video.

AAC-LC has a constant delay of about 2112 frames (encoder priming plus decoder look-ahead). Left alone it is a permanent negative A/V offset. The encoder runs a sample-accurate output clock and stamps each unit `primingFrames` earlier than its nominal position. That cancels the delay exactly. The real priming value is read from the converter. 2112 is the fallback.

Other things it does for you:

- Constant bitrate, so unit size is predictable and "one unit fits one packet" holds. Units over `AudioCodecID.maxAccessUnitBytes` are skipped. The clock still advances.
- Bitrate snapped to a rate the encoder supports, never above 160 kbps. `setBitrate` applies live without a re-anchor.
- Rebuilds itself when the source sample rate or channel count changes.
- Re-anchors its clock when input timestamps jump by more than `driftTolerance`, which happens when capture stalls.
- Throws on a converter failure so the caller can fall back to PCM and retry later.

### `AACDecoder`

Decodes one access unit into a non-interleaved Float32 `AVAudioPCMBuffer` at the rate and channel count the host announced in `audioFormatChanged`. Build it after that message arrives, not before. It performs no priming trim: the sender already compensated, and compensating again pushes audio permanently early.

Returns `nil` for a malformed or oversized unit, and for the first unit or two while the decoder primes. AAC-LC units are independently decodable, so a decoder that starts failing can be thrown away and rebuilt.

## Timestamps

Everything on the wire is microseconds on the sender's media clock. `CMTime.phorosMicroseconds` and `CMTime(phorosMicroseconds:)` convert.
