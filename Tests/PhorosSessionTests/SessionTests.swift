import XCTest
import Phoros
import PhorosSession

final class FrameAssemblerTests: XCTestCase {
    private func payload(frame: UInt32, index: UInt16, count: UInt16, bytes: [UInt8]) -> Data {
        VideoFragmentHeader(frameNumber: frame, fragmentIndex: index, fragmentCount: count, presentationTimestamp: 7).serialized() + Data(bytes)
    }

    func testSingleFragmentFrameIsReturnedImmediately() {
        var assembler = FrameAssembler()
        let frame = assembler.receive(payload(frame: 1, index: 0, count: 1, bytes: [9, 9]), isKeyframe: true)
        XCTAssertEqual(frame, AssembledFrame(frameNumber: 1, presentationTimestamp: 7, isKeyframe: true, bitstream: Data([9, 9])))
    }

    func testFragmentsAssembleInOrderRegardlessOfArrival() {
        var assembler = FrameAssembler()
        XCTAssertNil(assembler.receive(payload(frame: 5, index: 2, count: 3, bytes: [3]), isKeyframe: false))
        XCTAssertNil(assembler.receive(payload(frame: 5, index: 0, count: 3, bytes: [1]), isKeyframe: false))
        let frame = assembler.receive(payload(frame: 5, index: 1, count: 3, bytes: [2]), isKeyframe: false)
        XCTAssertEqual(frame?.bitstream, Data([1, 2, 3]))
        XCTAssertEqual(assembler.pendingFrameCount, 0)
    }

    func testAbandonedFramesAreDroppedOnceStale() {
        var assembler = FrameAssembler(staleDepth: 2)
        XCTAssertNil(assembler.receive(payload(frame: 1, index: 0, count: 2, bytes: [1]), isKeyframe: false))
        XCTAssertEqual(assembler.pendingFrameCount, 1)
        _ = assembler.receive(payload(frame: 2, index: 0, count: 1, bytes: [0]), isKeyframe: false)
        XCTAssertEqual(assembler.pendingFrameCount, 1)
        _ = assembler.receive(payload(frame: 4, index: 0, count: 1, bytes: [0]), isKeyframe: false)
        XCTAssertEqual(assembler.pendingFrameCount, 0)
    }

    func testMalformedPayloadsAreIgnored() {
        var assembler = FrameAssembler()
        XCTAssertNil(assembler.receive(Data([1, 2, 3]), isKeyframe: false))
        XCTAssertNil(assembler.receive(payload(frame: 1, index: 5, count: 2, bytes: [1]), isKeyframe: false))
        XCTAssertNil(assembler.receive(payload(frame: 1, index: 0, count: 0, bytes: [1]), isKeyframe: false))
        XCTAssertEqual(assembler.pendingFrameCount, 0)
    }

    func testFragmentHelperAndAssemblerRoundTrip() {
        let bitstream = Data((0..<5000).map { UInt8($0 % 251) })
        var assembler = FrameAssembler()
        var result: AssembledFrame?
        for payload in VideoFragmentHeader.fragment(bitstream, frameNumber: 9, presentationTimestamp: 1, maximumPayloadLength: 1400) {
            result = assembler.receive(payload, isKeyframe: true) ?? result
        }
        XCTAssertEqual(result?.bitstream, bitstream)
        XCTAssertEqual(result?.frameNumber, 9)
    }
}

final class AudioSequenceGuardTests: XCTestCase {
    func testForwardSequencesAreAccepted() {
        var guardian = AudioSequenceGuard()
        XCTAssertEqual(guardian.accept(10), .accept)
        XCTAssertEqual(guardian.accept(11), .accept)
        XCTAssertEqual(guardian.accept(300), .accept)
        XCTAssertEqual(guardian.lastAccepted, 300)
    }

    func testSmallStepBackIsADuplicateAndDoesNotMoveTheAnchor() {
        var guardian = AudioSequenceGuard()
        _ = guardian.accept(100)
        XCTAssertEqual(guardian.accept(100), .duplicate)
        XCTAssertEqual(guardian.accept(99), .duplicate)
        XCTAssertEqual(guardian.lastAccepted, 100)
        XCTAssertEqual(guardian.accept(101), .accept)
    }

