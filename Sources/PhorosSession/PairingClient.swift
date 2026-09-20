import Foundation
import Phoros

/// What the client advertises about itself in `hello` and `authRequest`.
public struct ClientCapabilities: Equatable, Sendable {
    public var deviceName: String
    /// Stable for the life of the install; the host stores the secret against it.
    public var deviceID: String
    /// `AudioCodecID`s this client can decode, most preferred first.
    public var audioCodecs: [AudioCodecID]
    /// `VideoCodecID`s this client can decode, most preferred first.
    public var videoCodecs: [VideoCodecID]
    public var preferredAudioSampleRate: Double?
    public var wantsAudio: Bool
    /// The highest video frame rate this client wants, normally its display's
    /// refresh rate. `nil` asks for the preset's own rate. See
    /// `PairingMessage.maximumFrameRate`.
    public var maximumFrameRate: Double?

    public init(
        deviceName: String,
        deviceID: String,
        audioCodecs: [AudioCodecID] = [.aacLC, .pcmFloat32],
        videoCodecs: [VideoCodecID] = [.hevc, .h264],
        preferredAudioSampleRate: Double? = nil,
        wantsAudio: Bool = true,
        maximumFrameRate: Double? = nil
    ) {
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.audioCodecs = audioCodecs
        self.videoCodecs = videoCodecs
        self.preferredAudioSampleRate = preferredAudioSampleRate
        self.wantsAudio = wantsAudio
        self.maximumFrameRate = maximumFrameRate
    }

    /// The `hello` that starts pairing.
    public func hello() -> PairingMessage {
        PairingMessage(
            type: .hello,
            deviceName: deviceName,
            deviceID: deviceID,
            supportedAudioCodecs: audioCodecs.map(\.wireName),
            supportedVideoCodecs: videoCodecs.map(\.wireName)
        )
    }

    /// The `codeVerify` carrying what the person typed.
    public func codeVerify(_ code: String) -> PairingMessage {
        PairingMessage(type: .codeVerify, deviceID: deviceID, code: code)
    }

    /// The `authRequest` for a connection after pairing.
    public func authRequest(secret: SharedSecret) -> PairingMessage {
        PairingMessage(
            type: .authRequest,
            deviceName: deviceName,
            deviceID: deviceID,
            sharedSecret: secret.hex,
            preferredAudioSampleRate: preferredAudioSampleRate,
            supportedAudioCodecs: audioCodecs.map(\.wireName),
            supportedVideoCodecs: videoCodecs.map(\.wireName),
            wantsAudio: wantsAudio,
            maximumFrameRate: maximumFrameRate
        )
    }
}

/// The client side of pairing and authentication, as an interpreter of host
/// replies. It holds no connection; it tells you what the host said.
public enum PairingClient {
    public enum Event: Equatable, Sendable {
        /// The host is showing a code. Ask the person to type it.
        case codeRequested(hostName: String?)
        /// Paired. Store `secret` for this host, along with `host`.
        case paired(secret: SharedSecret, host: PeerCapabilities, hostName: String?)
        /// Authenticated. Media will follow.
        case authenticated(host: PeerCapabilities, hostName: String?, audioCodec: AudioCodecID?, videoCodec: VideoCodecID?)
        /// The host said no. `reason` is safe to show.
        case failed(reason: String)
        /// The host removed this device. Forget the secret and pair again.
        case unpaired
        /// A message a client never receives.
        case unexpected(PairingMessageType)
    }

    /// Interprets one host message.
    public static func interpret(_ message: PairingMessage) -> Event {
        switch message.type {
        case .challenge:
            return .codeRequested(hostName: message.deviceName)
        case .pairSuccess:
            guard let hex = message.sharedSecret, let secret = SharedSecret(hex: hex) else {
                return .failed(reason: "The host sent an invalid secret")
            }
            return .paired(secret: secret, host: PeerCapabilities(message), hostName: message.deviceName)
        case .pairFailed:
            return .failed(reason: message.error ?? "Pairing failed")
        case .authSuccess:
            return .authenticated(
                host: PeerCapabilities(message),
                hostName: message.deviceName,
                audioCodec: message.selectedAudioCodec.flatMap(AudioCodecID.init(wireName:)),
                videoCodec: message.selectedVideoCodec.flatMap(VideoCodecID.init(wireName:))
            )
        case .authFailed:
            return .failed(reason: message.error ?? "Authentication failed")
        case .unpaired:
            return .unpaired
        case .hello, .codeVerify, .authRequest:
            return .unexpected(message.type)
        }
    }
}
