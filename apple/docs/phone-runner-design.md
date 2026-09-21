# ShortReelRunner: our own on-device driver (a WDA we own)

Design for a two-part library: a thin XCTest runner that lives on each phone
(`ShortReelRunner`) and a Mac-side client/lifecycle kit inside the app
(`PhoneRunner`). Together they form the deterministic execute + verification
leg from `docs/execute-leg-design.md`, replacing WebDriverAgent with code we
own while keeping the same hard guarantees: OS-level event synthesis,
acknowledged actions, and accessibility-tree readback — including SpringBoard,
Control Center, notification banners, and system alerts.

## Why build it instead of shipping WDA

- **Protocol fit.** WDA speaks W3C WebDriver — a browser-era protocol with
  sessions, capabilities, and element IDs we don't need. Our command model is
  `Command { action, expect, onFail }`; the runner should speak that natively.
- **Footprint.** WDA carries Safari/webview support, session management, and
  Appium compatibility shims. Maestro proved the useful core is tiny: one HTTP
  server, a tree endpoint, tap endpoints ([rebuilding the iOS driver](https://maestro.dev/blog/maestro-re-building-the-ios-driver)).
- **License and supply chain.** Everything below is Apache-2.0/BSD-compatible
  and written against headers we can dump ourselves. Nothing GPL, no Node.
- **Debuggability.** When a tap misses on TikTok at 2am, it's our log, our
  error, our fix — not an Appium issue thread.

## Architecture

```
ShortReel (Mac)                                   iPhone
┌────────────────────────────┐   USB + go-ios    ┌──────────────────────────┐
│ PhoneRunner                │   userspace tunnel│ ShortReelRunner          │
│  RunnerSupervisor          │◄─────────────────►│  XCTest bundle           │
│   (tunnel, DDI, install,   │  forwarded port   │   └ FlyingFox server     │
│    launch, forward, heal)  │  127.0.0.1:8700   │     /action/* /state/*   │
│  RunnerDeviceHost          │                   │   └ XCTest API           │
│   (DeviceHost conformance) │                   │     XCUIApplication      │
│  RunnerOracle              │                   │     XCUIDevice           │
│   (scalars, tree, alerts)  │                   │     XCPointerEventPath*  │
└──────┬───────────┬─────────┘                   └──────────────────────────┘
       │           │                            * private, v2 only
  HID executor  CoreMediaIO
  (fallback /   (frame-settle
   realism)      + OCR rungs)
```

### On-device: `ShortReelRunner`

Same shape as WDA and Maestro's driver: a stub host app plus a UI-testing
bundle. The bundle's single test starts the server in `setUp` and parks the
test; launching the "test" is what starts the driver. Launch path: go-ios
(`runxctest` / `forward`) over the userspace RemotePairing tunnel — no Xcode,
no root on the Mac.

Server: [FlyingFox](https://github.com/swhitty/FlyingFox) (Apache-2.0, pure
Swift, the server Maestro ships on-device). One port, HTTP + WebSocket.

**API surface** (thin, versioned, JSON):

| Endpoint | XCTest basis | Public API? |
|---|---|---|
| `POST /action/tap` `{x,y}` normalized | `XCUIApplication.coordinate.tap()` | yes |
| `POST /action/drag` `{from,to,duration,curve}` | `press(forDuration:thenDragTo:)` | yes |
| `POST /action/swipe` `{direction}` on element/screen | `swipeUp/Down/Left/Right()` | yes |
| `POST /action/pinch` `{scale,velocity}` | `pinch(withScale:velocity:)` | yes |
| `POST /action/type` `{text}` | `XCUIElement.typeText` / `XCUIKeyboard` | yes |
| `POST /action/pressButton` `{home,lock,volumeUp,…}` | `XCUIDevice.shared.press(_:)` | yes |
| `POST /action/openApp` `{bundleId}` | `XCUIApplication(bundleIdentifier:).activate()` | yes |
| `POST /action/gesture` `{pointers:[[…timed points]]}` | `XCPointerEventPath` + `XCTRunnerDaemonSession.synthesizeEvent` | **private — v2** (multitouch, exact timing) |
| `GET /state/app` | `XCUIApplication.state` / foreground query | yes |
| `GET /state/tree?target=&depth=&format=` | `XCUIElement.snapshot()` / `debugDescription` | yes |
| `GET /state/alerts` + `POST /action/alert` `{accept,dismiss}` | `app.alerts` | yes |
| `GET /state/locked` | `XCUIDevice` / SpringBoard query | yes |
| `GET /state/screenshot` | `XCUIScreen.main.screenshot()` | yes |
| `GET /health` | — | — |

**SpringBoard as a first-class target.** Every `/state/*` and `/action/*`
takes `target` (default: foreground app). `target=springboard` binds
`XCUIApplication(bundleIdentifier: "com.apple.springboard")`, which is what
makes the following work — all over the same endpoints:

- Home screen / App Library: icon elements with labels; tap by label or
  coordinate; page swipes.
- Control Center / notification banners: they render in SpringBoard's
  hierarchy; reachable via tree query + gesture.
- System permission alerts: `springboard.alerts` — accept/dismiss
  deterministically (the current HID path can't even detect these except by
  OCR).

**Settle control.** XCTest's quiescence wait is the built-in "UI finished
rendering" signal — but TikTok/YouTube never idle, so every action takes a
`settle` param: `idle` (default XCTest behavior), `animation` (cool-off only),
`none` (fire immediately, verification falls to the Mac-side ladder). This is
the knob WDA exposes as `waitForIdleTimeout`/`animationCoolOffTimeout`; we
make it per-request instead of per-session.

**Coordinate space.** Normalized 0…1 both axes — identical to
`NormalizedPoint` in `ShortReel/Services/DeviceHost.swift` — converted
on-device to screen points. Same command payload works against the HID
executor and the runner executor with no translation layer.

**v1 scope cut:** everything above except `/action/gesture` (multitouch,
exact-timing event records) is public XCTest API. The private
`XCPointerEventPath`/`XCSynthesizedEventRecord` path is v2, with headers we
dump from Xcode's XCTest.framework ourselves (WDA's `PrivateHeaders/XCTest`
is BSD-licensed and documents exactly what to dump).

### Mac-side: `PhoneRunner` (new folder `ShortReel/Services/PhoneRunner/`)

- `RunnerClient.swift` — URLSession/WebSocket client for the endpoints above;
  typed `RunnerError` carrying on-device failure reasons (not-hittable,
  stale snapshot, alert blocking).
- `RunnerSupervisor.swift` — per-phone lifecycle around the go-ios binary:
  userspace tunnel keepalive, `image auto` DDI mount, install/re-sign,
  `runxctest` launch, `forward` port, `/health` polling, restart on
  testmanagerd death or tunnel drop. One supervisor per UDID — multi-phone
  from day one.
- `RunnerDeviceHost.swift` — conforms to the existing `DeviceHost` protocol
  (`ShortReel/Services/DeviceHost.swift:40`). Planners and the visual runner
  route through it unchanged; `DeviceManager` picks runner-vs-HID per device.
- `RunnerOracle.swift` — the readback side, feeding the verification ladder:
  rung 1 scalars (`/state/app`, `/state/alerts`, `/state/locked`) and rung 4
  tree diff (`/state/tree`). Rungs 2–3 stay on CoreMediaIO frame-settle +
  Vision OCR — unchanged.
- `RunnerProvisioning.swift` — build/sign story: XcodeGen iOS targets in
  `project.yml`, signing with a local developer cert, `ios sign app`
  re-signing for distribution, re-sign cadence automation (7-day free /
  1-year paid).

### Executor/oracle split (the hybrid mode)

The design keeps execution and observation as separate protocols so the
realism strategy from the TikTok discussion is a config, not a rewrite:

- `executor = RunnerDeviceHost`, `oracle = RunnerOracle` → full deterministic
  mode (Settings, setup flows, content creation where detection isn't a
  concern).
- `executor = BluetoothHIDHost`, `oracle = RunnerOracle` → realistic-pointer
  mode: HID injects (genuine peripheral, zero event-side footprint), the
  runner never sends a single event and only answers `/state/*`.
- `executor = BluetoothHIDHost`, `oracle = ScreenOracle` (today) → zero-install
  fallback when no runner is provisioned.

## Integration with the existing screenshot/execute loop

`DevicePromptExecutor` / `PhoneVisualRunner` today: plan → `DeviceHost`
action → `PhoneScreenCaptureService.capture(after:)` → planner re-check.
Changes:

1. `DeviceManager` selects an executor+oracle pair per device (runner live?
   else HID; runner oracle available regardless of executor).
2. `DevicePromptPlan` actions gain the `expect` field; after each action the
   executor asks the oracle to verify per the ladder (scalars → frame-settle
   → OCR → tree diff).
3. `.home` maps to `pressButton(home)` in runner mode — the fragile
   edge-flick and AssistiveTouch-menu OCR path (`PhoneHomeNavigator`) becomes
   fallback-only.
4. System alerts stop being silent failures: the oracle surfaces
   `/state/alerts` between steps and the planner (or an auto-accept rule)
   handles them.
5. Evidence bundles on failure: runner tree dump + OCR text + before/after
   frames, shown in the inspector's Requests panel.

## Build/test layout

- `project.yml`: add `ShortReelRunner` (iOS stub app) + `ShortReelRunnerUITests`
  (the XCTest bundle containing the server — this is the artifact that gets
  installed). Host app targets stay macOS-only.
- `ShortReel/Services/PhoneRunner/` — macOS-side kit, picked up by folder-based
  sources; run `xcodegen generate`.
- Tests follow repo convention (standalone `swiftc` compiles): protocol
  round-trip tests for `RunnerClient` against a loopback FlyingFox server in
  the test target; supervisor tests against a fake go-ios subprocess.

## Risks (inherited from the XCTest path, tracked in execute-leg-design.md)

- iOS 26.4.2 runner-reaping ([pymobiledevice3#1666](https://github.com/doronz88/pymobiledevice3/issues/1666)) — spike first.
- iOS 27 breaks `devicectl` launch for runners ([appium/appium#22636](https://github.com/appium/appium/issues/22636)) — we launch via go-ios's testmanagerd path, not devicectl.
- testmanagerd jetsam → supervisor restart loop.
- Quiescence tuning for never-idle apps — mitigated by per-request `settle`.
- Private-API churn when `/action/gesture` lands in v2 — isolated behind one
  endpoint; everything else is public API.

## Build order

1. Spike: hand-build a 50-line proof — XCTest bundle + FlyingFox, `/health`,
   `/action/tap`, `/state/tree` on SpringBoard — launched via go-ios on SR1.
2. `PhoneRunner` kit: client + supervisor + `RunnerDeviceHost`.
3. `RunnerOracle` + expectation verification in `DevicePromptExecutor`.
4. Alert handling + evidence bundles in the inspector.
5. v2: private gesture synthesis (multitouch, exact-timing paths).

## Implemented integration and live-test prerequisites

The implementation now includes `RunnerCoordinator`: it matches trusted USB
phones to saved devices, installs both signed apps, allocates a separate local
port per phone, and invalidates prompt sessions when their input route changes.
Runner status and retry are in the Settings inspector. Normal application quit
stops owned test sessions/forwards; a separately started tunnel is left running.

Build device products with `SHORTREEL_DEVELOPMENT_TEAM=<team> bun scripts/runner.ts`
and package them with `bun run shortreel`. `bun scripts/runner.ts --check`
checks installed go-ios, provisioned products, CLI model configuration, and
Developer Mode without running actions. Xcode account login, profiles covering
the phones, and on-device Developer Mode confirmation remain prerequisites.

Wire version 2 adds `/action/key` (search/selectAll/addressBar/enter/escape/
backspace/tab). Swipes use a single continuous linear drag. Foreground queries
resolve the active XCTest application on every request, including after
Spotlight launches. This uses a small guarded private-XCTest adapter in
`RunnerAccessibility.m`; unsupported SDKs return an error instead of directing
input to the stub app. The public `typeKey:modifierFlags:` API synthesizes keys.
The runner identifiers are `com.joeblau.shortreel.runner`,
`com.joeblau.shortreel.runner.uitests.xctrunner`, and the test configuration name
is `ShortReelRunnerUITests.xctest` for go-ios `runtest`.

Limitations: `settle: none` does not disable XCTest's built-in quiescence;
`animation` adds a one-second pause. Lock state remains heuristic and tree
maxDepth is not implemented. Foreground detection and actual keyboard/gesture
behavior need confirmation on a signed live runner, particularly after SDK
updates. UI-TARS inference additionally requires a real model endpoint.

### Validation on 2026-09-19

- Mac Release build installed and launched from `/Applications/ShortReel.app`;
  UI-TARS preference confirmed.
- Unsigned iOS device runner `build-for-testing` passed.
- Standalone UI-TARS, runner client, runner host, runner supervisor, runner
  oracle, and prompt executor suites passed, including cancellation, both
  runner installations, version mismatch, and rejected action responses.
- Actual simulator HTTP smoke on iOS 27 verified health, Home, a continuous
  swipe into Spotlight, select-all, typing, foreground detection, screenshot,
  tree queries, and Safari address-bar navigation to `example.org`. The final
  accessibility tree contained both `Example Domain` and `example.org`.
  Safari was explicitly activated for the navigation portion; this does not
  prove the complete Spotlight app-launch or model-driven sequence.
- The smoke exposed hardware Return being acknowledged without submitting.
  `/action/key` Enter now uses XCTest `typeText("\n")`, and the corrected HTTP
  route was retested against the loaded page. The parked server test was
  deliberately stopped after the requests; it is not a conventional passing
  XCTest suite.
- Physical runner installation and actual UI-TARS inference remain untested:
  Xcode reported no account for team `99JJXS75CQ` and no development profiles;
  SR1/SR2 reported Developer Mode disabled; the UI-TARS CLI config was absent.


Wire version 3 adds optional tap count/hold duration, drag press/hold durations, and editing/navigation keys. Older request payloads retain their default behavior; the Mac supervisor requires the matching runner version to prevent old runners from ignoring new parameters. See [Phone action catalog](phone-actions.md).
