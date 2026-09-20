import Foundation

/// A JSON message exchanged during an authenticated session.
///
/// On the wire every message is `{"type": "<name>", "payload": {...}}`, with
/// `payload` omitted for messages that carry nothing. The `type` string
/// selects the payload shape, so decoding is exact: a message is either
/// understood completely or rejected with `ControlMessageError`, never
/// misread as a different message that happens to have similar fields.
///
/// Direction is noted on each case. A peer that receives a message it does
/// not expect for its role should ignore it.
public enum ControlMessage: Equatable, Sendable {
    // MARK: Session

    /// Either direction. Answer with `.pong`. Used for liveness and to
    /// measure round-trip time.
    case ping

    /// Either direction. Reply to `.ping`.
    case pong

    /// Client to host. Ask for the host's clock. Send only to a host whose
    /// `PeerCapabilities.supportsClockSync` is true.
    case clockProbe(ClockProbe)

    /// Host to client. Reply to `.clockProbe`, with the probe's fields echoed
    /// and the host's receive and send times added.
    case clockReply(ClockReply)

    /// Client to host. Start sending media.
    case streamRequest

    /// Client to host. Stop sending media; the connection stays open.
    case streamStop

    // MARK: Quality

    /// Client to host. How well the stream is playing, 0 (unwatchable) to
    /// 1 (perfect), for the host's adaptation logic.
    case qualityFeedback(quality: Double)

    /// Client to host. Switch to this preset.
    case qualityRequest(QualityPreset)

    /// Host to client. The preset now in effect. Sent after a request and
    /// whenever auto-adaptation changes tier.
    case qualityChanged(QualityPreset)

    // MARK: Video

    /// Client to host. Crop capture to this region, or release the crop.
    case viewportLockRequest(ViewportLock)

    /// Client to host. Stop sending video; keep audio flowing. Send only to a
    /// host whose `PeerCapabilities.supportsVideoHold` is true.
    case videoPause

    /// Client to host. Resume video after `.videoPause`. The host restarts
    /// from a keyframe and resends parameter sets.
    case videoResume

    // MARK: Audio

    /// Host to client. The format of the audio that follows. Sent before the
    /// first audio packet and whenever it changes.
    case audioFormatChanged(AudioFormat)

    /// Client to host. Start or stop sending audio for this session. Not a
    /// mute: the host stops encoding. Send only to a host whose
    /// `supportsAudioToggle` is true; otherwise mute locally.
    case audioEnableRequest(enabled: Bool)

    /// Client to host. Never send video above this many bits per second, whatever the
    /// preset allows; `nil` lifts the cap. A user's ceiling for a shared or metered link.
    /// Since 1.4.1; older hosts ignore it.
    case bitrateCapRequest(bitsPerSecond: Int?)

    // MARK: Windows

    /// Client to host. Send me the windows you can capture.
    case windowListRequest

    /// Host to client. Reply to `.windowListRequest`. Only sent inside an
    /// authenticated session, because window titles are as private as the
    /// picture.
    case windowList([WindowInfo])

    /// Client to host. Capture this window, or `0` for the full display.
    case windowSelectRequest(windowID: UInt32)

    /// Host to client. What the host is capturing now. Sent after
    /// `.authSuccess` and whenever it changes from either side.
    case captureModeChanged(CaptureMode)

    // MARK: Input

    /// Client to host. A media key, a button from the host's advertised
    /// layout, typed text, a live keystroke, or a click on the stream.
    case mediaKey(MediaKeyCommand)
}

/// Why a `ControlMessage` could not be decoded.
public enum ControlMessageError: Error, Equatable, Sendable {
    /// The `type` string is not one this version knows. The sending peer is
    /// newer; ignore the message.
    case unknownType(String)

    /// A message that needs a payload arrived without one.
    case missingPayload(ControlMessage.Kind)
}

// MARK: - Payloads

/// Payload of `.viewportLockRequest`. Coordinates are normalised to 0...1 of
/// the full display currently being streamed, origin top-left.
public struct ViewportLock: Codable, Equatable, Sendable {
    public var locked: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(locked: Bool, x: Double = 0, y: Double = 0, width: Double = 1, height: Double = 1) {
        self.locked = locked
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Release the crop and stream the full display.
    public static let unlocked = ViewportLock(locked: false)
}

/// Payload of `.audioFormatChanged`.
public struct AudioFormat: Codable, Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int

    public init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// One capturable window, as listed by the host.
///
/// `id` is stable only for the life of that window. Clients refresh the list
/// rather than remembering ids. No thumbnails: title and app are enough to
/// choose from and keep the message small.
public struct WindowInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: UInt32
    public var title: String
    public var app: String

    public init(id: UInt32, title: String, app: String) {
        self.id = id
        self.title = title
        self.app = app
    }
}