    func testLargeStepBackIsARestartAndReanchors() {
        var guardian = AudioSequenceGuard()
        _ = guardian.accept(5000)
        XCTAssertEqual(guardian.accept(0), .restarted)
        XCTAssertEqual(guardian.lastAccepted, 0)
        XCTAssertEqual(guardian.accept(1), .accept)
    }

    func testWrapAroundCountsAsForward() {
        var guardian = AudioSequenceGuard()
        _ = guardian.accept(UInt32.max)
        XCTAssertEqual(guardian.accept(0), .accept)
    }
}

final class SendSchedulerTests: XCTestCase {
    func testControlThenAudioThenVideo() {
        var scheduler = SendScheduler()
        scheduler.enqueue(Data([3]), lane: .video)
        scheduler.enqueue(Data([2]), lane: .audio)
        scheduler.enqueue(Data([1]), lane: .control)
        XCTAssertEqual(scheduler.dequeue()?.lane, .control)
        XCTAssertEqual(scheduler.dequeue()?.lane, .audio)
        XCTAssertEqual(scheduler.dequeue()?.lane, .video)
        XCTAssertNil(scheduler.dequeue())
    }

    func testConcurrentWriteWindowIsRespected() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumConcurrentWrites: 2))
        for _ in 0..<3 { scheduler.enqueue(Data([0]), lane: .video) }
        let a = scheduler.dequeue()!, b = scheduler.dequeue()!
        XCTAssertNil(scheduler.dequeue())
        scheduler.completed(a)
        XCTAssertNotNil(scheduler.dequeue())
        scheduler.completed(b)
    }

    func testVideoIsDroppedAboveTheBacklogButKeyframesNever() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 10))
        scheduler.enqueue(Data(count: 20), lane: .video)
        let write = scheduler.dequeue()!
        XCTAssertFalse(scheduler.admitVideo(isKeyframe: false))
        XCTAssertTrue(scheduler.admitVideo(isKeyframe: true))
        XCTAssertEqual(scheduler.droppedVideoFrames, 1)
        scheduler.completed(write)
        XCTAssertFalse(scheduler.admitVideo(isKeyframe: false), "a keyframe is owed first")
        scheduler.enqueueVideoFrame([Data(count: 1)], isKeyframe: true)
        XCTAssertTrue(scheduler.admitVideo(isKeyframe: false))
    }

    func testAudioIsShedOnlyBrieflyAndOnlyOnItsOwnBacklog() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 10, maximumQueuedAudioBytes: 10, maximumAudioSilence: 1))
        let t0 = Date(timeIntervalSince1970: 1000)
        // Video backlog alone must not shed audio.
        scheduler.enqueue(Data(count: 100), lane: .video)
        let video = scheduler.dequeue()!
        XCTAssertTrue(scheduler.admitAudio(now: t0))
        // Audio backlog does, for at most the silence window.
        scheduler.enqueue(Data(count: 100), lane: .audio)
        let audio = scheduler.dequeue()!
        XCTAssertFalse(scheduler.admitAudio(now: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(scheduler.admitAudio(now: t0.addingTimeInterval(1.5)))
        scheduler.completed(video)
        scheduler.completed(audio)
        XCTAssertEqual(scheduler.backlog.total, 0)
    }

    func testCountersReanchorWhenNothingIsInFlight() {
        var scheduler = SendScheduler()
        scheduler.enqueue(Data(count: 50), lane: .audio)
        let write = scheduler.dequeue()!
        // Simulate a lost accounting increment by completing a heavier write.
        scheduler.completed(SendScheduler.Write(data: Data(count: 10), lane: .audio))
        XCTAssertEqual(scheduler.backlog.total, 0)
        XCTAssertEqual(scheduler.backlog.audio, 0)
        _ = write
    }

    func testDropQueuedVideoKeepsAudio() {
        var scheduler = SendScheduler()
        scheduler.enqueue(Data([1]), lane: .video)
        scheduler.enqueue(Data([2]), lane: .audio)
        scheduler.dropQueuedVideo()
        XCTAssertEqual(scheduler.queuedCount, 1)
        XCTAssertEqual(scheduler.dequeue()?.lane, .audio)
    }
}

