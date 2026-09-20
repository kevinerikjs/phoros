import Foundation
import Phoros

/// What the host advertises about itself in `pairSuccess` and `authSuccess`.
/// Fill in what your host can do; everything defaults to "not supported".
public struct HostCapabilities: Equatable, Sendable {
    public var deviceName: String?
    public var remoteHosts: [String]
    public var supportsRemoteAccess: Bool
    public var supportsVideoHold: Bool
    public var supportsAudioToggle: Bool
    public var supportsWindowSelection: Bool
    public var controls: [ControlButton]
    /// The host replays `.input` packets into a virtual game controller
    /// (see `PhorosInput.VirtualGamepad`).
    public var supportsControllerInput: Bool
    /// The host answers `.clockProbe`. See `PairingMessage.supportsClockSync`.
    public var supportsClockSync: Bool

    public init(
        deviceName: String? = nil,
        remoteHosts: [String] = [],
        supportsRemoteAccess: Bool = false,
        supportsVideoHold: Bool = false,
        supportsAudioToggle: Bool = false,
        supportsWindowSelection: Bool = false,
        controls: [ControlButton] = [],
        supportsControllerInput: Bool = false,
        supportsClockSync: Bool = false
    ) {
        self.deviceName = deviceName
        self.remoteHosts = remoteHosts
        self.supportsRemoteAccess = supportsRemoteAccess
        self.supportsVideoHold = supportsVideoHold
        self.supportsAudioToggle = supportsAudioToggle
        self.supportsWindowSelection = supportsWindowSelection
        self.controls = controls
        self.supportsControllerInput = supportsControllerInput
        self.supportsClockSync = supportsClockSync
    }

    fileprivate func message(_ type: PairingMessageType) -> PairingMessage {
        PairingMessage(
            type: type,
            deviceName: deviceName,
            remoteHosts: remoteHosts.isEmpty ? nil : remoteHosts,
            supportsRemoteAccess: supportsRemoteAccess ? true : nil,
            supportsVideoHold: supportsVideoHold ? true : nil,
            supportsAudioToggle: supportsAudioToggle ? true : nil,
            supportsWindowSelection: supportsWindowSelection ? true : nil,
            controls: controls.isEmpty ? nil : controls,
            supportsControllerInput: supportsControllerInput ? true : nil,
            supportsClockSync: supportsClockSync ? true : nil
        )
    }
}

/// The host side of one pairing attempt.
///
/// ```swift
/// var pairing = PairingHost(capabilities: myCapabilities)
/// let (challenge, code) = pairing.begin(hello: message)   // show `code` on screen
/// send(challenge)
/// …
/// switch pairing.verify(message) {
/// case .paired(let secret, let reply): store(secret, for: pairing.peerDeviceID); send(reply)
/// case .rejected(let reply): send(reply)
/// case .ignored: break
/// }
/// ```
///
/// The code never crosses the wire. The person carries it from the host's
/// screen to the client. Storage of the resulting secret is the app's.
public struct PairingHost: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The code matched. Store `secret` against `peerDeviceID` and send `reply`.
        case paired(secret: SharedSecret, reply: PairingMessage)
        /// The code did not match. Send `reply`; the attempt stays open for a retry.
        case rejected(reply: PairingMessage)
        /// Not a `codeVerify`, or no attempt is in progress.
        case ignored
    }

    public var capabilities: HostCapabilities

    /// The client that said hello, once `begin` has run.
    public private(set) var peerDeviceID: String?
    public private(set) var peerDeviceName: String?

    /// The code being shown, once `begin` has run.
    public private(set) var code: String?

    /// Wall-clock deadline after which `verify` ignores everything.
    public private(set) var expiresAt: Date?

    public init(capabilities: HostCapabilities) {
        self.capabilities = capabilities
    }

    public var isActive: Bool { code != nil }

    /// Starts an attempt from a `hello`. Returns the challenge to send and the
    /// code to display. Returns `nil` if the message is not a hello or has no
    /// device id.
    public mutating func begin(
        hello: PairingMessage,
        code: String = PairingCode.generate(),
        validFor: TimeInterval = 300,
        now: Date = Date()
    ) -> (challenge: PairingMessage, code: String)? {
        guard hello.type == .hello, let deviceID = hello.deviceID else { return nil }
        peerDeviceID = deviceID
        peerDeviceName = hello.deviceName ?? deviceID
        self.code = code
        expiresAt = now.addingTimeInterval(validFor)
        return (PairingMessage(type: .challenge, deviceName: capabilities.deviceName), code)
    }

    /// Checks a `codeVerify`.
    public mutating func verify(
        _ message: PairingMessage,
        secret: SharedSecret = .generate(),
        now: Date = Date()
    ) -> Outcome {
        guard message.type == .codeVerify, let expected = code, let expiresAt else { return .ignored }
        guard now < expiresAt else {
            cancel()
            return .ignored
        }
        guard message.code == expected else {
            return .rejected(reply: PairingMessage(type: .pairFailed, error: "Incorrect code"))
        }
        var reply = capabilities.message(.pairSuccess)
        reply.sharedSecret = secret.hex
        cancel()
        return .paired(secret: secret, reply: reply)
    }

    /// Abandon the attempt. The code stops being valid.
    public mutating func cancel() {
        code = nil
        expiresAt = nil
    }
}

