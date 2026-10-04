import XCTest
import Phoros

final class MediaTests: XCTestCase {
    // MARK: Video fragments

    func testVideoFragmentHeaderBytesArePinned() {
        let header = VideoFragmentHeader(
            frameNumber: 0x0102_0304, fragmentIndex: 0x0506, fragmentCount: 0x0708,
            presentationTimestamp: 0x090A_0B0C_0D0E_0F10
        )
        XCTAssertEqual(header.serialized(), Data([
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        ]))
        XCTAssertEqual(VideoFragmentHeader.parse(from: header.serialized()), header)
    }

    func testVideoFragmentHeaderHandlesNegativeTimestampsAndSlices() {
        let header = VideoFragmentHeader(frameNumber: 1, fragmentIndex: 0, fragmentCount: 1, presentationTimestamp: -1)
        let padded = Data([0xFF, 0xFF]) + header.serialized()
        XCTAssertEqual(VideoFragmentHeader.parse(from: padded[2...]), header)
        XCTAssertNil(VideoFragmentHeader.parse(from: padded[2..<10]))
    }

    func testFragmentingSplitsAndReassembles() {
        let bitstream = Data((0..<3_001).map { UInt8($0 % 251) })
        let payloads = VideoFragmentHeader.fragment(bitstream, frameNumber: 42, presentationTimestamp: 7, maximumPayloadLength: 1400)

        XCTAssertEqual(payloads.count, 3)
        XCTAssertTrue(payloads.allSatisfy { $0.count <= 1400 })

        var reassembled = Data()
        for (index, payload) in payloads.enumerated() {
            let header = VideoFragmentHeader.parse(from: payload)!
            XCTAssertEqual(header.frameNumber, 42)
            XCTAssertEqual(header.fragmentIndex, UInt16(index))
            XCTAssertEqual(header.fragmentCount, 3)
            XCTAssertEqual(header.presentationTimestamp, 7)
            reassembled.append(payload.dropFirst(VideoFragmentHeader.size))
        }
        XCTAssertEqual(reassembled, bitstream)

        let tiny = VideoFragmentHeader.fragment(Data([1]), frameNumber: 0, presentationTimestamp: 0, maximumPayloadLength: 1400)
        XCTAssertEqual(tiny.count, 1)
        XCTAssertEqual(VideoFragmentHeader.parse(from: tiny[0])?.fragmentCount, 1)
    }

    // MARK: Audio chunks

    func testAudioChunkHeaderBytesArePinned() {
        let header = AudioChunkHeader(sequenceNumber: 0x0102_0304, presentationTimestamp: 0x0506_0708_090A_0B0C)
        XCTAssertEqual(header.serialized(), Data([
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C,
        ]))
        XCTAssertEqual(AudioChunkHeader.parse(from: (Data([0]) + header.serialized())[1...]), header)
        XCTAssertNil(AudioChunkHeader.parse(from: header.serialized().prefix(11)))
    }

    // MARK: Codecs

    func testCodecIdsAndNamesArePinned() {
        XCTAssertEqual(AudioCodecID.pcmFloat32.rawValue, 0)
        XCTAssertEqual(AudioCodecID.aacLC.rawValue, 1)
        XCTAssertEqual(AudioCodecID.pcmFloat32.wireName, "pcm_f32le")
        XCTAssertEqual(AudioCodecID.aacLC.wireName, "aac_lc")
        XCTAssertEqual(VideoCodecID.h264.rawValue, 0)
        XCTAssertEqual(VideoCodecID.hevc.rawValue, 1)
        XCTAssertEqual(VideoCodecID.h264.wireName, "h264")
        XCTAssertEqual(VideoCodecID.hevc.wireName, "hevc")
    }

    func testZeroFlagsMeanTheLegacyCodecs() {
        XCTAssertEqual(AudioCodecID(packetFlags: 0), .pcmFloat32)
        XCTAssertEqual(VideoCodecID(packetFlags: 0), .h264)
    }

    func testReservedHighNibbleIsIgnored() {
        XCTAssertEqual(AudioCodecID(packetFlags: 0xF1), .aacLC)
        XCTAssertEqual(VideoCodecID(packetFlags: 0xA0), .h264)
    }

    func testUnknownCodecIdsAreNeverMisreadAsTheLegacyCodec() {
        XCTAssertNil(AudioCodecID(packetFlags: 0x02))
        XCTAssertNil(AudioCodecID(packetFlags: 0x0F))
        XCTAssertNil(VideoCodecID(packetFlags: 0x02))
        XCTAssertNil(VideoCodecID(packetFlags: 0x0F))
    }

    func testWireNamesRoundTripAndUnknownNamesAreNil() {
        for codec in AudioCodecID.allCases { XCTAssertEqual(AudioCodecID(wireName: codec.wireName), codec) }
        for codec in VideoCodecID.allCases { XCTAssertEqual(VideoCodecID(wireName: codec.wireName), codec) }
        XCTAssertNil(AudioCodecID(wireName: "opus"))
        XCTAssertNil(VideoCodecID(wireName: "av1"))
    }

    // MARK: Quality presets

    func testQualityPresetNamesArePinned() {
        XCTAssertEqual(QualityPreset.allCases.map(\.rawValue), [
            "auto", "360p30", "480p30", "720p30", "720p60", "1080p30", "1080p60",
            "1440p30", "1440p60", "2160p30", "2160p60", "native30", "native60",
        ])
        XCTAssertEqual(QualityPreset.p720_60.width, 1280)
        XCTAssertEqual(QualityPreset.p720_60.height, 720)
        XCTAssertEqual(QualityPreset.p720_60.frameRate, 60)
    }

    // MARK: Controller reports

    func testControllerReportBytesArePinned() {
        let report = ControllerReport(
            buttons: [.a, .home], leftX: 0x0102, leftY: -2, rightX: 0x7FFF, rightY: Int16.min,
            leftTrigger: 0xAB, rightTrigger: 0xCD
        )
        XCTAssertEqual(report.serialized(), Data([
            0x00, 0x00, 0x40, 0x01,  // buttons: bit 0 and bit 14
            0x01, 0x02, 0xFF, 0xFE,  // leftX, leftY
            0x7F, 0xFF, 0x80, 0x00,  // rightX, rightY
            0xAB, 0xCD,
        ]))
        XCTAssertEqual(ControllerReport.parse(from: report.serialized()), report)
        XCTAssertEqual(ControllerReport.parse(from: (Data([0]) + report.serialized())[1...]), report)
        XCTAssertEqual(ControllerReport.neutral.serialized(), Data(repeating: 0, count: 14))
    }
}