final class SendSchedulerQueueAgeTests: XCTestCase {
    func testQueuedVideoCountsTowardAdmission() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 10_000))
        scheduler.enqueueVideoFrame([Data(count: 6_000)], isKeyframe: false)
        scheduler.enqueueVideoFrame([Data(count: 6_000)], isKeyframe: false)
        XCTAssertEqual(scheduler.queuedVideo.bytes, 12_000)
        XCTAssertFalse(scheduler.admitVideo(isKeyframe: false), "queued bytes alone exceed the budget")
        XCTAssertTrue(scheduler.needsKeyframe)
        XCTAssertTrue(scheduler.admitVideo(isKeyframe: true), "keyframes are always admitted")
    }

    func testStaleDeltaFramesAreShedAndKeyframesKept() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumVideoQueueAge: 0.1))
        let t0 = Date()
        scheduler.enqueueVideoFrame([Data([1])], isKeyframe: true, now: t0)
        scheduler.enqueueVideoFrame([Data([2])], isKeyframe: false, now: t0)
        scheduler.enqueueVideoFrame([Data([3]), Data([4])], isKeyframe: false, now: t0.addingTimeInterval(0.15))
        XCTAssertEqual(scheduler.dequeue(now: t0.addingTimeInterval(0.2))?.data, Data([1]), "the old keyframe still goes")
        XCTAssertEqual(scheduler.dequeue(now: t0.addingTimeInterval(0.2))?.data, Data([3, 4]), "the stale delta was shed, the fresh one goes as one write")
        XCTAssertEqual(scheduler.droppedVideoFrames, 1)
        XCTAssertTrue(scheduler.needsKeyframe)
        scheduler.enqueueVideoFrame([Data([5])], isKeyframe: true)
        XCTAssertFalse(scheduler.needsKeyframe, "a queued keyframe clears the request")
    }

    func testWholeFrameIsOneWrite() {
        var scheduler = SendScheduler()
        scheduler.enqueueVideoFrame([Data([1, 2]), Data([3])], isKeyframe: false)
        let write = scheduler.dequeue()
        XCTAssertEqual(write?.data, Data([1, 2, 3]))
        XCTAssertEqual(scheduler.queuedVideo.bytes, 0)
        XCTAssertEqual(scheduler.backlog.total, 3)
        scheduler.completed(write!)
        XCTAssertEqual(scheduler.backlog.total, 0)
    }
}

final class SendSchedulerGateTests: XCTestCase {
    func testCaptureGateRefusesWhileBacklogged() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 10_000))
        XCTAssertTrue(scheduler.shouldEncodeVideo())
        scheduler.enqueueVideoFrame([Data(count: 12_000)], isKeyframe: false)
        XCTAssertFalse(scheduler.admitCapture(), "the transport is behind: skip before encoding")
        XCTAssertEqual(scheduler.skippedCaptureFrames, 1)
        XCTAssertFalse(scheduler.needsKeyframe, "a skipped capture breaks no reference chain")
        let write = scheduler.dequeue()!
        scheduler.completed(write)
        XCTAssertTrue(scheduler.admitCapture())
    }

    func testDeltasAreRefusedUntilTheKeyframeArrives() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 10))
        scheduler.enqueueVideoFrame([Data(count: 20)], isKeyframe: false)
        XCTAssertFalse(scheduler.admitVideo(isKeyframe: false))
        XCTAssertTrue(scheduler.needsKeyframe)
        let write = scheduler.dequeue()!
        scheduler.completed(write)
        XCTAssertFalse(scheduler.admitVideo(isKeyframe: false), "the peer cannot decode a delta until the keyframe")
        XCTAssertTrue(scheduler.admitVideo(isKeyframe: true))
        scheduler.enqueueVideoFrame([Data(count: 1)], isKeyframe: true)
        XCTAssertTrue(scheduler.admitVideo(isKeyframe: false))
    }

    func testDrainRateShrinksTheByteBudget() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 192 * 1024, maximumQueueDelay: 0.03, minimumQueuedBytes: 1_000))
        XCTAssertEqual(scheduler.videoByteBudget, 192 * 1024, "unknown link: the byte cap applies")
        let t0 = Date()
        // 40 KB takes 40 ms to complete: a 1 MB/s link.
        scheduler.enqueueVideoFrame([Data(count: 40_000)], isKeyframe: false, now: t0)
        let write = scheduler.dequeue(now: t0)!
        scheduler.completed(write, now: t0.addingTimeInterval(0.04))
        XCTAssertEqual(scheduler.drainRate, 1_000_000, accuracy: 1)
        XCTAssertEqual(scheduler.videoByteBudget, 30_000, "30 ms of a 1 MB/s link")
    }
}

