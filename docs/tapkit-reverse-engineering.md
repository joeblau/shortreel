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

### Engage service publication format

`CBClassicManager.addServiceWithData:` takes a local serialization, not the
SDP wire format. Verified against this Mac's `bluetoothd` implementation of
`addServiceDataToLocalSDP` and `BT_DataElement_Extract`:

- Record: little-endian UInt16 attribute count, then UInt16 attribute IDs
  (also little-endian) followed by serialized values.
- Value: type byte, little-endian UInt16 size, then payload. Small unsigned
  integers and UUIDs have a four-byte little-endian payload even when their
  declared size is one or two bytes. Booleans have a one-byte payload.
- Strings use byte lengths; sequences use child counts and recursively
  serialized children.

Passing an on-air SDP sequence here made the daemon interpret `36 01` as
310 attributes and reject publication. The HID attribute IDs also need to
start with HIDParserVersion at `0x0201`, with HIDDescriptorList at `0x0206`.
See [Bluetooth SIG Assigned Numbers](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html)
and the [HID 1.1 test suite](https://files.bluetooth.com/wp-content/uploads/2024/10/HID11.TS_.p14.pdf).
The HID profile version is `0x0101`; the USB HID parser version is `0x0111`.

Run the record regression checks without Bluetooth hardware:

```sh
swiftc Engage/Services/BluetoothHID/HIDServiceRecord.swift Tests/HIDServiceRecordTests.swift -o /tmp/engage-sdp-tests
/tmp/engage-sdp-tests
```

After launching Engage, its `BluetoothHID` log must confirm the published
HID service before attempting pairing from the phone.

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

### Home navigation, verified from the live client implementation

The live `AssistiveTouchControlClient.home` closure uses a pointer gesture,
not Command-H. Its field is at offset `0x110`; the live factory at
`0x10003e4b0` references async descriptor `0x1010f5fb0`, thunk
`0x10003eed0`, and implementation `0x100025c00` in the arm64 slice.
The implementation moves to `(500, 990)` on a `1000 × 1000` surface,
settles for 0.1 seconds, presses the primary button, holds for 0.5 seconds,
then drags to `(500, 10)` with smoothstep interpolation over roughly
0.7 seconds before release. Gesture execution is at `0x10002c4fc`.

TapKit also has a `button3Home` onboarding stage, but that enum name alone
does not describe the live Home closure. Engage's physical test confirmed
that absolute pointer movement and a Back-button tap changed SOCIAL15PRO's
screen, while its former Command-H Home input left Settings unchanged.
The observed slow gesture changed this phone to App Switcher, and a shorter
flick also failed to establish reliable Home behavior. With a verified USB
screen, Engage therefore opens the AssistiveTouch menu, recognizes its exact
Home label alongside other menu labels, taps that observed target, and captures
again. The menu-to-Home path was physically verified on SOCIAL15PRO. A missing
or ambiguous menu stops rather than falling back to another gesture.

TapKit's `button3Home` setup configures a pointer button through the phone's
Settings UI. No writable lockdown preference for that mapping was established;
Engage does not assume the button is configured or write a guessed preference.
Its Bluetooth-only edge-gesture path remains unverified for reliable Home.
Bluetooth report delivery is only evidence of sent input; the next screen
establishes its effect.

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

Engage capture readiness, checked September 16, 2026:

- The attached phone is exposed as an external, muxed `iOS Device` using an
  opaque AVFoundation UUID, rather than its MobileDevice USB UDID. Screen
  discovery and association therefore validate those identities separately.
- `AVCaptureSession.startRunning()` can return with the capture graph running
  before any usable image arrives. Engage keeps the screen in its starting
  state until a JPEG frame from the selected source has a capture timestamp
  later than startup. If no such frame arrives within eight seconds, startup
  fails and closes that capture session instead of waiting indefinitely.
- The video connection may be populated as a muxed input starts. Its presence
  before `startRunning()` is not used as a readiness requirement; delivery of
  the first fresh frame is the requirement.
- Bounded `PhoneScreen` log events distinguish a graph with no sample callbacks
  from samples rejected for a missing clock/image buffer, invalid timestamps,
  or JPEG conversion. The first encoded frame records dimensions and capture
  age; stopping records callback and encoded-frame counts.

Sample timestamps are converted from the capture session's synchronization
clock to the host clock, following Apple's
[capture synchronization documentation](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock).
An invalid or stale timestamp is never replaced with the current time to
manufacture a fresh observation.

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

Engage's device picker now starts a Classic Bluetooth inquiry and saves the
selected device's real address after bonding succeeds. The user confirms
numeric comparison codes in the picker and on the phone. Previously paired
devices are listed separately from live inquiry results. A Bluetooth bond
does not mark a device controllable: both HID channels must open first.

Discovery uses a separate `CBClassicManager` session through
`CBClassicDiscovery`, with callback `(manager, peer, info)` verified from
`handlePeerDiscovered:`. The legacy `IOBluetoothDeviceInquiry` wrapper
returned error 1 on this Mac at the end of an inquiry without delivering
results. Pairing uses `IOBluetoothDevicePair` and its confirmation delegates.
Scan cancellation drops late callbacks; pairing and HID connection attempts
have separate timeouts. End-to-end iPhone bonding/control still requires a
physical-device check.

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

### Engage prompt routing and visual planners

The Device inspector's Planner setting selects **On this Mac** or **Grok** for
screen-based requests. The selection is saved on this Mac and defaults to the
local planner. Changing it stops active requests; the picker is disabled while
a device request is running, so a running loop cannot silently change providers.

- Literal inputs, such as “Scroll down” or explicit taps, use the deterministic
  command parser and Bluetooth driver. The whole request must parse before any
  input is sent. These requests report **Sent**, because the direct route does
  not verify their result visually.
- App-opening and search goals, including “Open Safari,” use the visual loop
  when a verified screen and planner are ready. Without screen feedback, parsed
  commands retain the direct route and report only **Sent**.
- For visual requests, a ready USB screen and selected planner enable the
  loop: capture a fresh frame, choose one interaction, send it over Bluetooth,
  and capture again before the next decision. Losing the screen stops the loop;
  it never replays the request through direct commands as a fallback.
- **On this Mac** uses Apple's on-device image understanding and local OCR.
  Screenshots, recognized text, and the request stay on the Mac.
- **Grok** sends the current screenshot, recognized text, request, and recent
  action history to Grok through the installed CLI. This is a cloud option.
  The inspector explains the data sent before the user runs a request. Provider
  availability is checked independently from USB capture and Bluetooth control.
  The CLI uses low reasoning effort for one-action decisions; its default high
  effort caused a 90-second timeout during live navigation.

Both visual planners use the same frame identity checks, action validation,
fresh-frame barrier, cancellation, and bounded execution loop. Provider
availability or a passing fixture test does not establish that a task succeeded
on a real phone; live completion must be verified from subsequent screen frames.

### Incoming channel dispatch and transport (September 2026 fix)

Further disassembly of TapKit's HIDKit shim found three missing pieces:

- Its replacement for `CBClassicPeer.handleMsg:args:` (arm64 address
  `0x100dd0be0`) handles messages 27/28 by installing callbacks before calling
  `handleL2CAPChannelOpened:` / `handleL2CAPChannelClosed:`. The framework's
  default dispatch discards these events until its outgoing peer state is
  connected; an incoming HID peripheral session can therefore lose them.
  Engage now intercepts only its own manager's HID PSMs and leaves other
  peers/services on the original implementation.
- TapKit duplicates each `CBL2CAPChannel.socketFD`, validates `SOCK_STREAM`,
  continuously reads with a dispatch source, and sends complete transactions
  with `sendmsg` plus an empty `SOL_SOCKET/SCM_RIGHTS` control message. Engage
  now uses that socket transport. Its former `sendData:withCompletion:nil`
  call was invalid: the current framework explicitly requires a completion.
- Engage now responds to report/protocol negotiation, tracks keyboard LED
  output and last input reports, handles suspend/unplug, rejects invalid
  requests, and propagates failed writes. A peer is ready only when both
  channel sockets have opened successfully.

Protocol transactions follow the Bluetooth SIG
[HID profile](https://www.bluetooth.com/specifications/specs/human-interface-device-profile-1-1-1/).
The record advertises report mode, so boot-mode requests are rejected.

Run the dispatch/protocol/socket checks (no radio or phone needed):

```sh
clang -fobjc-arc -Wall -Wno-nullability-completeness -framework Foundation -framework CoreBluetooth -framework IOBluetooth -I Engage/Services/BluetoothHID Tests/BluetoothHIDTransportTests.m Engage/Services/BluetoothHID/CBHIDSocket.m Engage/Services/BluetoothHID/HIDControlSession.m -o /tmp/engage-hid-transport-tests
/tmp/engage-hid-transport-tests
clang -fobjc-arc -Wall -Wno-nullability-completeness -framework Foundation -framework CoreBluetooth -framework IOBluetooth -I Engage/Services/BluetoothHID Tests/BluetoothHIDReconnectTests.m Engage/Services/BluetoothHID/CBHIDSocket.m Engage/Services/BluetoothHID/HIDControlSession.m -o /tmp/engage-hid-reconnect-tests
/tmp/engage-hid-reconnect-tests
```

The new USB setup bridge uses Apple's `AMDCreateDeviceList` and MobileDevice
sessions to discover attached phones, verify trust, obtain their real Bluetooth
addresses, and enable `AssistiveTouchEnabledByiTunes` on a selected phone.
USB presence is distinct from trust and from a working Bluetooth HID link.
The scanner now displays attached phones even before USB trust is granted;
phones opening both HID channels are also registered automatically.

The physical device reported `SOCIAL15PRO`, model `iPhone16,1`. Initial testing
found an untrusted phone; subsequent testing on September 16, 2026 verified
USB trust, Bluetooth identity, both HID channels, live USB frames, visible
pointer movement, and a Back-button tap that navigated Settings. A Grok visual
request also identified Safari's unlabeled dock icon and opened Safari, verified
by its Start Page in the next screen. The app's “Test Pointer Movement” action
sends only released-button pointer reports.

The Mac subsequently reported `CGSSessionScreenIsLocked = 1`, preventing
app UI verification and completion of a fresh Bluetooth permission prompt.
