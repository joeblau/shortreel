# How TapKit controls an iPhone from a Mac

Notes from a static read of `/Applications/TapKit.app` (v1.0.90, bundle
`com.joosting.tapkit`). Derived from `Info.plist`, linked frameworks, Swift
symbol names, embedded source paths, and byte patterns in the binary. Nothing
was executed.

## Summary

TapKit does not install anything on the phone. It makes the Mac look like a
Bluetooth mouse and keyboard, has the user pair that "mouse" from the iPhone's
AssistiveTouch settings, and then sends absolute-position pointer reports to
tap the screen. Screen content comes back over USB as a camera feed.

```
Agent (LLM) ──► PhoneControlClient ──► HIDKit ──► CBClassicManager (private CoreBluetooth)
                                                     │  SDP record: HID profile, report map
                                                     │  L2CAP PSM 0x11 control / 0x13 interrupt
                                                     ▼
                                              iPhone AssistiveTouch (paired pointer device)

Agent ◄── ScreenshotClient ◄── AVCaptureSession ◄── CoreMediaIO screen-capture DAL device (USB)
```

## 1. Input: Bluetooth Classic HID (HIDKit)

Evidence

- `NSBluetoothAlwaysUsageDescription`: "TapKit uses Bluetooth to expose an
  AssistiveTouch HID controller for paired iPhones."
- Private CoreBluetooth symbols: `CBClassicManager`, `CBClassicPeer`,
  `CBL2CAPChannel`, `channelWithPSM:`,
  `registerCallbacksWithConnectL2CAPCallback:disconnectL2CAPCallback:error:`,
  `makeClassicManagerWithQueue:error:`, `kCBMsgArgDiscoverableState`,
  `kCBMsgArgPSM`, `hidSDPDisable`.
- SDP attribute names: `hidService`, `hidDescriptorList`,
  `bluetoothProfileDescriptorList`, `protocolDescriptorList`,
  `additionalProtocolDescriptorLists`, `SDPAttribute`, `SDPElement`,
  `SDPUUID`.
- Log strings: `HIDP transaction exceeds the L2CAP packet limit`,
  `HIDKIT_CHANNEL_READ_FAILED psm=`, `L2CAP callbacks are not installed`,
  `keyboard values fall outside the report descriptor`.
- Package path: `Packages/HIDKit/Sources/HIDKit/HostManager.swift`, plus
  `HostBluetoothLifecycleClient`, `HostBluetoothPermissionClient`,
  `HostBluetoothPowerClient`.

This is Bluetooth Classic (BR/EDR) HID, not BLE HID-over-GATT. The Mac
publishes an SDP record advertising the HID profile, becomes discoverable,
and accepts two L2CAP connections from the phone: PSM 0x0011 (HID Control)
and PSM 0x0013 (HID Interrupt). Input reports go out on the interrupt
channel as HIDP DATA transactions (`0xA1 | report`).

Public CoreBluetooth cannot do any of this. TapKit calls a private
`CBClassicManager` that CoreBluetooth ships for Apple's own use, which is
why it is not sandboxed and not in the App Store.

### HID report descriptor (found at 0x1528780 in the arm64 slice)

```
05 01        Usage Page (Generic Desktop)
09 02        Usage (Mouse)
A1 01        Collection (Application)
85 02          Report ID (2)
09 01          Usage (Pointer)
A1 00          Collection (Physical)
05 09            Usage Page (Button)
19 01 29 20      Usage Min 1, Usage Max 32
15 00 25 01      Logical 0..1
95 20 75 01      32 x 1-bit buttons              → 4 bytes
81 02            Input (Data, Var, Abs)
05 01            Usage Page (Generic Desktop)
09 30 09 31      Usage X, Usage Y
15 00 26 FF 7F   Logical 0..32767
75 10 95 02      2 x 16-bit                       → 4 bytes
81 02            Input (Data, Var, Abs)           ← ABSOLUTE position
C0 C0

05 01 09 06 A1 01   Keyboard, Collection (Application)
85 01                 Report ID (1)
05 07 19 E0 29 E7     Modifier byte (LeftCtrl..RightGUI)
15 00 25 01 75 01 95 08 81 02
95 01 75 08 81 03     Reserved byte
95 05 75 01 05 08 19 01 29 05 91 02   5 LED bits (output)
95 01 75 03 91 03
95 06 75 08 15 00 25 65 05 07 19 00 29 65 81 00   6 keycodes
C0
```

Two things matter here:

- X/Y are **absolute** (0…32767). iOS AssistiveTouch maps an absolute
  pointer to the full screen, so a tap at (x%, y%) is deterministic and
  needs no calibration or relative-motion accumulation. Mouse report is
  `[0x02][buttons ×4][x lo][x hi][y lo][y hi]`.
- A standard boot-style keyboard rides along on report ID 1, so the agent
  can type into text fields with plain USB HID keycodes.

Tap = move to (x, y) with buttons 0, then same position with button 1 set,
then button 1 cleared. Swipe = press, interpolate positions, release.

### Pairing flow (from onboarding reducer names)

`AssistiveTouchBluetoothDevicesStep`, `AssistiveTouchPairingStageStep`,
`ConnectPhoneUnpairedView`, string ". Pair that phone in AssistiveTouch
Bluetooth Devices." The user is walked to Settings › Accessibility › Touch
› AssistiveTouch › Devices › Bluetooth Devices and taps the Mac. TapKit
watches the Mac's unified log (`bluetoothd`, `activeHIDDeviceCount:\s*(\d+)
-> (\d+)`) to detect when the phone actually opens the HID channels.

## 2. Screen: iPhone as a camera over USB

Evidence

- `NSCameraUsageDescription`: "To access your phone's screen, your mac
  exposes it as a Camera."
- `_CMIOObjectSetPropertyData`, `AVCaptureDeviceTypeExternal`,
  `AVCaptureDeviceDiscoverySession`, `AVCaptureVideoDataOutput`,
  `PhoneAVDeviceClient`, `PhoneScreenCaptureClient`, `PhoneCoreMediaRuntime`.

This is the QuickTime "Movie Recording from iPhone" trick: set
`kCMIOHardwarePropertyAllowScreenCaptureDevices = 1` on the CoreMediaIO
system object, and each USB-connected, trusted iPhone shows up as an
external `AVCaptureDevice` whose video stream is the phone's screen. Frames
are fed to the LLM as screenshots and, via Agora, streamed to a remote
viewer. This part needs a cable; it does not work over Bluetooth.

## 3. Lockdown (USB) for setup and state

Evidence

- `dlopen` of `/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice`.
- `AMDevicePair`, `AMDeviceIsPaired`, `AMDeviceValidatePairing`,
  `LockdownServiceClient`, `PhoneLockdownRuntime`, `lockdownDeviceDiscovery`.
- Preference keys `AssistiveTouchEnabledByiTunes`, `AssistiveTouchAxisSweepSpeed`,
  "AssistiveTouch pref write", "Accessibility pref write".

Over the USB lockdown session TapKit reads and writes the
`com.apple.Accessibility` domain, the same channel Xcode's Devices window
uses for "Configure Accessibility". That is how it turns AssistiveTouch on
without the user touching Settings, checks lock state, and lists installed
apps.

## 4. Switch Control and Shortcuts (secondary path)

`SwitchControlAutomation`, `SwitchControlCommandServiceClient`,
`ConnectAssistiveTouchReducer`, and a large AppleScript that drives the Mac
Shortcuts app (`tell process "Shortcuts"`, `Add Shortcut`) plus
`/usr/bin/shortcuts run`. TapKit installs a "Use TapKit" shortcut on the Mac
that syncs to the phone via iCloud; iOS Switch Control (with keyboard keys as
switches, e.g. `{"action":"tap","key_code":49}`) can run it. Also uses a
private `CGVirtualDisplay` to host the Shortcuts window off-screen.
`NSAppleEventsUsageDescription` and the `com.apple.security.automation.apple-events`
entitlement exist for this.

## 5. Everything else

| Concern | Library |
|---|---|
| State management | swift-composable-architecture |
| Remote viewing / streaming | AgoraRtcKit + AgoraScreenCaptureExtension |
| WebSockets to server | Starscream |
| Local DB | GRDB / sqlite |
| Auth / billing | Supabase, `tapkit.ai` |
| Updates | Sparkle |
| Analytics / crash | PostHog |

## What this means for Engage

- `DeviceHost` in `Engage/Services/DeviceHost.swift` is the seam. A real
  `BluetoothHIDHost` needs the private `CBClassicManager` API (headers must
  be reconstructed from class-dump of CoreBluetooth) and the descriptor
  above. `NormalizedPoint` already matches the absolute 0…32767 model.
- Engage must run unsandboxed, like TapKit, and needs
  `NSBluetoothAlwaysUsageDescription`.
- Screen feedback needs USB plus the CoreMediaIO screen-capture flag and
  `NSCameraUsageDescription`.
- Turning AssistiveTouch on programmatically needs MobileDevice.framework
  over USB; otherwise the user does it once by hand.