final class SendSchedulerTransportBacklogTests: XCTestCase {
    func testTransportBacklogCountsTowardTheBudgetAndHoldsDeltas() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 10_000))
        scheduler.transportBacklog = 12_000
        XCTAssertFalse(scheduler.shouldEncodeVideo(), "the kernel already holds more than the budget")
        scheduler.enqueueVideoFrame([Data(count: 100)], isKeyframe: false)
        XCTAssertNil(scheduler.dequeue(), "a delta waits while the transport is full")
        XCTAssertEqual(scheduler.queuedVideo.frames, 1)
        scheduler.enqueueVideoFrame([Data(count: 100)], isKeyframe: true)
        scheduler.dropQueuedVideo()
        scheduler.enqueueVideoFrame([Data(count: 100)], isKeyframe: true)
        XCTAssertNotNil(scheduler.dequeue(), "a keyframe goes regardless")
        scheduler.transportBacklog = 0
        scheduler.enqueueVideoFrame([Data(count: 100)], isKeyframe: false)
        XCTAssertNotNil(scheduler.dequeue())
    }

    func testReportedDrainRateReplacesTheEstimate() {
        var scheduler = SendScheduler(policy: SendPolicy(maximumQueuedBytes: 192 * 1024, maximumQueueDelay: 0.03, minimumQueuedBytes: 1_000))
        scheduler.reportDrainRate(500_000)
        XCTAssertEqual(scheduler.videoByteBudget, 15_000)
        scheduler.reportDrainRate(0)
        XCTAssertEqual(scheduler.drainRate, 500_000, "zero is not a measurement")
    }
}

final class ClockSyncTests: XCTestCase {
    func testOffsetComesFromTheShortestRoundTrip() {
        var sync = ClockSync()
        XCTAssertNil(sync.offset)
        // Host clock runs 5 s ahead. First exchange: 2 ms each way.
        let p1 = sync.probe(now: 1_000_000)
        XCTAssertEqual(sync.reply(ClockReply(id: p1.id, sentAt: p1.sentAt, receivedAt: 6_002_000, repliedAt: 6_002_100), now: 1_004_100), 4_000)
        XCTAssertEqual(sync.offset, 5_000_000)
        // Second exchange: 40 ms queued on the way there. Worse sample, ignored for the offset.
        let p2 = sync.probe(now: 2_000_000)
        XCTAssertEqual(sync.reply(ClockReply(id: p2.id, sentAt: p2.sentAt, receivedAt: 7_042_000, repliedAt: 7_042_100), now: 2_044_100), 44_000)
        XCTAssertEqual(sync.offset, 5_000_000)
        XCTAssertEqual(sync.bestRoundTrip, 4_000)
        XCTAssertEqual(sync.lastRoundTrip, 44_000)
        XCTAssertEqual(sync.age(ofPresentationTimestamp: 7_000_000, now: 2_030_000), 30_000, "a frame captured 30 ms ago")
    }

    func testReplyToUnknownProbeIsIgnored() {
        var sync = ClockSync()
        XCTAssertNil(sync.reply(ClockReply(id: 99, sentAt: 1, receivedAt: 2, repliedAt: 3), now: 4))
        let p = sync.probe(now: 10)
        XCTAssertNil(sync.reply(ClockReply(id: p.id, sentAt: 11, receivedAt: 2, repliedAt: 3), now: 4), "sentAt must echo")
        XCTAssertNil(sync.offset)
    }
}

