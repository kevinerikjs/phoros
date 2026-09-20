import Foundation

/// The fourteen-byte payload of an `.input` packet: the state of a game
/// controller attached to the client, sent at up to 60 Hz.
///
/// ```
/// offset  size  field
///      0     4  buttons, big-endian bit set, see `Buttons`
///      4     2  leftX, big-endian Int16, full range, right is positive
///      6     2  leftY, big-endian Int16, full range, up is positive
///      8     2  rightX
///     10     2  rightY
///     12     1  leftTrigger, 0 to 255
///     13     1  rightTrigger, 0 to 255
/// ```
///
/// Bit 0 of the packet header's flags (`connectedFlag`) says whether a physical
/// controller is attached. A report with the flag clear carries a neutral
/// state and tells the host to release any virtual device it created.
///
/// The client sends these framed with a `PacketHeader`, unlike its JSON
/// messages, so the host can recognise and route them by magic without
/// attempting a JSON decode sixty times a second. A host that cannot act on
/// controller input (it needs a virtual HID device) should recognise the type
/// and drop it silently.
public struct ControllerReport: Equatable, Sendable {
    /// Serialized size in bytes.
    public static let size = 14

    /// `PacketHeader.flags` bit meaning "a controller is attached".
    public static let connectedFlag: UInt8 = 0x01

    /// Standard gamepad buttons, one bit each. Layout follows the extended
    /// gamepad profile so a host can map it to a virtual device one to one.
    public struct Buttons: OptionSet, Equatable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let a = Buttons(rawValue: 1 << 0)
        public static let b = Buttons(rawValue: 1 << 1)
        public static let x = Buttons(rawValue: 1 << 2)
        public static let y = Buttons(rawValue: 1 << 3)
        public static let leftShoulder = Buttons(rawValue: 1 << 4)
        public static let rightShoulder = Buttons(rawValue: 1 << 5)
        public static let leftThumbstick = Buttons(rawValue: 1 << 6)
        public static let rightThumbstick = Buttons(rawValue: 1 << 7)
        public static let dpadUp = Buttons(rawValue: 1 << 8)
        public static let dpadDown = Buttons(rawValue: 1 << 9)
        public static let dpadLeft = Buttons(rawValue: 1 << 10)
        public static let dpadRight = Buttons(rawValue: 1 << 11)
        public static let menu = Buttons(rawValue: 1 << 12)
        public static let options = Buttons(rawValue: 1 << 13)
        public static let home = Buttons(rawValue: 1 << 14)
    }

    public var buttons: Buttons = []
    public var leftX: Int16 = 0
    public var leftY: Int16 = 0
    public var rightX: Int16 = 0
    public var rightY: Int16 = 0
    public var leftTrigger: UInt8 = 0
    public var rightTrigger: UInt8 = 0
    /// Optional trailing sequence number (two bytes after the fourteen). A client that
    /// sends the same report on more than one transport numbers them so the host can take
    /// the first copy and drop a stale one; hosts that do not know it ignore the bytes.
    public var sequence: UInt16?

    /// Nothing pressed, sticks centred, triggers released.
    public static let neutral = ControllerReport()

    public init(
        buttons: Buttons = [],
        leftX: Int16 = 0, leftY: Int16 = 0,
        rightX: Int16 = 0, rightY: Int16 = 0,
        leftTrigger: UInt8 = 0, rightTrigger: UInt8 = 0,
        sequence: UInt16? = nil
    ) {
        self.sequence = sequence
        self.buttons = buttons
        self.leftX = leftX
        self.leftY = leftY
        self.rightX = rightX
        self.rightY = rightY
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
    }

    /// The fourteen payload bytes.
    public func serialized() -> Data {
        var out = Data(capacity: ControllerReport.size)
        out.appendBigEndian(buttons.rawValue)
        out.appendBigEndian(leftX)
        out.appendBigEndian(leftY)
        out.appendBigEndian(rightX)
        out.appendBigEndian(rightY)
        out.append(leftTrigger)
        out.append(rightTrigger)
        if let sequence { out.appendBigEndian(sequence) }
        return out
    }

    /// True when `sequence` is newer than `previous` (wrapping, 16 bit).
    public static func isNewer(_ sequence: UInt16, than previous: UInt16) -> Bool {
        Int16(bitPattern: sequence &- previous) > 0
    }

    /// Reads a report from the first fourteen bytes of `data`, or `nil` when
    /// there are fewer, and the sequence from two more when present. `data` may be a slice.
    public static func parse(from data: Data) -> ControllerReport? {
        guard data.count >= ControllerReport.size else { return nil }
        let base = data.startIndex
        return ControllerReport(
            buttons: Buttons(rawValue: data.readBigEndian(UInt32.self, at: base)),
            leftX: data.readBigEndian(Int16.self, at: base + 4),
            leftY: data.readBigEndian(Int16.self, at: base + 6),
            rightX: data.readBigEndian(Int16.self, at: base + 8),
            rightY: data.readBigEndian(Int16.self, at: base + 10),
            leftTrigger: data[base + 12],
            rightTrigger: data[base + 13],
            sequence: data.count >= ControllerReport.size + 2 ? data.readBigEndian(UInt16.self, at: base + 14) : nil
        )
    }
}
