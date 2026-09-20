# Changelog

## 1.4.0

Protocol version stays 1. Additive.

- `Phoros`: `PairingMessage.maximumFrameRate` (auth_request), the highest frame rate the client wants; `PeerCapabilities.videoFrameRate(preset:hostRefreshRate:)` raises a 60 fps preset toward it. `PairingMessage.supportsClockSync` (auth_success). `ControlMessage.clockProbe` and `.clockReply` with `ClockProbe` and `ClockReply`.
- `PhorosSession`: `BitrateController` sets the video bitrate from the round trip of a control ping on the media connection, the one signal that sees the sender's socket buffer and the access point. `ClockSync` estimates the host's clock offset from probe replies so a client can read a frame's timestamp as an age. `SendScheduler`: `admitCapture` and `shouldEncodeVideo` refuse a frame before it is encoded, `enqueueVideoFrame` sends a frame as one write, queued bytes and `transportBacklog` count toward the budget, `maximumQueueDelay` shrinks the budget to a measured `drainRate`, delta frames are refused while a keyframe is owed and shed by `maximumVideoQueueAge`, `needsKeyframe` asks for recovery. `ControllerSampler` is event driven: `GCController` value changes are sent as they happen, rate limited to `sampleRate`, with a keepalive. `ClientCapabilities.maximumFrameRate`, `HostCapabilities.supportsClockSync`.
- `PhorosNetwork`: `PhorosConnection.parameters()` is the tuned TCP parameters (no delay, interactive video service class) both ends use.
- `PhorosMedia`: `VideoEncoderConfiguration.LatencyTuning` (`lowLatencyRateControl`, `maxFrameDelayCount`, `prioritizeSpeed`, `h264Profile`, `burstMultiplier`), `VideoEncoder.setBitrate` for a live change without a restart, `onFrameDropped` and `droppedFrames`, `keyframeInterval` on the configuration.
- Measured on the reference host and its latency harness at 1080p60: button to decoded frame 47/57 ms (p50/p95) before the release, 27.5/32.9 after it at 60 fps, 19.1/25.0 with a 120 fps client; a 12 Mbps link that carried 16 Mbps of content went from 477/1077 ms to 44/62.
- 118 tests.

## 1.3.0

Protocol version stays 1. Additive.

- `PhorosInput`: `GamepadProfile`. `VirtualGamepad` now presents a known controller identity, `.xboxOne` by default or `.dualShock4`, with that controller's descriptor and report layout. macOS's GameController framework adopts the device and every game gets the same mapping. `.generic` remains for raw-HID readers. The Xbox layout was verified through `GCController` on macOS 26: every button and axis lands on its name. The DualShock 4 layout follows the documented USB report and answers the driver's calibration and identity feature reports, but has not been verified on hardware.
- `VirtualGamepad` cancels the activated device before releasing it (IOKit aborted otherwise) and answers feature-report reads.
- 102 tests.

## 1.2.0

Protocol version stays 1. Additive.

- `Phoros`: `KeyModifiers`, the Carbon-valued mask that `MediaKeyCommand.keystrokeModifiers` carries, with `init?(wireName:)` for `ControlButton.modifier` names.
- `PhorosInput`: `InputReplay` (macOS) posts keystrokes, text, media keys and clicks for `ControlMessage.mediaKey`. `FrameMapping` maps frame-normalised taps and rects to the source with letterbox and viewport lock undone.
- README mark.
- 99 tests.

## 1.1.0

Protocol version stays 1. Everything here is additive.

- `Phoros`: `PairingMessage.supportsControllerInput`, sent by hosts that replay `.input` packets. `PeerCapabilities.supportsControllerInput` reads it with the conservative default.
- `PhorosSession`: `HostCapabilities.supportsControllerInput`.
- `PhorosInput`, new product: `ControllerSampler` and `ReportThrottle` for the client, `VirtualGamepad` (macOS 13+, `IOHIDUserDevice`) for the host, `GamepadReport` for the HID descriptor and report bytes, and `ControllerReport.init(GCExtendedGamepad)`.
- 93 tests.

## 1.0.0

First release. Protocol version 1: the wire contract that Beam 3.0 and Beacon 1.4 speak.

- `Phoros`: packet framing (`PacketHeader`, `Packet`, `LengthPrefix`, `FrameDecoder`), media headers (`VideoFragmentHeader`, `AudioChunkHeader`), codecs (`AudioCodecID`, `VideoCodecID`, `QualityPreset`), `ControllerReport`, handshake (`PairingMessage`, `ControlButton`, `PeerCapabilities`), and `ControlMessage` with type-keyed decoding.
- `PhorosSession`: `PairingHost`, `PairingClient`, `HostAuthenticator`, `ClientCapabilities`, `HostCapabilities`, `SharedSecret`, `FrameAssembler`, `AudioSequenceGuard`, `SendScheduler`, `VideoHold`, `RoundTripProbe`, `HeartbeatMonitor`, `QualityLadder`.
- `PhorosNetwork`: `PhorosConnection`.
- `PhorosMedia`: `VideoEncoder`, `VideoFormat`, `AnnexB`, `PCMChunk`, `AACEncoder`, `AACDecoder`.
- 84 tests. Wire fixtures pin every header's bytes and every message's JSON.
