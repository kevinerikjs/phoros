import Foundation

/// What the other side can do, read from its handshake message with the
/// conservative interpretation of every absent field already applied.
///
/// Use this instead of reading `PairingMessage` capability fields directly.
/// The rule it encodes: absence is never optimistic. A peer that did not say
/// it can do something cannot, and gets the original behaviour.
///
/// ```swift
/// let peer = PeerCapabilities(message)
/// let audio = peer.preferredAudioCodec(from: [.aacLC, .pcmFloat32])  // .aacLC only if advertised
/// if peer.supportsVideoHold { send(.videoPause) }
/// ```
public struct PeerCapabilities: Equatable, Sendable {
    /// Audio codecs the peer can decode, in its order of preference.
    /// Always contains `.pcmFloat32`, which every peer can decode; it is
    /// appended if the peer omitted it. Unknown names were dropped.
    public var audioCodecs: [AudioCodecID]

    /// Video codecs the peer can decode, in its order of preference.
    /// Always contains `.h264`.
    public var videoCodecs: [VideoCodecID]

    /// The peer said it resumes video correctly after a pause.
    public var supportsVideoHold: Bool

    /// The peer said it supports connections from outside the local network.
    public var supportsRemoteAccess: Bool

    /// The peer acts on `.audioEnableRequest`.
    public var supportsAudioToggle: Bool

    /// The peer answers `.windowListRequest` and acts on `.windowSelectRequest`.
    public var supportsWindowSelection: Bool

    /// The peer wants audio for this session. Absent means yes.
    public var wantsAudio: Bool

    /// The peer's preferred audio sample rate, if it stated one.
    public var preferredAudioSampleRate: Double?

    /// Remote addresses the peer advertised. Empty when it sent none.
    public var remoteHosts: [String]

    /// Buttons the peer asked to have rendered. Empty when it sent none.
    public var controls: [ControlButton]

    /// The peer replays `.input` packets into a virtual game controller.
    public var supportsControllerInput: Bool

    /// The peer answers `.clockProbe` with `.clockReply`.
    public var supportsClockSync: Bool

    /// The highest video frame rate the peer asked for, or `nil` for the
    /// preset's own rate. See `PairingMessage.maximumFrameRate`.
    public var maximumFrameRate: Double?

    public init(_ message: PairingMessage) {
        audioCodecs = PeerCapabilities.codecs(
            from: message.supportedAudioCodecs, parse: AudioCodecID.init(wireName:), fallback: .pcmFloat32
        )
        videoCodecs = PeerCapabilities.codecs(
            from: message.supportedVideoCodecs, parse: VideoCodecID.init(wireName:), fallback: .h264
        )
        supportsVideoHold = message.supportsVideoHold ?? false
        supportsRemoteAccess = message.supportsRemoteAccess ?? false
        supportsAudioToggle = message.supportsAudioToggle ?? false
        supportsWindowSelection = message.supportsWindowSelection ?? false
        wantsAudio = message.wantsAudio ?? true
        preferredAudioSampleRate = message.preferredAudioSampleRate
        remoteHosts = message.remoteHosts ?? []
        controls = message.controls ?? []
        supportsControllerInput = message.supportsControllerInput ?? false
        supportsClockSync = message.supportsClockSync ?? false
        maximumFrameRate = message.maximumFrameRate.flatMap { $0 > 0 ? $0 : nil }
    }

    /// The frame rate to capture and encode for this peer: the preset's rate,
    /// raised to the peer's `maximumFrameRate` when the preset is a 60 fps
    /// one and the host's display (`hostRefreshRate`) can supply it. The 30
    /// fps presets exist for constrained links and stay at 30.
    public func videoFrameRate(preset presetRate: Double, hostRefreshRate: Double) -> Double {
        guard presetRate >= 60, let wanted = maximumFrameRate else { return presetRate }
        return max(presetRate, min(wanted, hostRefreshRate))
    }

    /// The first of `preferences` the peer can decode. Falls back to the
    /// codec every peer can decode, so a host that prefers AAC still sends
    /// PCM to a client that never mentioned AAC.
    public func preferredAudioCodec(from preferences: [AudioCodecID] = [.aacLC, .pcmFloat32]) -> AudioCodecID {
        preferences.first(where: audioCodecs.contains) ?? .pcmFloat32
    }

    /// The first of `preferences` the peer can decode, falling back to H.264.
    public func preferredVideoCodec(from preferences: [VideoCodecID] = [.hevc, .h264]) -> VideoCodecID {
        preferences.first(where: videoCodecs.contains) ?? .h264
    }

    private static func codecs<C: Equatable>(
        from names: [String]?,
        parse: (String) -> C?,
        fallback: C
    ) -> [C] {
        var result = (names ?? []).compactMap(parse)
        if !result.contains(fallback) { result.append(fallback) }
        return result
    }
}
