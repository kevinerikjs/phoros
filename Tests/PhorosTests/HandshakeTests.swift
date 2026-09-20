import XCTest
import Phoros

final class HandshakeTests: XCTestCase {
    private func json(_ message: PairingMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testTypeNamesArePinned() {
        XCTAssertEqual(PairingMessageType.allCases.map(\.rawValue), [
            "hello", "challenge", "code_verify", "pair_success", "pair_failed",
            "auth_request", "auth_success", "auth_failed", "unpaired",
        ])
    }

    func testMessageFromAHostThatPredatesEveryCapabilityDecodes() throws {
        // Exactly what the first shipped host sent on auth_success.
        let legacy = Data(#"{"type":"auth_success","deviceName":"Mac"}"#.utf8)
        let message = try JSONDecoder().decode(PairingMessage.self, from: legacy)
        XCTAssertEqual(message.type, .authSuccess)
        XCTAssertEqual(message.deviceName, "Mac")
        XCTAssertNil(message.supportsVideoHold)
        XCTAssertNil(message.controls)

        let peer = PeerCapabilities(message)
        XCTAssertFalse(peer.supportsVideoHold)
        XCTAssertFalse(peer.supportsRemoteAccess)
        XCTAssertFalse(peer.supportsAudioToggle)
        XCTAssertFalse(peer.supportsWindowSelection)
        XCTAssertFalse(peer.supportsControllerInput)
        XCTAssertTrue(peer.wantsAudio)
        XCTAssertEqual(peer.remoteHosts, [])
        XCTAssertEqual(peer.controls, [])
    }

    func testNilFieldsAreOmittedAndHistoricalKeysAreKept() throws {
        let message = PairingMessage(
            type: .authSuccess,
            deviceName: "Mac",
            remoteHosts: ["100.64.0.1", "mac.tailnet.ts.net"],
            supportsVideoHold: true,
            controls: [ControlButton(id: "1", symbol: "playpause", label: "Play")]
        )
        let object = try json(message)

        XCTAssertEqual(Set(object.keys), ["type", "deviceName", "tailscaleHosts", "supportsVideoHold", "phoneControls"])
        XCTAssertEqual(object["tailscaleHosts"] as? [String], ["100.64.0.1", "mac.tailnet.ts.net"])
        XCTAssertNil(object["remoteHosts"])
        XCTAssertNil(object["controls"])

        let decoded = try JSONDecoder().decode(PairingMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded, message)
    }

    func testMessageWithUnknownFutureFieldsDecodes() throws {
        let future = Data(#"{"type":"auth_request","deviceID":"d","sharedSecret":"s","supportsTeleportation":true,"supportedAudioCodecs":["opus","aac_lc"]}"#.utf8)
        let message = try JSONDecoder().decode(PairingMessage.self, from: future)
        XCTAssertEqual(PeerCapabilities(message).audioCodecs, [.aacLC, .pcmFloat32])
    }

    func testControllerInputCapabilityIsAdvertisedOnlyWhenTrue() throws {
        let host = PairingMessage(type: .authSuccess, supportsControllerInput: true)
        XCTAssertEqual(try json(host)["supportsControllerInput"] as? Bool, true)
        XCTAssertTrue(PeerCapabilities(host).supportsControllerInput)

        let explicitNo = Data(#"{"type":"auth_success","supportsControllerInput":false}"#.utf8)
        XCTAssertFalse(PeerCapabilities(try JSONDecoder().decode(PairingMessage.self, from: explicitNo)).supportsControllerInput)
    }

    func testClockSyncCapabilityIsAdvertisedOnlyWhenTrue() throws {
        let host = PairingMessage(type: .authSuccess, supportsClockSync: true)
        XCTAssertEqual(try json(host)["supportsClockSync"] as? Bool, true)
        XCTAssertTrue(PeerCapabilities(host).supportsClockSync)
        XCTAssertNil(try json(PairingMessage(type: .authSuccess))["supportsClockSync"])
        XCTAssertFalse(PeerCapabilities(PairingMessage(type: .authSuccess)).supportsClockSync)
    }

    func testMaximumFrameRateRaisesOnlySixtyFpsPresets() throws {
        let request = PairingMessage(type: .authRequest, maximumFrameRate: 120)
        XCTAssertEqual(try json(request)["maximumFrameRate"] as? Double, 120)
        let peer = PeerCapabilities(request)
        XCTAssertEqual(peer.videoFrameRate(preset: 60, hostRefreshRate: 165), 120, "the client's display is the limit")
        XCTAssertEqual(peer.videoFrameRate(preset: 60, hostRefreshRate: 60), 60, "the host's display is the limit")
        XCTAssertEqual(peer.videoFrameRate(preset: 30, hostRefreshRate: 165), 30, "30 fps presets stay at 30")

        let legacy = PeerCapabilities(PairingMessage(type: .authRequest))
        XCTAssertNil(legacy.maximumFrameRate)
        XCTAssertEqual(legacy.videoFrameRate(preset: 60, hostRefreshRate: 165), 60, "absent means the preset's rate")
        XCTAssertNil(PeerCapabilities(PairingMessage(type: .authRequest, maximumFrameRate: 0)).maximumFrameRate)
    }

    // MARK: Capability interpretation

    func testAbsentCodecListMeansLegacyCodecsOnly() {
        let peer = PeerCapabilities(PairingMessage(type: .authRequest))
        XCTAssertEqual(peer.audioCodecs, [.pcmFloat32])
        XCTAssertEqual(peer.videoCodecs, [.h264])
        XCTAssertEqual(peer.preferredAudioCodec(), .pcmFloat32)
        XCTAssertEqual(peer.preferredVideoCodec(), .h264)
    }

    func testEmptyCodecListMeansTheSameAsAbsent() {
        let peer = PeerCapabilities(PairingMessage(type: .authRequest, supportedAudioCodecs: [], supportedVideoCodecs: []))
        XCTAssertEqual(peer.audioCodecs, [.pcmFloat32])
        XCTAssertEqual(peer.videoCodecs, [.h264])
    }

    func testAdvertisedCodecsAreHonouredInOrderAndLegacyIsAlwaysPresent() {
        let peer = PeerCapabilities(PairingMessage(
            type: .authRequest,
            supportedAudioCodecs: ["aac_lc"],
            supportedVideoCodecs: ["hevc", "h264"]
        ))
        XCTAssertEqual(peer.audioCodecs, [.aacLC, .pcmFloat32])
        XCTAssertEqual(peer.videoCodecs, [.hevc, .h264])
        XCTAssertEqual(peer.preferredAudioCodec(), .aacLC)
        XCTAssertEqual(peer.preferredAudioCodec(from: [.pcmFloat32]), .pcmFloat32)
        XCTAssertEqual(peer.preferredVideoCodec(), .hevc)
        XCTAssertEqual(peer.preferredVideoCodec(from: [.h264]), .h264)
    }

    func testControlButtonRoundTripsWithOptionalFieldsOmitted() throws {
        let button = ControlButton(id: "abc", symbol: "keyboard", label: "Type", mode: "keyboard")
        let data = try JSONEncoder().encode(button)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["id", "symbol", "label", "mode"])
        XCTAssertEqual(try JSONDecoder().decode(ControlButton.self, from: data), button)
    }
}