final class BitrateControllerTests: XCTestCase {
    func testQueueingDelayStepsDownAndClearLinkStepsUp() {
        var controller = BitrateController(maximum: 10_000_000, policy: BitrateControllerPolicy(initialBitrate: 0))
        let t0 = Date()
        controller.observe(roundTrip: 0.002, now: t0)
        XCTAssertNil(controller.evaluate(now: t0), "a floor sample alone changes nothing")
        controller.observe(roundTrip: 0.040, now: t0.addingTimeInterval(0.2))
        XCTAssertEqual(controller.queueDelay, 0.038, accuracy: 0.0001)
        XCTAssertNil(controller.evaluate(now: t0.addingTimeInterval(0.2)), "one sample is a spike")
        controller.observe(roundTrip: 0.040, now: t0.addingTimeInterval(0.4))
        XCTAssertEqual(controller.evaluate(now: t0.addingTimeInterval(0.4)), 7_000_000, "two are a queue")
        controller.observe(roundTrip: 0.040, now: t0.addingTimeInterval(0.5))
        XCTAssertNil(controller.evaluate(now: t0.addingTimeInterval(0.5)), "too soon for a second decrease")
        controller.observe(roundTrip: 0.030, now: t0.addingTimeInterval(0.8))
        XCTAssertNil(controller.evaluate(now: t0.addingTimeInterval(0.8)), "still queued but draining: the first cut is working")
        controller.observe(roundTrip: 0.040, now: t0.addingTimeInterval(1.1))
        XCTAssertEqual(controller.evaluate(now: t0.addingTimeInterval(1.1)), 4_900_000, "growing again: cut again")
        // The link clears. One increase after the clear interval, not before.
        for i in 0..<12 {
            controller.observe(roundTrip: 0.003, now: t0.addingTimeInterval(1.2 + Double(i) * 0.2))
            let result = controller.evaluate(now: t0.addingTimeInterval(1.2 + Double(i) * 0.2))
            if Double(i) * 0.2 < 2 { XCTAssertNil(result, "step \(i)") } else { XCTAssertEqual(result, 5_635_000); break }
        }
    }

    func testSlowStartClimbsFastUntilTheFirstCongestion() {
        var controller = BitrateController(maximum: 10_000_000)
        XCTAssertEqual(controller.current, 4_000_000, "a new link starts below the ceiling")
        let t0 = Date()
        controller.observe(roundTrip: 0.003, now: t0)
        controller.observe(roundTrip: 0.003, now: t0.addingTimeInterval(0.7))
        XCTAssertEqual(controller.evaluate(now: t0.addingTimeInterval(0.7)), 6_000_000, "slow start: 1.5x every 0.6 s")
        controller.observe(roundTrip: 0.200, now: t0.addingTimeInterval(0.9))
        XCTAssertNil(controller.evaluate(now: t0.addingTimeInterval(0.9)))
        controller.observe(roundTrip: 0.200, now: t0.addingTimeInterval(1.0))
        XCTAssertEqual(controller.evaluate(now: t0.addingTimeInterval(1.0)), 3_000_000, "a severe queue halves the rate")
        controller.observe(roundTrip: 0.003, now: t0.addingTimeInterval(1.2))
        controller.observe(roundTrip: 0.003, now: t0.addingTimeInterval(2.0))
        XCTAssertNil(controller.evaluate(now: t0.addingTimeInterval(2.0)), "after congestion the climb is the slow one")
    }

    func testNeverBelowMinimumOrAboveMaximum() {
        var controller = BitrateController(maximum: 2_000_000, policy: BitrateControllerPolicy(minimumBitrate: 1_500_000))
        let t0 = Date()
        controller.observe(roundTrip: 0.001, now: t0)
        controller.observe(roundTrip: 0.100, now: t0.addingTimeInterval(0.2))
        controller.observe(roundTrip: 0.100, now: t0.addingTimeInterval(0.4))
        XCTAssertEqual(controller.evaluate(now: t0.addingTimeInterval(0.4)), 1_500_000)
        controller.observe(roundTrip: 0.100, now: t0.addingTimeInterval(0.6))
        XCTAssertNil(controller.evaluate(now: t0.addingTimeInterval(0.6)), "already at the floor")
        controller.setMaximum(1_200_000)
        XCTAssertEqual(controller.current, 1_200_000, "the ceiling pulls the rate down with it")
    }
}

final class PairingTests: XCTestCase {
    let client = ClientCapabilities(deviceName: "iPhone", deviceID: "dev-1", preferredAudioSampleRate: 48_000)
    let host = HostCapabilities(deviceName: "Mac", remoteHosts: ["100.64.0.1"], supportsRemoteAccess: true, supportsVideoHold: true, supportsAudioToggle: true, supportsWindowSelection: true, supportsControllerInput: true)

