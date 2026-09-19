# ShortReel

A macOS app that farms social-media warm-up activity across real iPhones. It pairs with phones over Bluetooth by emulating an AssistiveTouch HID keyboard, reads each phone's screen over USB, and drives the UI with an agent that plans actions from what it sees on screen.

## Requirements

- macOS 15+
- Xcode with command line tools
- [Bun](https://bun.sh)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional — the project regenerates itself when available)
- An iPhone paired over USB and Bluetooth, with AssistiveTouch enabled

## Getting started

```sh
bun shortreel
```

This regenerates the Xcode project (when XcodeGen is installed), builds `ShortReel.app` in Release, signs it with your local Apple Development identity when one is available, installs it to `/Applications`, and launches it. Set `SHORTREEL_CODE_SIGN_IDENTITY` to pick a specific signing identity.

Grant the app Bluetooth and Camera permissions when macOS asks — the phone screen arrives as a camera source.

## How it works

- **Bluetooth HID** (`ShortReel/Services/BluetoothHID`) — publishes an HID-over-GATT-style record on Classic Bluetooth so a paired iPhone's AssistiveTouch treats the Mac as a keyboard controller.
- **Screen capture** (`ShortReel/Services/PhoneScreenCapture`) — reads the USB-connected iPhone's screen, which macOS exposes as a camera device.
- **Prompt planning** (`ShortReel/Services/DevicePrompts`) — sends screen frames plus OCR anchors to a planner (Grok CLI or on-device) and executes the returned tap/swipe/key actions over the HID channel.

See `docs/device-visual-loop.md` and `docs/tapkit-reverse-engineering.md` for the full protocol details.

## Tests

Standalone test suites live in `Tests/` and compile directly with `swiftc`/`clang` — each file's header comment contains its build command, e.g.:

```sh
swiftc ShortReel/Services/BluetoothHID/HIDServiceRecord.swift Tests/HIDServiceRecordTests.swift -o /tmp/shortreel-sdp-tests
/tmp/shortreel-sdp-tests
```
