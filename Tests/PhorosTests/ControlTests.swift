import XCTest
import Phoros

final class ControlTests: XCTestCase {
    private func decode(_ json: String) throws -> ControlMessage {
        try JSONDecoder().decode(ControlMessage.self, from: Data(json.utf8))
    }

    private func object(_ message: ControlMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    /// One example of every message, paired with the JSON a shipped peer
    /// produces for it. If a case is added without a fixture here, the
    /// exhaustiveness check at the bottom fails.
    private let fixtures: [(ControlMessage, String)] = [
        (.ping, #"{"type":"ping"}"#),
        (.pong, #"{"type":"pong"}"#),
        (.streamRequest, #"{"type":"stream_request"}"#),
        (.streamStop, #"{"type":"stream_stop"}"#),
        (.qualityFeedback(quality: 0.5), #"{"type":"quality_feedback","payload":{"quality":0.5}}"#),
        (.qualityRequest(.p720_30), #"{"type":"quality_request","payload":{"preset":"720p30"}}"#),
        (.qualityChanged(.p1080_60), #"{"type":"quality_changed","payload":{"preset":"1080p60"}}"#),
        (.viewportLockRequest(ViewportLock(locked: true, x: 0.1, y: 0.2, width: 0.5, height: 0.25)),
         #"{"type":"viewport_lock_request","payload":{"locked":true,"x":0.1,"y":0.2,"width":0.5,"height":0.25}}"#),
        (.videoPause, #"{"type":"video_pause"}"#),
        (.videoResume, #"{"type":"video_resume"}"#),
        (.audioFormatChanged(AudioFormat(sampleRate: 48_000, channels: 2)),
         #"{"type":"audio_format_changed","payload":{"sampleRate":48000,"channels":2}}"#),
        (.audioEnableRequest(enabled: false), #"{"type":"audio_enable_request","payload":{"enabled":false}}"#),
        (.bitrateCapRequest(bitsPerSecond: 8_000_000), #"{"type":"bitrate_cap_request","payload":{"bitsPerSecond":8000000}}"#),
        (.bitrateCapRequest(bitsPerSecond: nil), #"{"type":"bitrate_cap_request","payload":{}}"#),
        (.windowListRequest, #"{"type":"window_list_request"}"#),
        (.windowList([WindowInfo(id: 12, title: "Notes", app: "Notes")]),
         #"{"type":"window_list","payload":{"windows":[{"id":12,"title":"Notes","app":"Notes"}]}}"#),
        (.windowSelectRequest(windowID: 0), #"{"type":"window_select_request","payload":{"windowID":0}}"#),
        (.captureModeChanged(CaptureMode(windowMode: true, windowID: 12, title: "Notes", app: "Notes")),
         #"{"type":"capture_mode_changed","payload":{"windowMode":true,"windowID":12,"title":"Notes","app":"Notes"}}"#),
        (.mediaKey(MediaKeyCommand(key: .playPause, controlID: "b1", keystroke: "\n", keystrokeModifiers: 256,
                                   click: Click(x: 0.5, y: 0.5, button: "right"))),
         #"{"type":"media_key","payload":{"key":"play_pause","controlID":"b1","keystroke":"\n","keystrokeModifiers":256,"click":{"x":0.5,"y":0.5,"button":"right"}}}"#),
        (.clockProbe(ClockProbe(id: 7, sentAt: 1_000_000)), #"{"type":"clock_probe","payload":{"id":7,"sentAt":1000000}}"#),
        (.clockReply(ClockReply(id: 7, sentAt: 1_000_000, receivedAt: 5_000_000, repliedAt: 5_000_020)),
         #"{"type":"clock_reply","payload":{"id":7,"sentAt":1000000,"receivedAt":5000000,"repliedAt":5000020}}"#),
    ]

    func testEveryMessageDecodesFromItsShippedJSON() throws {
        for (expected, json) in fixtures {
            XCTAssertEqual(try decode(json), expected, json)
        }
    }

    func testEveryMessageEncodesToItsShippedJSON() throws {
        for (message, json) in fixtures {
            let expected = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! NSDictionary
            XCTAssertEqual(try object(message) as NSDictionary, expected, json)
        }
    }

    func testFixturesCoverEveryKind() {
        XCTAssertEqual(Set(fixtures.map { $0.0.kind }), Set(ControlMessage.Kind.allCases))
    }

    func testKindNamesArePinned() {
        XCTAssertEqual(ControlMessage.Kind.allCases.map(\.rawValue), [
            "ping", "pong", "stream_request", "stream_stop",
            "quality_feedback", "quality_request", "quality_changed",
            "viewport_lock_request", "video_pause", "video_resume",
            "audio_format_changed", "audio_enable_request", "bitrate_cap_request",
            "window_list_request", "window_list", "window_select_request", "capture_mode_changed",
            "media_key",
            "clock_probe", "clock_reply",
        ])
    }

    func testMessagesWithoutPayloadOmitTheKey() throws {
        XCTAssertEqual(Set(try object(.ping).keys), ["type"])
    }

    func testNullPayloadFromOlderEncodersIsTolerated() throws {
        XCTAssertEqual(try decode(#"{"type":"pong","payload":null}"#), .pong)
    }

    func testQualityChangedAndRequestAreDistinctDespiteIdenticalPayloads() throws {
        XCTAssertEqual(try decode(#"{"type":"quality_changed","payload":{"preset":"auto"}}"#), .qualityChanged(.auto))
        XCTAssertEqual(try decode(#"{"type":"quality_request","payload":{"preset":"auto"}}"#), .qualityRequest(.auto))
    }

    func testUnknownTypeIsReportedNotGuessed() {
        XCTAssertThrowsError(try decode(#"{"type":"teleport","payload":{"enabled":true}}"#)) { error in
            XCTAssertEqual(error as? ControlMessageError, .unknownType("teleport"))
        }
    }

    func testMissingPayloadIsReported() {
        XCTAssertThrowsError(try decode(#"{"type":"quality_request"}"#)) { error in
            XCTAssertEqual(error as? ControlMessageError, .missingPayload(.qualityRequest))
        }
    }

    func testWrongShapedPayloadIsRejectedNotCoerced() {
        // {"enabled": true} is a valid object; it is not a window selection.
        XCTAssertThrowsError(try decode(#"{"type":"window_select_request","payload":{"enabled":true}}"#))
    }

    func testClockProbeAndReplyRoundTrip() throws {
        let probe = ControlMessage.clockProbe(ClockProbe(id: 7, sentAt: 1_000_000))
        let probeObject = try object(probe)
        XCTAssertEqual(probeObject["type"] as? String, "clock_probe")
        XCTAssertEqual((probeObject["payload"] as? [String: Any])?["sentAt"] as? Int64, 1_000_000)
        XCTAssertEqual(try decode(#"{"type":"clock_probe","payload":{"id":7,"sentAt":1000000}}"#), probe)

        let reply = ControlMessage.clockReply(ClockReply(id: 7, sentAt: 1_000_000, receivedAt: 5_000_000, repliedAt: 5_000_020))
        XCTAssertEqual(try decode(#"{"type":"clock_reply","payload":{"id":7,"sentAt":1000000,"receivedAt":5000000,"repliedAt":5000020}}"#), reply)
        XCTAssertThrowsError(try decode(#"{"type":"clock_reply","payload":{"id":7}}"#), "a reply without times is not a reply")
    }

    func testMediaKeyOptionalFieldsAreOmittedWhenNil() throws {
        let object = try object(.mediaKey(MediaKeyCommand(key: .next)))
        XCTAssertEqual((object["payload"] as? [String: Any])?.keys.sorted(), ["key"])
    }
}
