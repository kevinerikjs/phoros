import CoreMedia
import Foundation
import Phoros
import VideoToolbox

/// Settings for one `VideoEncoder` session.
public struct VideoEncoderConfiguration: Equatable, Sendable {
    public var width: Int32
    public var height: Int32
    public var frameRate: Double
    public var bitrateBitsPerSecond: Int
    /// The codec to try. If the hardware cannot encode HEVC the session falls
    /// back to H.264 and reports that through `onParameterSets`.
    public var codec: VideoCodecID
    /// Seconds between forced keyframes. Two keeps a joining or recovering
    /// client waiting at most that long for a picture.
    public var keyframeInterval: Double

    /// Latency-related encoder settings. The defaults are what measured best
    /// on the latency harness; see docs/media.md.
    public var latency: LatencyTuning

    public init(
        width: Int32,
        height: Int32,
        frameRate: Double = 30,
        bitrateBitsPerSecond: Int = 6_000_000,
        codec: VideoCodecID = .h264,
        keyframeInterval: Double = 2,
        latency: LatencyTuning = LatencyTuning()
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.bitrateBitsPerSecond = bitrateBitsPerSecond
        self.codec = codec
        self.keyframeInterval = keyframeInterval
        self.latency = latency
    }

    public struct LatencyTuning: Equatable, Sendable {
        /// `kVTCompressionPropertyKey_MaxFrameDelayCount`. 0 asks the encoder
        /// to emit each frame before accepting the next. `nil` leaves the
        /// encoder's default.
        public var maxFrameDelayCount: Int?
        /// `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality`.
        public var prioritizeSpeed: Bool
        /// `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`: the
        /// hardware's low-latency rate-control mode. Falls back to a normal
        /// session when the encoder refuses it.
        public var lowLatencyRateControl: Bool
        /// H.264 profile. `.high` keeps the shipped quality; `.baseline` and
        /// `.main` are cheaper to encode and decode.
        public var h264Profile: H264Profile
        /// Peak-rate window: `DataRateLimits` at `burstMultiplier` times the
        /// average over one second. `nil` disables the limit.
        public var burstMultiplier: Double?

        public enum H264Profile: Equatable, Sendable { case baseline, main, high }

        public init(
            maxFrameDelayCount: Int? = nil,
            prioritizeSpeed: Bool = false,
            lowLatencyRateControl: Bool = false,
            h264Profile: H264Profile = .high,
            burstMultiplier: Double? = 2
        ) {
            self.maxFrameDelayCount = maxFrameDelayCount
            self.prioritizeSpeed = prioritizeSpeed
            self.lowLatencyRateControl = lowLatencyRateControl
            self.h264Profile = h264Profile
            self.burstMultiplier = burstMultiplier
        }
    }
}

public enum VideoEncoderError: Error, Sendable {
    case sessionCreationFailed(OSStatus)
}

/// A hardware H.264 or HEVC encoder that produces exactly what a Phoros
/// `.video` / `.videoKeyframe` / `.parameterSets` packet carries.
///
/// Settings that took production time to get right and are baked in:
/// real-time mode, no frame reordering (B-frames add a frame of latency and
/// break the "keyframe or not" packet split), High/Main profile with automatic
/// level, a burst limit of twice the target bitrate, and a bounded keyframe
/// interval.
///
/// ```swift
/// let encoder = VideoEncoder(configuration: config)
/// encoder.onParameterSets = { annexB, codec in send(.parameterSets, flags: codec.packetFlags, annexB) }
/// encoder.onFrame = { annexB, pts, isKeyframe in send(isKeyframe ? .videoKeyframe : .video, …) }
/// try encoder.start()
/// encoder.encode(sampleBuffer)      // from ScreenCaptureKit, the camera, anywhere
/// ```
///
/// Callbacks arrive on the encoder's own queue.
public final class VideoEncoder: @unchecked Sendable {
    /// Parameter sets for the session that just started, and the codec it
    /// actually uses. Emitted once per session, before the first frame, and
    /// again after every `reconfigure`.
    public var onParameterSets: ((_ annexB: Data, _ codec: VideoCodecID) -> Void)?
    /// One encoded frame in Annex B.
    public var onFrame: ((_ annexB: Data, _ presentationTime: CMTime, _ isKeyframe: Bool) -> Void)?
    /// Encoding errors that did not stop the session.
    public var onError: ((OSStatus) -> Void)?

    public private(set) var configuration: VideoEncoderConfiguration
    private var session: VTCompressionSession?
    private var parameterSetsSent = false
    private var forceKeyframe = false
    private let queue = DispatchQueue(label: "phoros.video-encoder", qos: .userInteractive)

    public init(configuration: VideoEncoderConfiguration) {
        self.configuration = configuration
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// Whether this machine has a hardware HEVC encoder. Probed once.
    public static let isHEVCSupported: Bool = {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: 640, height: 360, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: hardwareOnlySpecification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr && session != nil
    }()

    /// Hardware encoding only. Software H.264 cannot keep up with a live screen and would
    /// mask a missing encoder as a slow one. On iOS before 17.4 the keys do not exist, and
    /// every iOS device has hardware encoders, so no specification is needed there.
    private static var hardwareOnlySpecification: CFDictionary? {
        #if os(macOS)
        return [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ] as CFDictionary
        #else
        if #available(iOS 17.4, tvOS 17.4, visionOS 1.1, *) {
            return [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
            ] as CFDictionary
        }
        return nil
        #endif
    }

