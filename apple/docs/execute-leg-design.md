# Execute-leg system design: deterministic iPhone interaction with verified completion

Research synthesis, September 2026. Eight parallel research tracks (XCTest/WDA,
go-ios/pymobiledevice3, idb/tidevice/sonic, Apple's own tooling, Bluetooth HID
ecosystem, agent-verification literature, enterprise/hardware fallbacks, UI
introspection channels). Sources cited inline; full agent reports are in the
session log.

## The decision in one paragraph

Every deterministic, non-jailbreak iPhone input path in 2026 — commercial
device farms (AWS, BrowserStack, Firebase, Kobiton, Bitbar), Appium, Maestro,
Midscene, minitap — funnels through **Apple's XCTest stack**: an on-device
runner app that synthesizes events via testmanagerd's private
`XCPointerEventPath` / `XCSynthesizedEventRecord` APIs into the kernel input
pipeline. That path gives us what Bluetooth HID fundamentally cannot:
synchronous acknowledgements, quiescence waits, and an accessibility-tree
readback to verify completion. The design below makes a WDA/DeviceKit runner
the **primary execute leg**, keeps our Bluetooth HID link as the **zero-install
fallback and setup channel**, and wraps both in a command protocol where every
action carries an explicit expectation that must verify before the run
continues.

## Why Bluetooth HID alone can't be the answer

- HID is **write-only**. No project in the ecosystem (TapKit, VKCOM/devicehub's
  ESP32 rig, TestDevLab, PlusQA) has any readback over HID; everyone verifies
  from screen captures after the fact.
- AssitiveTouch interference is real and recurring: iPadOS 18.4 broke
  press-move-release drags for a commercial remote-desktop vendor; RustDesk hit
  cursor coordinate mismatches; iOS 26 moved pointer settings and made
  AssistiveTouch more load-bearing, not less.
- Multi-phone pairing over one Mac works (TapKit sells a five-phone plan, and
  our own SR1/SR2 setup confirms it), but bond fragility and per-iOS-version
  behavior drift make it a poor foundation for "executed properly to
  completion" guarantees.

Bluetooth HID remains essential for: first-boot/pairing dialogs, zero-install
control, Full Keyboard Access Shortcut triggers, and Switch Control input. It
just can't be the verification-grade leg.

## The primary leg: on-device XCTest runner

### What runs on the phone

A signed XCTest runner app hosting an HTTP/JSON-RPC server. Two maintained
options:

| Runner | Protocol | License | Notes |
|---|---|---|---|
| **WebDriverAgent** ([appium/WebDriverAgent](https://github.com/appium/WebDriverAgent)) | WebDriver REST on :8100, MJPEG on :9100 | BSD | Most battle-tested; v16.12.9 released 2026-09-19; ~9 patch releases in Sept 2026 alone. Full `/source` AX tree, W3C Actions, alerts, app lifecycle, `mobile:` gestures |
| **DeviceKit** ([mobile-next/devicekit-ios](https://github.com/mobile-next/devicekit-ios)) | JSON-RPC 2.0 over WS/HTTP on :12004 | FSL-1.1 (converts to Apache-2.0 on a delay — review terms before shipping) | New (Jan 2026); modern API (`device.io.tap/swipe/gesture/text`, `device.dump.ui`), H264 stream; smaller track record |

Longer term, a **custom minimal runner** (Maestro's design: a thin FlyingFox
HTTP server inside an XCTest bundle serving `/subTree` + tap endpoints) removes
the third-party dependency entirely and is license-trivial. Start with WDA.

### What runs on the Mac: go-ios as the sidecar

[go-ios](https://github.com/danielpaulus/go-ios) (MIT, single static binary,
JSON in/out, used in production by Sauce Labs/HeadSpin) covers the entire
provisioning and transport problem without Xcode or Node:

- `ios tunnel start --userspace` — iOS 17+ RemotePairing tunnel, **no root**.
- `ios image auto` — mounts the personalized developer disk image.
- `ios ui download (wda|devicekit)` + `ios ui install` — prebuilt runner
  artifacts re-signed with a local P12/profile, no Xcode build step.
- `ios ui run (wda|devicekit)` — launches the runner over testmanagerd and
  forwards its port, health-polling until ready.
- `ios ax` — DTX accessibility-audit channel (read-only checks, no XCTest).
- `--udid` everywhere for multi-phone; everything emits JSON.

ShortReel spawns `ios` as a subprocess per phone; Swift then talks plain HTTP
to the forwarded localhost port via URLSession. No private macOS frameworks,
no Node, no sandbox issues.

Alternatives assessed and rejected: **pymobiledevice3** (GPL-3.0 — subprocess
only, and go-ios covers the same ground; its `universal-hid-service` is worth
re-implementing later, not linking), **appium-ios-device/remotexpc** (Node
dependency chain aimed at Appium), **tidevice** (iOS 17+ broken, maintenance
mode), **sonic-cloud** (archived May 2025, AGPL), **idb** (revived and active,
MIT, but device-HID subset is unverified on iOS 18/26 and its AX readback is
simulator-only — revisit only if the app-less HID channel benches well),
**full Appium server** (viable but heavy; we only need WDA, not the Node
orchestration layer).

### Device requirements (one-time per phone)

Developer Mode on, USB trust, DDI mounted, signed runner installed and
developer cert trusted, auto-lock Never (WDA sessions die on lock; our
`PhoneAutoLockConfigurator` already handles this), and our existing
AssistiveTouch/HID setup unchanged. Signing is the main operational cost:
paid developer account → 1-year profiles; free account → 7-day re-sign.
go-ios's download/sign/install pipeline makes either cadence scriptable.

### Known risks, with mitigations

- **iOS 26.4.2 runner-reaping** ([pymobiledevice3#1666](https://github.com/doronz88/pymobiledevice3/issues/1666)):
  XCTest runner killed at T+1.2s on that specific build. Bench-test on our
  phones before committing; keep HID fallback warm.
- **iOS 27 launch-path change** ([appium/appium#22636](https://github.com/appium/appium/issues/22636)):
  `devicectl process launch` no longer works for runners — must launch via
  RemoteXPC/CoreDevice process control (go-ios's path). Pin go-ios versions.
- **testmanagerd jetsam**: on-device daemon death kills the session;
  supervisor restarts the runner and re-establishes the session.
- **Readback flakiness, not execution flakiness**: the WDA slowness guide is
  clear that hangs live in hierarchy snapshots, not in acting. Tuning knobs:
  `snapshotMaxDepth`, `excludedAttributes`, `format=description`,
  `waitForIdleTimeout`, `animationCoolOffTimeout`, `accessibilityDeadline`.
- **Private-API treadmill**: WDA breaks on iOS/Xcode updates and gets patched
  fast. We inherit that cadence — pin versions, test on iOS betas.

## The command protocol: expectation-based verify-then-continue

Modeled on VeriGUI's TVAE loop (ACL 2026: Thinking–Verification–Action–
Expectation) and the reflection patterns in AppAgent v2 / Mobile-Agent v2/v3.
The core rule from the literature: **never trust that an action landed —
attach an explicit expectation to every command and verify the post-action
observation against it.**

### Command model

Every command the planner emits is a typed action with a declared expectation:

```
Command {
  action:   tap(point) | swipe(from,to,duration) | type(text) | key(code)
          | pressButton(home|lock|volume) | openApp(bundleId) | wait(ms)
          | gesture(path)                       // multi-pointer
  expect:   appForeground(bundleId)             // scalar check
          | textAppears(string, region?)        // OCR check
          | screenSettles(timeout)              // frame-diff check
          | treeContains(query)                 // AX-tree check
          | none                                // explicit, not forgotten
  onFail:   retry(n) | replan | abort
}
```

The planner (or the example-prompt presets) authors expectations per command
type — no model training needed:

- `openApp` → `activeAppInfo.bundleId == X` (ms, deterministic)
- `tap` → frame-settle + optional OCR delta in the tapped region
- `type` → AX value of focused field, or OCR match
- `swipe`/`scroll` → scroll-region pixel shift + settle

### Verification ladder (cheapest first, stop at first pass)

1. **Scalar WDA endpoints** (tens of ms): `activeAppInfo`, `isLocked`,
   alert text/buttons. Deterministic; gate every command whose effect is
   expressible as a scalar.
2. **Frame-settle oracle** (~0 device cost): our existing CoreMediaIO stream —
   inter-frame delta below threshold for T ms means the transition finished.
   This is the universal "did anything happen / is it safe to act" signal.
3. **Vision OCR delta** (tens–hundreds of ms, Mac-side): `VNRecognizeTextRequest`
   on the captured frame; before/after text-set diff. Catches "Toast: Saved"
   class effects. Also `VNFeaturePrint` distance for perceptual similarity.
4. **AX-tree diff** (0.5–several s, selective): WDA `/source` with
   `excludedAttributes` / `format=description` / `snapshotMaxDepth`. Reserve
   for navigation commands where cheaper signals are ambiguous.
5. **VLM judge** (optional, last resort): local model or cloud planner for
   genuinely ambiguous screens.

Bonus: XCTest's built-in quiescence wait means WDA actions already block until
the app idles — a free "rendering finished" signal. Don't fight it with fixed
sleeps.

### Failure ladder

1. Retry the action once after a settle timeout.
2. Idempotency check — is the expected effect already present? (Makes retries
   safe for non-idempotent UI.)
3. Generic revert — Home + relaunch to a known anchor state.
4. Abort the sequence with an evidence bundle: before/after frames, OCR text,
   `/source` dump, command history. Surface it in the inspector's Requests
   panel (which already shows per-request step status).

### Which transport executes

- **WDA mode (default when runner is live)**: commands map to WebDriver
  actions; completion = action ack + expectation verified. TapKit's nine
  `use_phone` actions all have W3C Actions or `mobile:` equivalents; the Home
  gesture becomes `mobile: pressButton` (home) — deterministic, replacing our
  fragile edge-flick and AssistiveTouch-menu OCR path entirely.
- **HID mode (fallback)**: commands map to our existing
  `BluetoothHIDHost` reports; verification skips ladder rung 1 (no WDA
  scalars) and relies on rungs 2–5. The protocol is identical — only the
  executor and the top verification rung change.

## Complementary channels (nearly free, keep on the backlog)

- **Deterministic long-text entry**: `devicectl device pasteboard sync-with-host`
  + a single Cmd-V HID keystroke beats per-key HID typing for >100-char text
  (TapKit caps `type_text` at 100 chars for this reason).
- **Shortcut triggers via Full Keyboard Access**: our HID keyboard can fire
  FKA shortcuts that run on-device Shortcuts (settings toggles, URL opens).
  Trigger is deterministic; completion still verified via the ladder.
- **`ios ax` audit channel**: read-only DTX accessibility checks (element
  labels + rects, focus walk, AX settings readback) with no XCTest — useful
  mid-ladder signal and for verifying settings changes actually stuck.
- **Switch Control recipes over our HID link**: scripted on-device sequences
  triggerable by HID keys. Fixed-coordinate and readback-less, but useful for
  regulated/detection-sensitive apps where a runner can't be installed.

## Rollout plan

1. **Spike (days)**: install go-ios; on SR1/SR2 — userspace tunnel, `image
   auto`, `ios ui download/install/run wda`; drive taps and `/source` from
   curl. Bench-test the iOS 26.4.2 runner-reaping issue and measure `/source`
   and OCR latency on our hardware. Confirm the paid-account signing story.
2. **Executor seam**: new `PhoneExecutor` protocol behind the existing
   `DeviceHost` seam — `WDAExecutor` (HTTP) and `HIDExecutor` (current
   Bluetooth). Planner/loop code unchanged; executor chosen per device by
   runner availability.
3. **Verifier**: frame-settle detector on the existing capture stream, Vision
   OCR delta, scalar-endpoint checks; wire expectations into the command
   parser and the visual planners.
4. **Recovery + evidence**: failure ladder, evidence bundles in the Requests
   inspector UI.
5. **Lifecycle supervisor**: per-phone go-ios subprocess management, tunnel
   keepalive across reboots (go-ios#442 race), runner restart on testmanagerd
   death, re-sign cadence automation.
6. **Later**: custom minimal runner (Maestro-style) to own the on-device code;
   re-implement pymobiledevice3's Universal HID `session` batched-gesture idea
   if XCTest-free-but-acknowledged injection becomes valuable.

## License ledger

| Component | License | Integration |
|---|---|---|
| go-ios | MIT | Ship/spawn binary |
| WebDriverAgent | BSD | Sign & install on phones |
| Appium (if ever used) | Apache-2.0 | Subprocess |
| DeviceKit | FSL-1.1 → Apache-2.0 | Review conversion terms first |
| pymobiledevice3 | GPL-3.0 | Avoid; go-ios covers it |
| darwin-bt-remote | AGPL-3.0 | Read for knowledge only |

## Open items flagged by research (bench-test before relying)

- idb device-HID subset on iOS 18/26 (docs don't name which commands work).
- `perform_press` over axAuditDaemon for arbitrary apps (entitlement caveat).
- BLE absolute-mouse on iPhone (conflicting public claims; irrelevant if we
  stay on Bluetooth Classic / XCTest).
- Hard latency numbers for `/source`, screenshotr, and Vision OCR on iPhone
  class hardware — measure during the spike.
- go-ios REST API now requires `GO_IOS_API_KEY` (v1.3.0+) — use the CLI/JSON
  subprocess mode instead.
