import Foundation

/// The kinds of handshake message. Sent as the `type` field of a
/// `PairingMessage`.
///
/// Pairing happens once, on the client's initiative, and ends with a shared
/// secret both sides store. Every later connection authenticates with that
/// secret. Both flows use the same message shape.
///
/// ```
/// pairing                          authentication
/// client        host               client        host
///   |-- hello ---->|                 |-- authRequest -->|
///   |<- challenge -|  host shows     |<- authSuccess ---|  stream starts
///   |              |  a code on      |   or             |
///   |-- codeVerify>|  its screen     |<- authFailed ----|
///   |<- pairSuccess|  with secret    |                  |
///   |   or         |                 |<- unpaired ------|  host removed
///   |<- pairFailed |                 |                  |  this device
/// ```
public enum PairingMessageType: String, Codable, CaseIterable, Sendable {
    /// Client to host. "I want to pair; here is my name and stable id."
    case hello = "hello"

    /// Host to client. "Type the code I am showing." The code itself is not
    /// in the message; it goes through the person, which is the point.
    case challenge = "challenge"

    /// Client to host. "The person typed this code."
    case codeVerify = "code_verify"

    /// Host to client. "Correct. Here is the shared secret; store it."
    case pairSuccess = "pair_success"

    /// Host to client. "Wrong code."
    case pairFailed = "pair_failed"

    /// Client to host, on every connection after pairing. Carries the stored
    /// secret and everything the client can do.
    case authRequest = "auth_request"

    /// Host to client. "Authenticated; streaming starts now." Carries
    /// everything the host can do and what it chose for this session.
    case authSuccess = "auth_success"

    /// Host to client. "Secret did not match, or device is not paired."
    case authFailed = "auth_failed"

    /// Host to client. "This device was removed on the host. Forget the
    /// secret and pair again."
    case unpaired = "unpaired"
}

/// One JSON message of the pairing and authentication handshake.
///
/// Every field after `type` is optional and only some apply to each type;
/// the table in docs/wire-format.md says which. The optionality is the
/// compatibility mechanism: a peer that does not know a field ignores it, a
/// peer that does not send one leaves it absent, and `PeerCapabilities` turns
/// absence into the conservative interpretation.
///
/// Two field names are historical and kept as wire keys: `remoteHosts` is
/// encoded as `tailscaleHosts`, and `controls` as `phoneControls`.
public struct PairingMessage: Codable, Equatable, Sendable {
    public var type: PairingMessageType

    /// Human-readable name of the sender, for lists and prompts.
    public var deviceName: String?

    /// Client to host. A UUID the client keeps for its lifetime, so the host
    /// can recognise it across reinstalls of nothing but the secret.
    public var deviceID: String?

    /// Client to host in `.codeVerify`: the six-digit code the person typed.
    public var code: String?

    /// Host to client in `.pairSuccess`: hex-encoded 32 random bytes.
    /// Client to host in `.authRequest`: the same bytes, proving identity.
    public var sharedSecret: String?

    /// Host to client in a failure: a sentence the client may show.
    public var error: String?

    // MARK: Host capabilities and session choices (host to client)

    /// Addresses the host can be reached at from outside the local network,
    /// such as a VPN or overlay-network address and its DNS name. Sent on
    /// `.pairSuccess` and refreshed on every `.authSuccess` so the client's
    /// stored copy never goes stale.
    public var remoteHosts: [String]?

    /// Always `true` from hosts that support remote connections. Its absence
    /// is the useful signal: such a host predates remote access entirely,
    /// which is a different situation from a host that supports it but has
    /// no remote address right now. Both produce an empty `remoteHosts`, and
    /// the client should tell the person different things.
    public var supportsRemoteAccess: Bool?

    /// `true` only from hosts that correctly resume video after the client
    /// releases a `.videoPause`. A host that accepts the message but predates
    /// the fix strands the client's decoder: every frame during the hold is
    /// dropped, including the keyframe, and the stream stays black. Absent
    /// means "do not pause video on this host".
    public var supportsVideoHold: Bool?

    /// Host to client on `.authSuccess`: the audio codec chosen for this
    /// session, by `wireName`. Informational. Each audio packet's flags are
    /// the authority, because the host may fall back to PCM mid-session.
    public var selectedAudioCodec: String?

    /// Host to client on `.authSuccess`: the video codec chosen for this
    /// session, by `wireName`. Informational; the `.parameterSets` packet's
    /// flags are the authority.
    public var selectedVideoCodec: String?

    /// `true` from hosts that act on `.audioEnableRequest`. Absent means the
    /// host keeps sending audio regardless and the client mutes locally.
    public var supportsAudioToggle: Bool?

    /// `true` from hosts that answer `.windowListRequest` and act on
    /// `.windowSelectRequest`.
    public var supportsWindowSelection: Bool?

    /// Buttons the host would like the client to show, in order. Absent means
    /// the client shows its built-in media keys.
    public var controls: [ControlButton]?

    /// `true` from hosts that replay `.input` packets into a virtual game
    /// controller. Absent means the host drops them, so the client should not
    /// sample a controller or show that one is forwarded. Sent on
    /// `.pairSuccess` and `.authSuccess`.
    public var supportsControllerInput: Bool?

    /// `true` from hosts that answer `ControlMessage.clockProbe` with
    /// `.clockReply`. Absent means the host drops probes, so the client has
    /// no clock offset and no frame age. Sent on `.authSuccess`.
    public var supportsClockSync: Bool?

