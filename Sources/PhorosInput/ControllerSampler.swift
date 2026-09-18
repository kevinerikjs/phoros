import Foundation
import Phoros

/// Decides which sampled reports are worth sending. Sans-IO.
///
/// Send when the state changed, and otherwise once per `keepalive` so the
/// host can tell "nothing pressed" from "client went away", and so a report
/// lost to a reconnect is repaired within a second.
public struct ReportThrottle: Equatable, Sendable {
    public var keepalive: TimeInterval
    private var lastSent: ControllerReport?
    private var lastSentAt: Date = .distantPast

    public init(keepalive: TimeInterval = 1.0) {
        self.keepalive = keepalive
    }

    /// Returns `true` when `report` should go out now, and records it.
    public mutating func shouldSend(_ report: ControllerReport, now: Date) -> Bool {
        guard report != lastSent || now.timeIntervalSince(lastSentAt) >= keepalive else { return false }
        lastSent = report
        lastSentAt = now
        return true
    }

    /// Forget the last report so the next sample is sent whatever it is.
    public mutating func reset() {
        lastSent = nil
        lastSentAt = .distantPast
    }
}

#if canImport(GameController)
import GameController

extension ControllerReport {
    /// A snapshot of an extended gamepad in wire form.
    public init(_ pad: GCExtendedGamepad) {
        var buttons: Buttons = []
        if pad.buttonA.isPressed { buttons.insert(.a) }
        if pad.buttonB.isPressed { buttons.insert(.b) }
        if pad.buttonX.isPressed { buttons.insert(.x) }
        if pad.buttonY.isPressed { buttons.insert(.y) }
        if pad.leftShoulder.isPressed { buttons.insert(.leftShoulder) }
        if pad.rightShoulder.isPressed { buttons.insert(.rightShoulder) }
        if pad.leftThumbstickButton?.isPressed == true { buttons.insert(.leftThumbstick) }
        if pad.rightThumbstickButton?.isPressed == true { buttons.insert(.rightThumbstick) }
        if pad.dpad.up.isPressed { buttons.insert(.dpadUp) }
        if pad.dpad.down.isPressed { buttons.insert(.dpadDown) }
        if pad.dpad.left.isPressed { buttons.insert(.dpadLeft) }
        if pad.dpad.right.isPressed { buttons.insert(.dpadRight) }
        if pad.buttonMenu.isPressed { buttons.insert(.menu) }
        if pad.buttonOptions?.isPressed == true { buttons.insert(.options) }
        if pad.buttonHome?.isPressed == true { buttons.insert(.home) }

        self.init(
            buttons: buttons,
            leftX: ControllerReport.axis(pad.leftThumbstick.xAxis.value),
            leftY: ControllerReport.axis(pad.leftThumbstick.yAxis.value),
            rightX: ControllerReport.axis(pad.rightThumbstick.xAxis.value),
            rightY: ControllerReport.axis(pad.rightThumbstick.yAxis.value),
            leftTrigger: ControllerReport.trigger(pad.leftTrigger.value),
            rightTrigger: ControllerReport.trigger(pad.rightTrigger.value)
        )
    }

    /// GameController axis (-1...1) to wire axis (-32767...32767).
    public static func axis(_ value: Float) -> Int16 {
        Int16(clamping: Int(value * 32767))
    }

    /// GameController trigger (0...1) to wire trigger (0...255).
    public static func trigger(_ value: Float) -> UInt8 {
        UInt8(clamping: Int(value * 255))
    }
}

