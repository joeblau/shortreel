# Device prompt execution

Device inspector requests use one visual loop per physical iPhone:

1. Capture a new USB screen frame.
2. Give the user's goal, the frame, and recent attempted actions to the selected vision model.
3. Validate and send one Bluetooth input, or wait, request clarification, or finish.
4. Require a frame captured after that input finished before choosing another action.

The inspector selects its execution path when the user submits a request. Literal inputs such as “Go home”, “Scroll down”, and explicit taps execute directly. App-opening and search requests, including “Open Safari” and compound plans containing these actions, use the visual loop whenever a verified USB screen and the selected planner are available. These navigation goals need feedback: a fixed shortcut sequence can land in the wrong app or screen. With Bluetooth alone, the text planner must validate the complete request before any input. Direct commands report input as sent, without claiming visual verification. Requests needing unavailable screen feedback ask for clarification. A visual run that loses its screen always stops and never replays itself as direct commands.

## Setup

- Connect the selected iPhone to the Mac by USB, unlock it, and trust the Mac.
- Connect its Bluetooth AssistiveTouch input channels in ShortReel.
- Set Auto-Lock to Never so the screen keeps streaming: Device Settings → **Set Auto-Lock to Never** drives the phone's own Settings app to change it (Spotlight → Auto-Lock → observed tap on Never). Low Power Mode must stay off, since it forces a 30-second auto-lock.
- In **Devices → Phone Screen**, allow screen access. A uniquely matched screen connects automatically when the Bluetooth phone is connected. With multiple phones, unique names on both sides match automatically; phones sharing a name need an explicit screen-picker selection. macOS exposes USB phone screens as camera sources, which is why Camera permission is required. The USB source is multiplexed audio/video; the app has a microphone usage description for opening that source, but only configures video output and does not record audio.
- Write a goal in the right-hand inspector and press **⌘ Enter**. Stop cancels the current request.

The inspector's **Planner** picker offers two clients:

- **On this Mac** uses the macOS 27 Foundation Models image attachment API. It requires Apple Intelligence and a system model reporting both vision and guided-generation capabilities. Screenshots and recognized text remain on this Mac. The app still builds for macOS 15 and explains when the native planner is unavailable.
- **Grok** uses the installed Grok CLI and its existing login. The request, bounded JPEG, OCR anchors, and recent attempted actions go to Grok. Each invocation uses a private temporary profile, disables tools and web search, and checks that plugins, hooks, MCP, language servers, and instruction files are inactive before sending the image. ShortReel accepts one validated JSON decision; Grok cannot execute shell commands or send phone input itself. Process cancellation, a 90-second deadline, output limits, and temporary-file cleanup bound each invocation.

Changing the planner cancels active requests. The picker is disabled while a request runs, and its disclosure identifies where screen data is processed.

For an already bonded phone, **Connect** now asks the Classic Bluetooth manager to connect to that exact saved address, then opens HID Control (PSM 17) followed by HID Interrupt (PSM 19). It also accepts phone-initiated channels and reuses them if they arrive first. Pairing or an ACL connection alone never marks the phone controllable: both usable HID sockets are required. A failed or cancelled attempt closes only its partial HID channels and leaves unrelated Bluetooth services alone.

## Identity and observations

`PhoneScreenCaptureService` enables CoreMediaIO screen-capture devices and recognizes external Apple muxed inputs whose model is `iOS Device`. It excludes ordinary webcams and Continuity Camera. Capture IDs are opaque: this Mac reports a privacy UUID for SOCIAL15PRO, not its USB UDID. Requiring a physical UDID in that field incorrectly hid the attached phone.

`DeviceManager` first identifies the trusted USB phone by its Bluetooth address. Automatic association prefers a unique physical UDID match when one is exposed. For privacy UUIDs, the friendly name stands in when it forms a unique pair: exactly one phone and one source carry it. Phones or sources sharing a name stay ambiguous and need an explicit screen-picker selection.

The capture engine keeps AVFoundation objects on one serial queue. It converts sample presentation timestamps through the capture session's synchronization clock to distinguish newly captured frames from late delivery. It encodes at most ten JPEG frames per second, bounded to a 1280-pixel long edge, and pre-decodes each frame to a CGImage on the capture queue so views never decode JPEG on the main actor. Published dimensions come from the encoded image.

