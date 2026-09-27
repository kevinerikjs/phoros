#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Phoros

/// Posts keyboard, media-key and mouse events on a macOS host for the input a
/// client sends in `ControlMessage.mediaKey`.
///
/// Everything here needs the Accessibility permission (`isAccessibilityGranted`).
/// Nothing here needs an entitlement: unlike a virtual HID device, `CGEvent`
/// posting is available to any Developer ID app the person has approved.
///
/// ```swift
/// guard InputReplay.isAccessibilityGranted else { InputReplay.requestAccessibilityPermission(); return }
/// if let key = command.keystroke { InputReplay.typeKeystroke(key, modifiers: KeyModifiers(rawValue: command.keystrokeModifiers ?? 0)) }
/// if let text = command.text { InputReplay.typeText(text, thenReturn: true) }
/// if let click = command.click, let point = mapToScreen(click) { InputReplay.click(at: point, right: click.button == "right") }
/// ```
///
/// Typing and clicking run on a background queue so a long text never holds
/// up the network thread. Media keys and single key presses post inline.
public enum InputReplay {
    /// Whether this process may post events.
    public static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Ask the system to show the Accessibility prompt for this process.
    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// System media keys, posted as the NX system-defined events the
    /// media-key hardware produces, so they reach whichever app is playing.
    public enum MediaKey: Equatable, Sendable {
        case playPause, next, previous, volumeUp, volumeDown, mute

        // NX_KEYTYPE_* from IOKit's ev_keymap.h.
        fileprivate var nxKeyType: Int32 {
            switch self {
            case .volumeUp: return 0
            case .volumeDown: return 1
            case .mute: return 7
            case .playPause: return 16
            case .next: return 17
            case .previous: return 18
            }
        }
    }

    private static let queue = DispatchQueue(label: "phoros.input-replay", qos: .userInitiated)

    /// The original behaviour for the built-in buttons a client sends as
    /// `MediaKeyCommand.key`: media keys for transport, arrow keys for seek.
    public static func perform(_ key: MediaKeyCommand.Key) {
        switch key {
        case .playPause: postMediaKey(.playPause)
        case .next: postMediaKey(.next)
        case .previous: postMediaKey(.previous)
        case .seekBackward: pressKey(code: UInt32(kVK_LeftArrow))
        case .seekForward: pressKey(code: UInt32(kVK_RightArrow))
        }
    }