/// The host side of authenticating a returning client.
public enum HostAuthenticator {
    public struct Session: Equatable, Sendable {
        public var deviceID: String
        public var peer: PeerCapabilities
        public var audioCodec: AudioCodecID
        public var videoCodec: VideoCodecID
        /// The `authSuccess` to send.
        public var reply: PairingMessage
    }

    public enum Outcome: Equatable, Sendable {
        case authenticated(Session)
        /// Send `reply` and close the connection.
        case rejected(reply: PairingMessage)
    }

    /// Checks an `authRequest` against the stored secret for its device and,
    /// on success, negotiates codecs from the client's advertisement.
    ///
    /// - Parameters:
    ///   - request: The incoming message. Anything but an `authRequest` is rejected.
    ///   - storedSecret: Looks up the secret paired with a device id. `nil`
    ///     means the device is not paired.
    ///   - capabilities: What this host advertises.
    ///   - audioPreferences: Codecs the host would like to send, best first.
    ///     Pass `[.pcmFloat32]` to force PCM.
    ///   - videoPreferences: Same for video.
    public static func authenticate(
        _ request: PairingMessage,
        storedSecret: (String) -> SharedSecret?,
        capabilities: HostCapabilities,
        audioPreferences: [AudioCodecID] = [.aacLC, .pcmFloat32],
        videoPreferences: [VideoCodecID] = [.hevc, .h264]
    ) -> Outcome {
        guard request.type == .authRequest,
              let deviceID = request.deviceID,
              let hex = request.sharedSecret,
              let presented = SharedSecret(hex: hex)
        else {
            return .rejected(reply: PairingMessage(type: .authFailed, error: "Invalid auth request"))
        }
        guard let stored = storedSecret(deviceID) else {
            return .rejected(reply: PairingMessage(type: .authFailed, error: "Device not paired"))
        }
        guard stored.matches(presented) else {
            return .rejected(reply: PairingMessage(type: .authFailed, error: "Authentication failed"))
        }

        let peer = PeerCapabilities(request)
        let audio = peer.preferredAudioCodec(from: audioPreferences)
        let video = peer.preferredVideoCodec(from: videoPreferences)
        var reply = capabilities.message(.authSuccess)
        reply.selectedAudioCodec = audio.wireName
        reply.selectedVideoCodec = video.wireName
        return .authenticated(Session(deviceID: deviceID, peer: peer, audioCodec: audio, videoCodec: video, reply: reply))
    }
}