Starting an AVFoundation graph does not mark the screen ready. Startup waits for the selected source's first usable frame with a capture timestamp later than startup, and times out after eight seconds if none arrives. The failed session is then closed, so a silent stream cannot leave the UI waiting indefinitely or enable visual input without an image. The same eight-second deadline applies to subsequent fresh-frame requests; stopping or disconnecting rejects pending requests. Video-connection state is diagnostic only during muxed-source startup. Bounded `PhoneScreen` logs report graph readiness, the first sample, rejected samples, the first encoded frame, and callback/frame totals on stop.

The runner checks source identity, frame ID, capture time, JPEG validity, and encoded dimensions. It checks cancellation and connection state again after model inference and before input. Completion requires a model decision based on a valid screen observation; a successful Bluetooth write alone is not completion.

Home uses the Bluetooth driver’s AssistiveTouch pointer swipe from the bottom center toward the middle of the screen, releasing immediately at the end. It does not open or read the floating menu. With a verified USB screen, the navigator checks a fresh frame before the swipe and captures again after the animation settles, checking identity, freshness, availability, and cancellation. Direct Home reports Sent; full visual goals use a subsequent model observation to establish completion.

The swipe routing and frame checks are covered by injected tests and the application build. The bottom-edge gesture still needs verification on the attached iPhone; a fresh frame alone does not prove that Home was reached.

## Bounds and limitations

- One request runs per device, with at most 30 decisions and five minutes total. A suspended capture or model cannot later dispatch a result after cancellation or timeout.
- Repeating an identical input on identical JPEG bytes stops before the third dispatch. Clock/cursor changes can prevent an exact match; the overall limits still apply.
- Local Vision text recognition supplies per-frame text targets. OCR-selected taps use those anchors rather than model coordinates. The native planner requires explicit user coordinates for unlabeled targets. Grok may identify an unlabeled control in the image and propose a normalized tap with a visual target description; bounds and structured output are checked, but those checks cannot guarantee perception accuracy. The next fresh frame supplies feedback. Ambiguous or inconsistent decisions stop for clarification.
- Text input uses the existing US keyboard map, at most 100 characters per visual step. Passwords, verification codes, ambiguous targets, and unobservable goals may require user input.
- Run history contains attempted actions and the model's short explanations. A completed result includes its claimed visual evidence, which the user can compare with the live phone preview.

Live testing on September 16, 2026 verified capture from the attached SOCIAL15PRO after the signed build: the USB screen delivered 591×1280 JPEGs at approximately three frames per second, with a first-frame capture age of about 0.11 seconds. USB trust and Bluetooth identity succeeded, and both Bluetooth HID channels opened. After the USB screen was disconnected, a direct “Open Settings” request reported **Sent**, confirming that the Bluetooth-only execution path remained available. That status does not prove Settings appeared on the phone.

Later live testing on the same phone verified **Open Safari** through the complete Grok loop: a dock-icon tap opened Safari, a new frame showed Safari's toolbar and address, and the request reported **Completed**. Separate explicit tap/type/Enter requests loaded `bloxwap.com`, confirming physical keyboard input. The initial compound visual request opened Safari but timed out on a later high-effort model call; low effort is now explicit. A synthetic production call with that setting completed in 5.84 seconds. These checks establish the observed navigation path, not reliability for arbitrary goals.

The explicit Connect path also succeeded on the installed build: the bonded connection callback returned success, then PSM 17 and PSM 19 opened in order, followed by fresh USB screen frames. Both input channels were ready about 2.2 seconds after Connect.

## Verification

Standalone tests in `Tests` cover capture source filtering and image encoding, visual loop order and post-action observation, malformed/stale/cross-device frames, model decision validation, cancellation, disconnects, limits, session history, and driver dispatch. The build/install command is `bun run shortreel`.

The install script signs local builds with an available Apple Development identity so macOS can retain Bluetooth and camera permissions across updates. Set `SHORTREEL_CODE_SIGN_IDENTITY` to choose a different local identity. Without a signing identity, updates may require granting those permissions again. Denied Bluetooth permission is reported immediately instead of waiting for a phone connection timeout.

Apple references: [USB screen-capture device discovery](https://developer.apple.com/documentation/coremediaio/kcmiohardwarepropertyallowscreencapturedevices), [capture synchronization clock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock), [Foundation Models attachments](https://developer.apple.com/documentation/foundationmodels/attachment), [WWDC26 Foundation Models vision](https://developer.apple.com/videos/play/wwdc2026/241/).