    /// Press and release one media key.
    public static func postMediaKey(_ key: MediaKey) {
        for (flags, state) in [(0xA00, 0xA), (0xB00, 0xB)] {
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: Int((key.nxKeyType << 16) | Int32(state << 8)), data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Press and release a virtual key with modifiers held. The modifiers go
    /// down and back up as real modifier keys around it, like a physical
    /// keyboard. Setting the flags on the key event alone is not enough: the
    /// HID event source keeps those flags, and later events that do not set
    /// their own (plain typed characters) inherit them, so a one-shot ⌘ would
    /// stay held on the Mac after the phone had released it.
    public static func pressKey(code: UInt32, modifiers: KeyModifiers = []) {
        let held = modifierKeys.filter { modifiers.contains($0.modifier) }
        var flags: CGEventFlags = []
        for key in held {
            flags.insert(key.flag)
            postModifier(key.code, flags: flags)
        }
        postKey(code: code, modifiers: modifiers, down: true)
        postKey(code: code, modifiers: modifiers, down: false)
        for key in held.reversed() {
            flags.remove(key.flag)
            postModifier(key.code, flags: flags)
        }
    }

    private static let modifierKeys: [(modifier: KeyModifiers, code: Int, flag: CGEventFlags)] = [
        (.control, kVK_Control, .maskControl),
        (.option, kVK_Option, .maskAlternate),
        (.shift, kVK_Shift, .maskShift),
        (.command, kVK_Command, .maskCommand),
    ]

    /// A modifier key changing state, posted as the flags-changed event a
    /// physical modifier produces. `flags` is the full set held afterwards.
    private static func postModifier(_ code: Int, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
        else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// One half of a key press. For macros and held keys.
    public static func postKey(code: UInt32, modifiers: KeyModifiers = [], down: Bool) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(truncatingIfNeeded: code), keyDown: down)
        event?.flags = eventFlags(for: modifiers)
        event?.post(tap: .cghidEventTap)
    }

    /// One key from a client's live keyboard, as `MediaKeyCommand.keystroke`
    /// carries it. Backspace, Return and Tab go as their real keys so
    /// terminals and editors treat them as such. A chord needs a real key
    /// code, so a character with modifiers is looked up in the ANSI table
    /// and typed plain when it has none. Everything else is typed as Unicode
    /// and works on any keyboard layout.
    public static func typeKeystroke(_ key: String, modifiers: KeyModifiers = []) {
        queue.async {
            switch key {
            case "\u{8}", "\u{7f}": pressKey(code: UInt32(kVK_Delete), modifiers: modifiers)
            case "\n", "\r": pressKey(code: UInt32(kVK_Return), modifiers: modifiers)
            case "\t": pressKey(code: UInt32(kVK_Tab), modifiers: modifiers)
            case _ where !modifiers.isEmpty:
                if let code = ansiKeyCode(for: key) {
                    pressKey(code: code, modifiers: modifiers)
                } else {
                    typeUnicode(key)
                }
            default:
                typeUnicode(key)
            }
        }
    }

    /// Press and release one named desktop key. This shares the same serial
    /// queue as live text so rapid taps keep their down/up ordering.
    public static func typeSpecialKey(_ key: SpecialKey, modifiers: KeyModifiers = []) {
        queue.async {
            pressKey(code: virtualKeyCode(for: key), modifiers: modifiers)
        }
    }

    /// Type a line of text into whatever has focus, one character per event
    /// with a short gap so terminals keep up. Newlines inside the text are
    /// typed as Return. `thenReturn` presses Return once at the end.
    public static func typeText(_ text: String, thenReturn: Bool) {
        queue.async {
            for scalar in text.unicodeScalars {
                if scalar == "\n" || scalar == "\r" {
                    pressKey(code: UInt32(kVK_Return))
                } else {
                    typeUnicode(String(scalar))
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            if thenReturn {
                Thread.sleep(forTimeInterval: 0.05)
                pressKey(code: UInt32(kVK_Return))
            }
        }
    }

    /// Move the pointer to `point` (global, top-left origin) and click.
    /// `count` 2 or 3 marks the click as the second or third of a multi-click,
    /// which is what makes apps treat it as a double- or triple-click.
    public static func click(at point: CGPoint, right: Bool = false, count: Int = 1) {
        queue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            let button: CGMouseButton = right ? .right : .left
            let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
            let clickState = Int64(max(1, min(count, 3)))
            if clickState == 1 {
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.02)
            }
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: clickState)
                event?.post(tap: .cghidEventTap)
                if type == down { Thread.sleep(forTimeInterval: 0.03) }
            }
        }
    }

    /// The button a pointer drag is holding down, if any. Only touched on `queue`.
    private static var heldButton: CGMouseButton?

    /// Press a mouse button at `point` and keep it down (the start of a drag).
    public static func pointerDown(at point: CGPoint, right: Bool = false) {
        queue.async {
            if heldButton != nil { releaseHeldButton(at: point) }
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            let button: CGMouseButton = right ? .right : .left
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
            let event = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
            event?.post(tap: .cghidEventTap)
            heldButton = button
        }
    }

    /// Move the pointer while a button is held (a drag), or plainly if none is.
    public static func pointerMove(to point: CGPoint) {
        queue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            let type: CGEventType
            switch heldButton {
            case .left?: type = .leftMouseDragged
            case .right?: type = .rightMouseDragged
            default: type = .mouseMoved
            }
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                    mouseButton: heldButton ?? .left)?.post(tap: .cghidEventTap)
        }
    }

    /// Release the held button at `point` (the end of a drag).
    public static func pointerUp(at point: CGPoint) {
        queue.async { releaseHeldButton(at: point) }
    }

    /// Release a held button wherever the pointer is. For a client that went
    /// away mid-drag, so no button stays down on the Mac.
    public static func releasePointer() {
        queue.async {
            guard heldButton != nil else { return }
            releaseHeldButton(at: CGEvent(source: nil)?.location ?? .zero)
        }
    }

    private static func releaseHeldButton(at point: CGPoint) {
        guard let button = heldButton,
              let source = CGEventSource(stateID: .hidSystemState) else { return }
        let event = CGEvent(mouseEventSource: source, mouseType: button == .right ? .rightMouseUp : .leftMouseUp,
                            mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
        heldButton = nil
    }

    /// Scroll the view under `point` by a delta in points, as a trackpad does.
    /// Positive `dy` moves the content down (scrolls toward the top).
    public static func scroll(at point: CGPoint, dx: Double, dy: Double) {
        queue.async {
            guard let source = CGEventSource(stateID: .hidSystemState) else { return }
            if CGEvent(source: nil)?.location != point, heldButton == nil {
                CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event?.post(tap: .cghidEventTap)
        }
    }

    /// The wire modifier mask as `CGEventFlags`.
    public static func eventFlags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    /// The ANSI virtual key code for one typed character, for chords.
    /// Letters match either case. `nil` for characters with no key.
    public static func ansiKeyCode(for key: String) -> UInt32? {
        guard key.count == 1, let character = key.lowercased().first, let code = ansiTable[character] else { return nil }
        return UInt32(code)
    }

    private static func virtualKeyCode(for key: SpecialKey) -> UInt32 {
        switch key {
        case .escape: return UInt32(kVK_Escape)
        case .tab: return UInt32(kVK_Tab)
        case .leftArrow: return UInt32(kVK_LeftArrow)
        case .upArrow: return UInt32(kVK_UpArrow)
        case .downArrow: return UInt32(kVK_DownArrow)
        case .rightArrow: return UInt32(kVK_RightArrow)
        case .home: return UInt32(kVK_Home)
        case .end: return UInt32(kVK_End)
        case .pageUp: return UInt32(kVK_PageUp)
        case .pageDown: return UInt32(kVK_PageDown)
        case .forwardDelete: return UInt32(kVK_ForwardDelete)
        case .f1: return UInt32(kVK_F1)
        case .f2: return UInt32(kVK_F2)
        case .f3: return UInt32(kVK_F3)
        case .f4: return UInt32(kVK_F4)
        case .f5: return UInt32(kVK_F5)
        case .f6: return UInt32(kVK_F6)
        case .f7: return UInt32(kVK_F7)
        case .f8: return UInt32(kVK_F8)
        case .f9: return UInt32(kVK_F9)
        case .f10: return UInt32(kVK_F10)
        case .f11: return UInt32(kVK_F11)
        case .f12: return UInt32(kVK_F12)
        }
    }

    private static let ansiTable: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
        "9": kVK_ANSI_9, " ": kVK_Space, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
    ]

    private static func typeUnicode(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var units = Array(text.utf16)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            // Explicitly unmodified, so a chord typed just before cannot leak into it.
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }
    }
}
#endif