    /// The codec the running session uses. Differs from the configured one
    /// after an HEVC fallback.
    public var activeCodec: VideoCodecID { queue.sync { configuration.codec } }

    public func start() throws {
        try queue.sync { try startSession() }
    }

    public func stop() {
        queue.sync {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            parameterSetsSent = false
            forceKeyframe = false
        }
    }

    /// Restarts with new settings. Parameter sets are emitted again and the
    /// next frame is a keyframe. Failures are reported through `onError`; a
    /// session that fails to restart leaves the pipeline with no encoder, so
    /// callers should watch for it.
    public func reconfigure(_ change: @escaping (inout VideoEncoderConfiguration) -> Void) {
        queue.async { [self] in
            var next = configuration
            change(&next)
            guard next != configuration || session == nil else { return }
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            configuration = next
            do { try startSession() } catch VideoEncoderError.sessionCreationFailed(let status) {
                onError?(status)
            } catch {}
        }
    }

    /// Make the next frame a keyframe. Safe from any thread.
    public func requestKeyframe() {
        queue.async { [self] in forceKeyframe = true }
    }

    /// Encodes one captured frame. Frames arriving before `start` are dropped.
    public func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        queue.async { [self] in
            guard let session else { return }
            var properties: CFDictionary?
            if forceKeyframe {
                forceKeyframe = false
                properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            }
            let status = VTCompressionSessionEncodeFrame(
                session, imageBuffer: imageBuffer, presentationTimeStamp: pts, duration: .invalid,
                frameProperties: properties, sourceFrameRefcon: nil, infoFlagsOut: nil
            )
            if status != noErr { onError?(status) }
        }
    }

    // MARK: Session

    private func startSession() throws {
        guard session == nil else { return }
        parameterSetsSent = false
        forceKeyframe = false

        var spec = VideoEncoder.hardwareOnlySpecification
        if configuration.latency.lowLatencyRateControl {
            var dict = (spec as? [String: Any]) ?? [:]
            dict[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
            spec = dict as CFDictionary
        }

        var created: VTCompressionSession?
        var status = create(codec: configuration.codec, spec: spec, into: &created)
        if (status != noErr || created == nil), configuration.latency.lowLatencyRateControl {
            // The hardware refused low-latency rate control; run a normal session.
            spec = VideoEncoder.hardwareOnlySpecification
            status = create(codec: configuration.codec, spec: spec, into: &created)
        }
        if (status != noErr || created == nil), configuration.codec == .hevc {
            // No HEVC encoder here. H.264 is always available; report what actually runs.
            configuration.codec = .h264
            status = create(codec: .h264, spec: spec, into: &created)
        }
        guard status == noErr, let session = created else {
            throw VideoEncoderError.sessionCreationFailed(status)
        }

        let c = configuration
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        let h264Profile: CFString
        switch c.latency.h264Profile {
        case .baseline: h264Profile = kVTProfileLevel_H264_Baseline_AutoLevel
        case .main: h264Profile = kVTProfileLevel_H264_Main_AutoLevel
        case .high: h264Profile = kVTProfileLevel_H264_High_AutoLevel
        }
        VTSessionSetProperty(
            session, key: kVTCompressionPropertyKey_ProfileLevel,
            value: c.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : h264Profile
        )
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: c.bitrateBitsPerSecond))
        if let burst = c.latency.burstMultiplier {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [Int(Double(c.bitrateBitsPerSecond) * burst), 1] as CFArray)
        }
        if let delay = c.latency.maxFrameDelayCount {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: delay))
        }
        if c.latency.prioritizeSpeed {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: c.frameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: Int(c.frameRate * c.keyframeInterval)))
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    private func create(codec: VideoCodecID, spec: CFDictionary?, into session: inout VTCompressionSession?) -> OSStatus {
        VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: configuration.width, height: configuration.height,
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: phorosCompressionOutput,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
    }

    fileprivate func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sampleBuffer, sampleBuffer.isValid else {
            if status != noErr { onError?(status) }
            return
        }

        var isKeyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
           CFArrayGetCount(attachments) > 0,
           let dict = CFArrayGetValueAtIndex(attachments, 0).map({ Unmanaged<CFDictionary>.fromOpaque($0).takeUnretainedValue() }),
           let notSync = (dict as NSDictionary)[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        }

        if isKeyframe, !parameterSetsSent,
           let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let sets = VideoFormat.parameterSets(from: description, codec: configuration.codec) {
            parameterSetsSent = true
            onParameterSets?(sets, configuration.codec)
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer else { return }
        let annexB = AnnexB.fromLengthPrefixed(Data(bytes: pointer, count: length))
        guard !annexB.isEmpty else { return }
        onFrame?(annexB, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), isKeyframe)
    }
}

private func phorosCompressionOutput(
    refcon: UnsafeMutableRawPointer?,
    sourceFrameRefcon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refcon else { return }
    Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue().handleOutput(status: status, sampleBuffer: sampleBuffer)
}