/// Watches for an extended gamepad and delivers `ControllerReport`s ready to
/// send as `.input` packets.
///
/// ```swift
/// let sampler = ControllerSampler()
/// sampler.onAttachmentChange = { attached in showGamepadBadge(attached) }
/// sampler.onReport = { report, connected in
///     send(Packet.encode(.input, flags: connected ? ControllerReport.connectedFlag : 0, payload: report.serialized()))
/// }
/// sampler.start()
/// ```
///
/// One controller is forwarded at a time: the first with an extended gamepad
/// profile. When it disconnects, one neutral report with `connected == false`
/// goes out so the host releases its virtual device.
///
/// Reports go out the moment the controller changes (GameController's value
/// handler), rate-limited to `sampleRate`, and once per keepalive interval
/// while nothing changes. Polling at 60 Hz instead cost 17 ms of latency at
/// the median on the harness, half a frame of a 60 Hz game.
///
/// GameController stops delivering input while an iOS app is in the
/// background, so reports only flow while the client is in the foreground.
/// `onReport` is called on the sampler's queue. `onAttachmentChange` is
/// called on the main queue.
public final class ControllerSampler: @unchecked Sendable {
    public var onReport: ((_ report: ControllerReport, _ connected: Bool) -> Void)?
    public var onAttachmentChange: ((_ attached: Bool) -> Void)?
    /// Which controllers to consider. Default: any with an extended gamepad
    /// profile. A host that also creates virtual controllers on the same
    /// machine uses this to avoid sampling its own output.
    public var accepts: ((GCController) -> Bool)?

    public let sampleRate: Double
    private var throttle: ReportThrottle
    private var controller: GCController?
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var lastSendNanos: UInt64 = 0
    private var pendingSend = false
    private let queue = DispatchQueue(label: "phoros.controller-sampler", qos: .userInteractive)
    private static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    private static func nanos() -> UInt64 { mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom) }

    public init(sampleRate: Double = 60, keepalive: TimeInterval = 1.0) {
        self.sampleRate = sampleRate
        self.throttle = ReportThrottle(keepalive: keepalive)
    }

    deinit { stop() }

    /// Whether a physical controller is attached and being forwarded.
    public var isAttached: Bool { controller != nil }

    /// Start watching. Attaches to a controller that is already connected.
    public func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                self?.attach(controller)
            },
            center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
                guard let self, let controller = note.object as? GCController, controller === self.controller else { return }
                self.detach()
            },
        ]
        if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil && (accepts?($0) ?? true) }) {
            attach(controller)
        }
    }

    /// Stop watching. Sends nothing; call before the connection closes.
    public func stop() {
        stopTimer()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if controller != nil {
            controller = nil
            onAttachmentChange?(false)
        }
        throttle.reset()
    }

    private func attach(_ candidate: GCController) {
        guard let pad = candidate.extendedGamepad, controller == nil, accepts?(candidate) ?? true else { return }
        controller = candidate
        throttle.reset()
        onAttachmentChange?(true)
        candidate.handlerQueue = queue
        pad.valueChangedHandler = { [weak self] pad, _ in self?.changed(pad) }
        startTimer()
    }

    /// Something moved. Send now unless a report went out less than one
    /// sample interval ago; then send once at the end of that interval so a
    /// burst of analog jitter becomes one report and the last state never
    /// waits for the keepalive.
    private func changed(_ pad: GCExtendedGamepad) {
        let now = Self.nanos()
        let minGap = UInt64(1_000_000_000 / sampleRate)
        if now &- lastSendNanos >= minGap {
            emit(pad, now: now)
        } else if !pendingSend {
            pendingSend = true
            let wait = minGap - (now &- lastSendNanos)
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(wait))) { [weak self] in
                guard let self else { return }
                pendingSend = false
                if let pad = controller?.extendedGamepad { emit(pad, now: Self.nanos()) }
            }
        }
    }

    private func emit(_ pad: GCExtendedGamepad, now: UInt64) {
        let report = ControllerReport(pad)
        guard throttle.shouldSend(report, now: Date()) else { return }
        lastSendNanos = now
        onReport?(report, true)
    }

    private func detach() {
        stopTimer()
        controller?.extendedGamepad?.valueChangedHandler = nil
        controller = nil
        onAttachmentChange?(false)
        throttle.reset()
        onReport?(.neutral, false)
    }

    private func startTimer() {
        stopTimer()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1.0 / sampleRate, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    /// Timer tick: the keepalive path. Unchanged state goes out once per
    /// keepalive interval; changes already went out from `changed`.
    private func tick() {
        guard let pad = controller?.extendedGamepad else { return }
        emit(pad, now: Self.nanos())
    }
}
#endif