/// Payload of `.captureModeChanged`.
public struct CaptureMode: Codable, Equatable, Sendable {
    /// `true` when capturing a single window, `false` for the full display.
    public var windowMode: Bool
    public var windowID: UInt32?
    public var title: String?
    public var app: String?

    public init(windowMode: Bool, windowID: UInt32? = nil, title: String? = nil, app: String? = nil) {
        self.windowMode = windowMode
        self.windowID = windowID
        self.title = title
        self.app = app
    }

    public static let fullDisplay = CaptureMode(windowMode: false)

    public static func window(_ window: WindowInfo) -> CaptureMode {
        CaptureMode(windowMode: true, windowID: window.id, title: window.title, app: window.app)
    }
}

/// Payload of `.mediaKey`. Started as a media-key message and grew into the
/// client's general input path, which is why it has both `key` and the
/// optional fields.
public struct MediaKeyCommand: Codable, Equatable, Sendable {
    public enum Key: String, Codable, CaseIterable, Sendable {
        case playPause = "play_pause"
        case next = "next"
        case previous = "previous"
        case seekBackward = "seek_backward"
        case seekForward = "seek_forward"
    }

    /// The built-in action. A host that advertised `controls` and receives a
    /// `controlID` acts on that instead and ignores `key`.
    public var key: Key

    /// `ControlButton.id` of the pressed button, when the host advertised a
    /// layout.
    public var controlID: String?

    /// Text the person entered for a `promptsForText` button. The host types
    /// it, followed by Return.
    public var text: String?

    /// One key from the live keyboard: a character, `"\n"` for Return or
    /// `"\u{8}"` for Backspace. The host types it immediately, nothing
    /// appended.
    public var keystroke: String?

    /// Modifier mask armed for this keystroke, in the host's native encoding
    /// (Carbon `cmdKey` and friends on macOS). The host posts the key as a
    /// chord when it can map the character to a key code.
    public var keystrokeModifiers: UInt32?

    /// A tap on the stream while a click mode is active.
    public var click: Click?

    public init(
        key: Key,
        controlID: String? = nil,
        text: String? = nil,
        keystroke: String? = nil,
        keystrokeModifiers: UInt32? = nil,
        click: Click? = nil
    ) {
        self.key = key
        self.controlID = controlID
        self.text = text
        self.keystroke = keystroke
        self.keystrokeModifiers = keystrokeModifiers
        self.click = click
    }
}

/// Where the person tapped, normalised to the frame the client is showing
/// (0...1, origin top-left). The host maps that through the viewport lock and
/// the captured window or display to a point on screen and clicks there.
public struct Click: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    /// `"left"` or `"right"`.
    public var button: String

    public init(x: Double, y: Double, button: String = "left") {
        self.x = x
        self.y = y
        self.button = button
    }
}

/// A clock probe: one sample for estimating the offset between two peers'
/// clocks, as in NTP. Times are microseconds of each peer's own monotonic
/// clock, the same clock as video presentation timestamps.
public struct ClockProbe: Codable, Equatable, Sendable {
    /// Matches a reply to its probe.
    public var id: UInt32
    /// The client's clock when it sent the probe.
    public var sentAt: Int64

    public init(id: UInt32, sentAt: Int64) {
        self.id = id
        self.sentAt = sentAt
    }
}

/// The host's answer to a `ClockProbe`.
public struct ClockReply: Codable, Equatable, Sendable {
    public var id: UInt32
    /// `ClockProbe.sentAt`, echoed.
    public var sentAt: Int64
    /// The host's clock when the probe arrived.
    public var receivedAt: Int64
    /// The host's clock when the reply left.
    public var repliedAt: Int64

    public init(id: UInt32, sentAt: Int64, receivedAt: Int64, repliedAt: Int64) {
        self.id = id
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.repliedAt = repliedAt
    }
}

// MARK: - Codable

extension ControlMessage {
    /// The `type` string of each message, and the set of names this version
    /// understands.
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case ping = "ping"
        case pong = "pong"
        case streamRequest = "stream_request"
        case streamStop = "stream_stop"
        case qualityFeedback = "quality_feedback"
        case qualityRequest = "quality_request"
        case qualityChanged = "quality_changed"
        case viewportLockRequest = "viewport_lock_request"
        case videoPause = "video_pause"
        case videoResume = "video_resume"
        case audioFormatChanged = "audio_format_changed"
        case audioEnableRequest = "audio_enable_request"
        case bitrateCapRequest = "bitrate_cap_request"
        case windowListRequest = "window_list_request"
        case windowList = "window_list"
        case windowSelectRequest = "window_select_request"
        case captureModeChanged = "capture_mode_changed"
        case mediaKey = "media_key"
        case clockProbe = "clock_probe"
        case clockReply = "clock_reply"
    }

    public var kind: Kind {
        switch self {
        case .ping: return .ping
        case .pong: return .pong
        case .streamRequest: return .streamRequest
        case .streamStop: return .streamStop
        case .qualityFeedback: return .qualityFeedback
        case .qualityRequest: return .qualityRequest
        case .qualityChanged: return .qualityChanged
        case .viewportLockRequest: return .viewportLockRequest
        case .videoPause: return .videoPause
        case .videoResume: return .videoResume
        case .audioFormatChanged: return .audioFormatChanged
        case .audioEnableRequest: return .audioEnableRequest
        case .bitrateCapRequest: return .bitrateCapRequest
        case .windowListRequest: return .windowListRequest
        case .windowList: return .windowList
        case .windowSelectRequest: return .windowSelectRequest
        case .captureModeChanged: return .captureModeChanged
        case .mediaKey: return .mediaKey
        case .clockProbe: return .clockProbe
        case .clockReply: return .clockReply
        }
    }
}