    // MARK: Client capabilities and preferences (client to host)

    /// The client's native audio hardware rate, so the host can encode to it
    /// from the first packet instead of guessing and switching mid-stream.
    public var preferredAudioSampleRate: Double?

    /// `AudioCodecID.wireName`s the client can decode, most preferred first.
    /// Sent on `.hello` and on every `.authRequest`. Absent or empty means
    /// PCM only. Unknown names are ignored by the host.
    public var supportedAudioCodecs: [String]?

    /// `VideoCodecID.wireName`s the client can decode, most preferred first.
    /// Absent or empty means H.264 only. Unknown names are ignored.
    public var supportedVideoCodecs: [String]?

    /// Whether the client wants audio packets at all for this session.
    /// Absent means yes.
    public var wantsAudio: Bool?

    /// The highest video frame rate the client wants, normally its display's
    /// refresh rate. A host captures and encodes at the lower of this and
    /// its own display, when the preset allows more than 30 fps. Absent
    /// means the preset's own rate, which is what every client got before
    /// this field existed. Sent on `.authRequest`.
    public var maximumFrameRate: Double?

    public init(
        type: PairingMessageType,
        deviceName: String? = nil,
        deviceID: String? = nil,
        code: String? = nil,
        sharedSecret: String? = nil,
        error: String? = nil,
        remoteHosts: [String]? = nil,
        supportsRemoteAccess: Bool? = nil,
        supportsVideoHold: Bool? = nil,
        selectedAudioCodec: String? = nil,
        selectedVideoCodec: String? = nil,
        supportsAudioToggle: Bool? = nil,
        supportsWindowSelection: Bool? = nil,
        controls: [ControlButton]? = nil,
        supportsControllerInput: Bool? = nil,
        preferredAudioSampleRate: Double? = nil,
        supportedAudioCodecs: [String]? = nil,
        supportedVideoCodecs: [String]? = nil,
        wantsAudio: Bool? = nil,
        supportsClockSync: Bool? = nil,
        maximumFrameRate: Double? = nil
    ) {
        self.type = type
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.code = code
        self.sharedSecret = sharedSecret
        self.error = error
        self.remoteHosts = remoteHosts
        self.supportsRemoteAccess = supportsRemoteAccess
        self.supportsVideoHold = supportsVideoHold
        self.selectedAudioCodec = selectedAudioCodec
        self.selectedVideoCodec = selectedVideoCodec
        self.supportsAudioToggle = supportsAudioToggle
        self.supportsWindowSelection = supportsWindowSelection
        self.controls = controls
        self.supportsControllerInput = supportsControllerInput
        self.preferredAudioSampleRate = preferredAudioSampleRate
        self.supportedAudioCodecs = supportedAudioCodecs
        self.supportedVideoCodecs = supportedVideoCodecs
        self.wantsAudio = wantsAudio
        self.supportsClockSync = supportsClockSync
        self.maximumFrameRate = maximumFrameRate
    }

    private enum CodingKeys: String, CodingKey {
        case type, deviceName, deviceID, code, sharedSecret, error
        case remoteHosts = "tailscaleHosts"
        case supportsRemoteAccess, supportsVideoHold
        case selectedAudioCodec, selectedVideoCodec
        case supportsAudioToggle, supportsWindowSelection
        case controls = "phoneControls"
        case supportsControllerInput
        case preferredAudioSampleRate, supportedAudioCodecs, supportedVideoCodecs, wantsAudio
        case supportsClockSync, maximumFrameRate
    }
}

/// A button the host asks the client to render, and what the client sends
/// back when it is pressed.
///
/// Pressing one sends `ControlMessage.mediaKey` with `controlID` set to `id`.
/// A host that advertised buttons acts on `controlID` and ignores the legacy
/// `key`; the client still fills `key` for the built-in buttons so an older
/// host does something sensible.
public struct ControlButton: Codable, Equatable, Identifiable, Sendable {
    /// Stable within one host; echoed back as `MediaKeyCommand.controlID`.
    public var id: String

    /// SF Symbols name for the button face.
    public var symbol: String

    /// Accessibility label and fallback text.
    public var label: String

    /// Render larger. Absent means no.
    public var prominent: Bool?

    /// The client should ask the person for a line of text and send it as
    /// `MediaKeyCommand.text`. Absent means no.
    public var promptsForText: Bool?

    /// Prompt to show when asking for text.
    public var textPrompt: String?

    /// How the button behaves on the client. Known values: `tap` (send on
    /// press), `text` (prompt, then send), `keyboard` (open the live
    /// keyboard, each key goes as `keystroke`), `click`, `click_left`,
    /// `click_right` (toggle click mode; taps on the stream go as `click`),
    /// `modifier` (arm `modifier` for the next keystroke). Absent means `tap`,
    /// or `text` when `promptsForText` is set. Unknown values should be
    /// treated as `tap`.
    public var mode: String?

    /// For `mode == "modifier"`: which key, as the host names it
    /// (`cmd`, `shift`, `option`, `control`).
    public var modifier: String?

    public init(
        id: String,
        symbol: String,
        label: String,
        prominent: Bool? = nil,
        promptsForText: Bool? = nil,
        textPrompt: String? = nil,
        mode: String? = nil,
        modifier: String? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.label = label
        self.prominent = prominent
        self.promptsForText = promptsForText
        self.textPrompt = textPrompt
        self.mode = mode
        self.modifier = modifier
    }
}