    func testFullPairingFlow() throws {
        var pairing = PairingHost(capabilities: host)
        let hello = client.hello()
        XCTAssertEqual(hello.supportedAudioCodecs, ["aac_lc", "pcm_f32le"])

        let (challenge, code) = pairing.begin(hello: hello, code: "123456")!
        XCTAssertEqual(challenge.type, .challenge)
        XCTAssertNil(challenge.code, "the code never crosses the wire")
        XCTAssertEqual(PairingClient.interpret(challenge), .codeRequested(hostName: "Mac"))

        guard case .rejected(let failure) = pairing.verify(client.codeVerify("000000")) else { return XCTFail() }
        XCTAssertEqual(PairingClient.interpret(failure), .failed(reason: "Incorrect code"))
        XCTAssertTrue(pairing.isActive, "a wrong code does not end the attempt")

        let secret = SharedSecret.generate()
        guard case .paired(let issued, let success) = pairing.verify(client.codeVerify(code), secret: secret) else { return XCTFail() }
        XCTAssertEqual(issued, secret)
        XCTAssertEqual(pairing.peerDeviceID, "dev-1")
        XCTAssertFalse(pairing.isActive)

        guard case .paired(let stored, let peer, let name) = PairingClient.interpret(success) else { return XCTFail() }
        XCTAssertEqual(stored, secret)
        XCTAssertEqual(name, "Mac")
        XCTAssertTrue(peer.supportsRemoteAccess)
        XCTAssertTrue(peer.supportsControllerInput)
        XCTAssertEqual(peer.remoteHosts, ["100.64.0.1"])
    }

    func testExpiredAttemptIgnoresTheCode() {
        var pairing = PairingHost(capabilities: host)
        let t0 = Date()
        let (_, code) = pairing.begin(hello: client.hello(), validFor: 60, now: t0)!
        XCTAssertEqual(pairing.verify(client.codeVerify(code), now: t0.addingTimeInterval(61)), .ignored)
        XCTAssertFalse(pairing.isActive)
    }

    func testAuthenticationNegotiatesAndRejects() {
        let secret = SharedSecret.generate()
        let lookup: (String) -> SharedSecret? = { $0 == "dev-1" ? secret : nil }

        guard case .authenticated(let session) = HostAuthenticator.authenticate(client.authRequest(secret: secret), storedSecret: lookup, capabilities: host) else { return XCTFail() }
        XCTAssertEqual(session.audioCodec, .aacLC)
        XCTAssertEqual(session.videoCodec, .hevc)
        XCTAssertEqual(session.peer.preferredAudioSampleRate, 48_000)
        XCTAssertEqual(session.reply.type, .authSuccess)
        XCTAssertEqual(session.reply.selectedAudioCodec, "aac_lc")
        XCTAssertEqual(session.reply.supportsVideoHold, true)

        guard case .authenticated(let forcedPCM) = HostAuthenticator.authenticate(client.authRequest(secret: secret), storedSecret: lookup, capabilities: host, audioPreferences: [.pcmFloat32]) else { return XCTFail() }
        XCTAssertEqual(forcedPCM.audioCodec, .pcmFloat32)

        let wrong = SharedSecret.generate()
        guard case .rejected(let reply) = HostAuthenticator.authenticate(client.authRequest(secret: wrong), storedSecret: lookup, capabilities: host) else { return XCTFail() }
        XCTAssertEqual(reply.error, "Authentication failed")

        var unknown = client
        unknown.deviceID = "stranger"
        guard case .rejected(let unpaired) = HostAuthenticator.authenticate(unknown.authRequest(secret: secret), storedSecret: lookup, capabilities: host) else { return XCTFail() }
        XCTAssertEqual(unpaired.error, "Device not paired")

        guard case .rejected = HostAuthenticator.authenticate(PairingMessage(type: .authRequest, deviceID: "dev-1", sharedSecret: "zz"), storedSecret: lookup, capabilities: host) else { return XCTFail() }
    }

    func testLegacyClientAuthenticatesToLegacyCodecs() {
        let secret = SharedSecret.generate()
        let legacy = PairingMessage(type: .authRequest, deviceName: "Old iPhone", deviceID: "dev-1", sharedSecret: secret.hex)
        guard case .authenticated(let session) = HostAuthenticator.authenticate(legacy, storedSecret: { _ in secret }, capabilities: host) else { return XCTFail() }
        XCTAssertEqual(session.audioCodec, .pcmFloat32)
        XCTAssertEqual(session.videoCodec, .h264)
        XCTAssertTrue(session.peer.wantsAudio)
    }

    func testClientInterpretsAuthReplies() {
        let success = PairingMessage(type: .authSuccess, deviceName: "Mac", supportsVideoHold: true, selectedAudioCodec: "aac_lc", selectedVideoCodec: "hevc")
        guard case .authenticated(let peer, "Mac", .aacLC, .hevc) = PairingClient.interpret(success) else { return XCTFail() }
        XCTAssertTrue(peer.supportsVideoHold)
        XCTAssertEqual(PairingClient.interpret(PairingMessage(type: .unpaired)), .unpaired)
        XCTAssertEqual(PairingClient.interpret(PairingMessage(type: .hello)), .unexpected(.hello))
    }

