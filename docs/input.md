# Input back to the host

The client sends three kinds of input. A game controller goes as binary `.input` packets. Keyboard, text, media keys and clicks go as `ControlMessage.mediaKey`. `PhorosInput` carries both ends of the first and the host end of the second. It also carries the geometry that turns a tap on the frame into a point on the source.

## Game controller

A game controller paired to the client plays games on the host. The client samples the controller and sends `.input` packets. The host replays them into a virtual gamepad. The operating system, and every game on it, sees a real controller.

The wire side is one packet type and one fourteen-byte payload, `ControllerReport`. [wire-format.md](wire-format.md#controller-reports) describes it. `PhorosInput` carries both ends.

### What the host needs

`VirtualGamepad` creates the device with `IOHIDUserDevice`. That call needs the `com.apple.developer.hid.virtual.device` entitlement. Apple grants it per team on request. Ask from the developer portal: Identifiers, your App ID, Additional Capabilities, HID Virtual Device. After the grant:

1. Enable the capability on the App ID.
2. Add `com.apple.developer.hid.virtual.device` = `true` to the app's entitlements file.
3. Build with a provisioning profile that includes it. A Developer ID app with a restricted entitlement must embed a profile. Xcode does this with `-allowProvisioningUpdates`.

Without the entitlement, `IOHIDUserDeviceCreateWithProperties` returns nil. There is no test path around it. Running as root does not help. The system kills an ad hoc signed binary that claims the entitlement when it starts. `VirtualGamepad` reports `.creationFailed` once per session and drops reports after that.

A host that does not have the entitlement must not set `HostCapabilities.supportsControllerInput`. It still receives `.input` packets from older clients. Recognise the type and return, before any JSON decode. Letting sixty binary packets a second fall into the JSON path fills the log.

### Which controller the Mac sees

macOS's GameController framework only adopts controllers it has a profile for. A generic HID gamepad exists in the IORegistry, but `GCController.controllers()` never lists it, and each game that reads raw HID guesses its own layout. `VirtualGamepad` therefore presents a known identity, chosen with `GamepadProfile`:

| Profile | Identity | Verified |
|---|---|---|
| `.xboxOne` (default) | Xbox Wireless Controller, Model 1708, Bluetooth | Yes, every button and axis through `GCController` on macOS 26 |
| `.dualShock4` | DualShock 4 (second revision), USB, answers calibration and identity feature reports | Layout from the documented USB report, not yet verified on hardware |
| `.generic` | Our own vendor and product id | Raw HID readers only |

The Xbox button cannot be forwarded: iOS reserves it for Game Center, so it never reaches the client app.

### Host

```swift
import Phoros, PhorosSession, PhorosInput

let capabilities = HostCapabilities(deviceName: "Mac", supportsControllerInput: true)
let gamepad = VirtualGamepad(profile: .xboxOne)
gamepad.onEvent = { event in
    switch event {
    case .created: log("virtual gamepad created")
    case .released: log("virtual gamepad removed")
    case .creationFailed: log("entitlement missing, controller input dropped")
    case .reportRejected(let status): log("HID rejected a report: \(status)")
    }
}

// In the frame handler:
case .packet(let packet) where packet.type == .input:
    guard let report = ControllerReport.parse(from: packet.payload) else { return }
    gamepad.handle(report, connected: packet.flags & ControllerReport.connectedFlag != 0)

// When the session ends:
gamepad.release()
```

The device appears on the first connected report and disappears on a report with the flag clear, on `release()`, or when the instance is dropped. Games see a controller plug in and unplug.

`GamepadReport`, `XboxOneReport` and `DualShock4Report` hold each profile's HID descriptor and the mapping from `ControllerReport` to report bytes. All three are pure and pinned by tests.

### Client

```swift
import Phoros, PhorosInput

let sampler = ControllerSampler()          // event driven, at most 60 reports/s, 1 s keepalive
sampler.onAttachmentChange = { attached in showGamepadBadge(attached) }
sampler.onReport = { report, connected in
    let flags: UInt8 = connected ? ControllerReport.connectedFlag : 0
    send(Packet.encode(.input, flags: flags, payload: report.serialized()))
}

// After auth_success:
if host.supportsControllerInput { sampler.start() }

// On disconnect:
sampler.stop()
```

`ControllerSampler` forwards the first connected controller that has an extended gamepad profile. Since 1.4.0 it is event driven: a report goes out when the framework reports a value change, no sooner than `1 / sampleRate` after the previous one, so a press waits on the network and not on the next poll (the 60 Hz poll cost up to 16 ms). `ReportThrottle` sends a report when the state changed, and otherwise once per keepalive interval. A quiet controller costs one packet a second. A report lost to a reconnect is repaired within that second. When the controller disconnects, one neutral report with `connected == false` goes out and the host releases its device.

Start the sampler only for a host that advertised `supportsControllerInput`. A host that predates the flag drops the packets. The client would show a controller badge for input that goes nowhere.

The GameController framework stops delivering input when an iOS app leaves the foreground, so forwarding pauses in the background and in Picture in Picture.

### Testing

`GamepadReport` and `ReportThrottle` are pure and covered by `swift test`. `VirtualGamepad` can only be tested with the entitlement in a signed build. Run the host and connect a controller to the client. Check that the system's Game Controllers list, or any game, shows the virtual device with sticks and triggers moving.

## Keyboard, text, media keys and clicks

The wire side is `ControlMessage.mediaKey(MediaKeyCommand)`. One message carries one of these:

- a built-in `key` for transport and seek
- a `controlID` for a button the host advertised
- `text` from a prompt
- one `keystroke` from a live keyboard, with a `keystrokeModifiers` mask
- a `click` normalised to the frame [wire-format.md](wire-format.md) lists the fields.

`KeyModifiers` is the mask. Its values are Carbon's: `command` 0x0100, `shift` 0x0200, `option` 0x0800, `control` 0x1000. The first host posted keystrokes with Carbon and the mask went out as it was. A client on any platform builds it from `ControlButton.modifier` names with `KeyModifiers(wireName:)`.

### Host (macOS)

`InputReplay` posts the events. It needs the Accessibility permission and no entitlement. Check `isAccessibilityGranted` before the first call and use `requestAccessibilityPermission()` to show the system prompt.

```swift
import Phoros, PhorosInput

func handle(_ command: MediaKeyCommand) {
    guard InputReplay.isAccessibilityGranted else { return }
    if let text = command.text {
        InputReplay.typeText(text, thenReturn: true)
    } else if let key = command.keystroke {
        InputReplay.typeKeystroke(key, modifiers: KeyModifiers(rawValue: command.keystrokeModifiers ?? 0))
    } else if let click = command.click, let point = screenPoint(for: click) {
        InputReplay.click(at: point, right: click.button == "right")
    } else {
        InputReplay.perform(command.key)
    }
}
```

What the functions lock in:

- `typeKeystroke` sends Backspace, Return and Tab as their real keys, so terminals and editors treat them as such. A character with modifiers is a chord and needs a real key code. The ANSI table supplies it, and a character with no key is typed plain. Everything else is typed as Unicode, which works on any keyboard layout.
- `typeText` types one character per event with a 2 ms gap so terminals keep up, and can press Return at the end.
- `click` moves the pointer first, then presses and releases with short gaps, so apps that track hover see the move.
- `postMediaKey` posts the NX system-defined events media-key hardware produces, so the key reaches whichever app is playing.
- `perform(_ key:)` is the original behaviour for the built-in buttons: media keys for transport, arrow keys for seek.

Typing and clicking run on a background queue. Media keys and single presses post inline.

A host that renders its own button layout (`HostCapabilities.controls`) decides what each `controlID` means. That mapping is app policy and stays in the app. `InputReplay` is the layer under it.

### Where a tap lands

The client normalises a tap to the frame it shows. The host encodes a fixed-aspect frame, so a source with a different aspect is letterboxed inside it. A viewport lock shows only part of the source. `FrameMapping` undoes both:

```swift
let point = FrameMapping.sourcePoint(
    forFramePoint: CGPoint(x: click.x, y: click.y),
    sourceFrame: capturedWindow.frame,          // or the display's frame
    shownViewport: viewportLock,                // source-normalised, nil for the whole source
    frameSize: CGSize(width: encoder.width, height: encoder.height)
)
```

`nil` means the tap was in the letterbox. `sourceRect(fromFrameRect:sourceSize:frameSize:)` does the same for a rect, which is how a host turns a `viewportLockRequest` into a source region. Both are pure and covered by tests.