extension ControlMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, payload }

    // Single-field payloads keep their historical wrapper objects on the wire.
    private struct QualityValue: Codable { var quality: Double }
    private struct PresetValue: Codable { var preset: QualityPreset }
    private struct EnabledValue: Codable { var enabled: Bool }
    private struct BitrateCapValue: Codable { var bitsPerSecond: Int? }
    private struct WindowsValue: Codable { var windows: [WindowInfo] }
    private struct WindowIDValue: Codable { var windowID: UInt32 }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let typeName = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: typeName) else {
            throw ControlMessageError.unknownType(typeName)
        }

        func payload<T: Decodable>(_: T.Type) throws -> T {
            guard let value = try container.decodeIfPresent(T.self, forKey: .payload) else {
                throw ControlMessageError.missingPayload(kind)
            }
            return value
        }

        switch kind {
        case .ping: self = .ping
        case .pong: self = .pong
        case .streamRequest: self = .streamRequest
        case .streamStop: self = .streamStop
        case .videoPause: self = .videoPause
        case .videoResume: self = .videoResume
        case .windowListRequest: self = .windowListRequest
        case .qualityFeedback: self = .qualityFeedback(quality: try payload(QualityValue.self).quality)
        case .qualityRequest: self = .qualityRequest(try payload(PresetValue.self).preset)
        case .qualityChanged: self = .qualityChanged(try payload(PresetValue.self).preset)
        case .viewportLockRequest: self = .viewportLockRequest(try payload(ViewportLock.self))
        case .audioFormatChanged: self = .audioFormatChanged(try payload(AudioFormat.self))
        case .audioEnableRequest: self = .audioEnableRequest(enabled: try payload(EnabledValue.self).enabled)
        case .bitrateCapRequest: self = .bitrateCapRequest(bitsPerSecond: try container.decodeIfPresent(BitrateCapValue.self, forKey: .payload)?.bitsPerSecond)
        case .windowList: self = .windowList(try payload(WindowsValue.self).windows)
        case .windowSelectRequest: self = .windowSelectRequest(windowID: try payload(WindowIDValue.self).windowID)
        case .captureModeChanged: self = .captureModeChanged(try payload(CaptureMode.self))
        case .mediaKey: self = .mediaKey(try payload(MediaKeyCommand.self))
        case .clockProbe: self = .clockProbe(try payload(ClockProbe.self))
        case .clockReply: self = .clockReply(try payload(ClockReply.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .type)

        switch self {
        case .ping, .pong, .streamRequest, .streamStop, .videoPause, .videoResume, .windowListRequest:
            break
        case .qualityFeedback(let quality):
            try container.encode(QualityValue(quality: quality), forKey: .payload)
        case .qualityRequest(let preset), .qualityChanged(let preset):
            try container.encode(PresetValue(preset: preset), forKey: .payload)
        case .viewportLockRequest(let lock):
            try container.encode(lock, forKey: .payload)
        case .audioFormatChanged(let format):
            try container.encode(format, forKey: .payload)
        case .audioEnableRequest(let enabled):
            try container.encode(EnabledValue(enabled: enabled), forKey: .payload)
        case .bitrateCapRequest(let bitsPerSecond):
            try container.encode(BitrateCapValue(bitsPerSecond: bitsPerSecond), forKey: .payload)
        case .windowList(let windows):
            try container.encode(WindowsValue(windows: windows), forKey: .payload)
        case .windowSelectRequest(let windowID):
            try container.encode(WindowIDValue(windowID: windowID), forKey: .payload)
        case .captureModeChanged(let mode):
            try container.encode(mode, forKey: .payload)
        case .clockProbe(let probe):
            try container.encode(probe, forKey: .payload)
        case .clockReply(let reply):
            try container.encode(reply, forKey: .payload)
        case .mediaKey(let command):
            try container.encode(command, forKey: .payload)
        }
    }
}