    func testSharedSecretHexRoundTripAndConstantTimeCompare() {
        let secret = SharedSecret.generate()
        XCTAssertEqual(secret.hex.count, 64)
        XCTAssertEqual(SharedSecret(hex: secret.hex), secret)
        XCTAssertTrue(secret.matches(SharedSecret(hex: secret.hex)!))
        XCTAssertFalse(secret.matches(SharedSecret.generate()))
        XCTAssertNil(SharedSecret(hex: "abc"))
        XCTAssertNil(SharedSecret(hex: String(repeating: "zz", count: 32)))
        XCTAssertEqual(PairingCode.generate().count, 6)
    }
}

final class LinkHealthTests: XCTestCase {
    func testProbeAbandonsStaleProbes() {
        var probe = RoundTripProbe(staleAfter: 10)
        let t0 = Date()
        XCTAssertTrue(probe.shouldSend(now: t0))
        XCTAssertFalse(probe.shouldSend(now: t0.addingTimeInterval(5)))
        XCTAssertTrue(probe.shouldSend(now: t0.addingTimeInterval(11)), "a lost pong never stops probing")
        XCTAssertEqual(probe.receivedPong(now: t0.addingTimeInterval(11.25)), 0.25)
        XCTAssertNil(probe.receivedPong(now: t0.addingTimeInterval(12)))
    }

    func testHeartbeatMonitor() {
        let t0 = Date()
        var monitor = HeartbeatMonitor(timeout: 30, now: t0)
        XCTAssertFalse(monitor.isTimedOut(now: t0.addingTimeInterval(29)))
        XCTAssertTrue(monitor.isTimedOut(now: t0.addingTimeInterval(31)))
        monitor.heard(now: t0.addingTimeInterval(31))
        XCTAssertFalse(monitor.isTimedOut(now: t0.addingTimeInterval(40)))
    }

    func testVideoHoldResumeAlwaysRepairsTheDecoder() {
        var hold = VideoHold()
        hold.pause()
        XCTAssertTrue(hold.isHeld)
        XCTAssertEqual(hold.resume(), [.resendParameterSets, .requestKeyframe])
        XCTAssertFalse(hold.isHeld)
    }
}

final class QualityLadderTests: XCTestCase {
    let tiers: [QualityPreset] = [.p360_30, .p480_30, .p720_30, .p1080_30]

    func testStartsAtTheTopAndStepsDownAfterSustainedBadFeedback() {
        var ladder = QualityLadder(tiers: tiers)
        let t0 = Date()
        XCTAssertEqual(ladder.current, .p1080_30)
        ladder.feedback(0.2)
        XCTAssertNil(ladder.evaluate(now: t0))
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(2)))
        XCTAssertEqual(ladder.evaluate(now: t0.addingTimeInterval(3.5)), .p720_30)
        // Minimum interval prevents a second step right away; the low timer restarts.
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(5)))
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(7.9)))
        XCTAssertEqual(ladder.evaluate(now: t0.addingTimeInterval(9.6)), .p480_30)
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(12.6)))
    }

    func testStepsUpSlowlyAndNotPastTheTop() {
        var ladder = QualityLadder(tiers: tiers, startingAt: .p720_30)
        let t0 = Date()
        ladder.feedback(0.95)
        XCTAssertNil(ladder.evaluate(now: t0))
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(11)))
        XCTAssertEqual(ladder.evaluate(now: t0.addingTimeInterval(12.5)), .p1080_30)
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(100)))
    }

    func testMiddlingFeedbackResetsTimers() {
        var ladder = QualityLadder(tiers: tiers)
        let t0 = Date()
        ladder.feedback(0.2)
        XCTAssertNil(ladder.evaluate(now: t0))
        ladder.feedback(0.6)
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(2)))
        ladder.feedback(0.2)
        XCTAssertNil(ladder.evaluate(now: t0.addingTimeInterval(4)), "the low timer restarted")
    }

    func testManualSetMovesTheLadder() {
        var ladder = QualityLadder(tiers: tiers)
        ladder.set(.p360_30)
        XCTAssertEqual(ladder.current, .p360_30)
        XCTAssertEqual(ladder.index, 0)
    }
}
