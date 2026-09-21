# Device prompt execution

Device inspector requests use one visual loop per physical iPhone:

1. Capture a new USB screen frame.
2. Give the user's goal, the frame, and recent attempted actions to the selected vision model.
3. Validate and send one Bluetooth input, or wait, request clarification, or finish.
4. Require a frame captured after that input finished before choosing another action.

The inspector selects its execution path when the user submits a request. With UI-TARS selected, every request goes directly to the visual model loop, including “Go home”, “Open Safari”, and “Close all apps”. The command parser and scripted Spotlight/close-all routines are bypassed. If the screen or model is unavailable, the request stops without falling back to scripted commands and preserves the draft for retry. UI-TARS chooses the first action and each subsequent action from a fresh screenshot, and must verify completion itself.

All providers use the visual loop. A run that loses its screen stops and never replays itself as direct commands.

Codex is the default planner. It uses Codex vision to interpret each screenshot,
check the prior input’s visible result, and generate the next command. Bluetooth
AssistiveTouch input and USB screen capture require no Developer Mode. A normal
`bun shortreel` build does not bundle or install the optional XCTest runner;
packaging it requires `SHORTREEL_INCLUDE_RUNNER=1`. Existing installations retain
their saved planner choice; choose Codex in Agent to switch.

The action decoder is an input adapter, not a workflow planner: it validates model output and maps one action to one phone operation. UI-TARS can request `hotkey(key='appSwitcher')` to perform the existing bottom-edge swipe-and-hold gesture. It then inspects each new screenshot and chooses which card to swipe, whether to wait, and when the goal is complete. Compound actions such as `closeAllApps` are rejected by visual-action validation. The executor does not automatically retry UI-TARS inputs; the model receives the next frame and chooses any retry, subject to the runner’s stalled-action guard.

See [Phone action catalog](phone-actions.md) for the full coordinate, gesture timing, keyboard, and flow-control interface.

## UI-TARS observation and verification

UI-TARS uses the selected model for three separate tasks: classify the current screen without the goal or prior explanations; propose one action using execution evidence; and review that proposal against the screenshot and goal without the planner's explanation. The observer uses a short layout classification: Home, Home editing, App Switcher cards, a foreground app, or unknown. The action review interprets controls and overlays within that layout. Malformed or structurally contradictory observation/review output stops input rather than skipping verification.

A rejected proposal gets one corrected planning attempt and another review. A second rejection or ambiguous screen requests clarification without executing either rejected proposal. Completion claims are reviewed too. These are independent calls to the same model, not independent models; correlated visual errors remain possible. No Grok fallback runs for UI-TARS.

Execution feedback reports whether screen pixels materially changed. This is explicitly not proof of a semantic transition. Only the two most recent transitions retain images; they are released when the run ends. The gesture executor remains responsible for one input, and the model still chooses workflow actions.

Settings → **Test App Switcher** isolates the physical gesture from planning. It captures the initial screen, sends one bottom-edge swipe with a hold at its endpoint, then requires a fresh frame with app preview cards. It leaves the switcher open and never dismisses apps. The result appears in Agent. Bluetooth starts at normalized `(0.5, 1.0)`, moves immediately to `(0.5, 0.55)` over 360 ms and holds 900 ms before releasing. It does not long-press a dock icon before moving.

## Setup

- Connect the selected iPhone to the Mac by USB, unlock it, and trust the Mac.
- Connect its Bluetooth AssistiveTouch input channels in ShortReel.
- Set Auto-Lock to Never so the screen keeps streaming: Device Settings → **Set Auto-Lock to Never** drives the phone's own Settings app to change it (Spotlight → Auto-Lock → observed tap on Never). Low Power Mode must stay off, since it forces a 30-second auto-lock.
- In **Devices → Phone Screen**, allow screen access. A uniquely matched screen connects automatically when the Bluetooth phone is connected. With multiple phones, unique names on both sides match automatically; phones sharing a name need an explicit screen-picker selection. macOS exposes USB phone screens as camera sources, which is why Camera permission is required. The USB source is multiplexed audio/video; the app has a microphone usage description for opening that source, but only configures video output and does not record audio.
- Write a goal in the right-hand inspector and press **⌘ Enter**. Stop cancels the current request.

The inspector's **Planner** picker offers four clients:

- **UI-TARS** is an optional local or hosted planner. Run `npx -p @ui-tars/cli -p uuid ui-tars start` and complete its model base URL, API key, and model prompts. ShortReel reuses `~/.ui-tars-cli.json` and calls that model service directly, using Chat Completions or Responses according to `useResponsesApi`. The CLI is a model client, not a local server; it does not need to keep running. This follows the upstream [CLI configuration](https://github.com/bytedance/UI-TARS-desktop/blob/main/packages/ui-tars/cli/src/cli/start.ts) and [model request protocol](https://github.com/bytedance/UI-TARS-desktop/blob/main/packages/ui-tars/sdk/src/Model.ts). Planning and review requests include the selected phone's current JPEG, up to two recent before/after transitions, the goal, and up to eight exact executed inputs with pixel-change results. Earlier model explanations are excluded from execution history. Frames from another source or a future timestamp are excluded, and the current frame is explicitly labelled last. ShortReel parses one UI-TARS action, checks coordinates and supported inputs, and executes it through the existing phone host. It never starts UI-TARS' Mac-desktop or Android operators. Requests time out, reject redirects and oversized/incomplete responses, and stop on cancellation. Keys and server error bodies are not logged. Without a CLI configuration, the built-in local UI-TARS server is used; selecting UI-TARS never silently invokes another model.

- **On this Mac** uses the macOS 27 Foundation Models image attachment API. It requires Apple Intelligence and a system model reporting both vision and guided-generation capabilities. Screenshots and recognized text remain on this Mac. The app still builds for macOS 15 and explains when the native planner is unavailable.

- **Codex** is the default and uses `gpt-6-astra` through the installed Codex CLI and its saved login. Screenshots and task context are sent to OpenAI. It is selectable when Codex is installed and runs independently of UI-TARS, including the App Switcher diagnostic.

- **Claude** uses Claude Code's saved login and the `sonnet` alias by default.
  Screenshots and task context are sent to Anthropic. It supports the same Agent
  requests, Stage workflows, and App Switcher/screen inspection calls as Codex.
  The CLI must support `--safe-mode`; `SHORTREEL_CLAUDE_PATH` overrides discovery.

Codex and Claude share `PhonePlannerContext` (instructions, task prompt, bounded
progress notes, and same-phone screenshot history) and `PhonePlannerResponse`
(schema, action validation, and navigation checks). Their adapters differ only
in CLI invocation and image/result packaging. The inline Model section remembers a
separate model selection for each provider; custom image-capable model IDs are
accepted. The old saved `astra` provider value is retained for compatibility,
while its display name is Codex. Model changes cancel active requests just like
provider changes. UI-TARS and the native model retain their existing protocols.

Changing the planner cancels active requests. The picker is disabled while a request runs, and its disclosure identifies where screen data is processed.

Each request uses only the selected planner. There is no automatic fallback to Grok or another provider.

## Stage actions

The inspector's **Stage** pane submits reusable goals to the same per-phone visual
session as Agent. **Clear Home Screen** starts immediately and keeps Instagram,
YouTube, TikTok, and X while removing other app icons from visible Home Screen pages,
the Dock, and folders. It instructs the planner to use **Remove from Home Screen**,
preserving installed apps and their data in App Library. It also removes Home
Screen widgets and entire widget stacks, using Remove Widget/Remove Stack followed
by the observed widget confirmation. Already hidden pages, Today View, and Lock
Screen widgets are left alone. Missing allowed apps are added from App Library when
installed; otherwise the run requests input. It never installs apps or hides
whole pages as a shortcut. This follows [Apple's removal flow](https://support.apple.com/guide/iphone/remove-or-delete-apps-iph248b543ca/ios).

Cleanup prefers entering editing mode once by holding empty wallpaper (or choosing
Edit Home Screen from an icon menu), then tapping each unwanted app's visible minus
badge and choosing Remove from Home Screen. It stays in editing mode between apps
and across pages, re-reading each screenshot because icons rearrange. Individual
long-press removal is a fallback when editing badges are unavailable. An already
open app menu proceeds through Remove App, followed by Remove from Home Screen
on the next screenshot. Page-overview
minus buttons and checkmarks must not be used to remove or hide pages.

The goal requires exactly one visible Home Screen page with an empty grid and
Instagram, YouTube, TikTok, and X in the Dock. Cleanup continues onto the next page
to the right with a leftward finger swipe, until App Library is observed. Empty
pages are allowed to collapse after editing ends; pages are never hidden as a
shortcut. A final sweep checks both boundaries after the last layout change.

Every cleanup completion claim receives a separate visual review of the entire
goal, which can return a next input to continue cleanup or verification. The
runner also requires observed horizontal navigation in both directions since the
last non-navigation input, and a separate inspection rejects completion outside
normal Home. Navigation alone does not prove page count: identifying exactly one
empty page, the boundaries, and the Dock contents still relies on visual model
judgment. The Search pill or one empty screenshot is insufficient evidence.
Codex and Claude retain bounded progress notes and recent screenshot transitions;
notes are unverified observations, not proof. Before a third unchanged cleanup
input, the planner gets one corrective request to choose a different action;
the repeated-input guard still blocks an unchanged retry.

A local English OCR check runs before each cleanup input. When it recognizes a
removal menu, it grounds a proposed menu-row tap to the center of the observed
Edit Home Screen, Remove App, Remove from Home Screen, Remove Widget, Remove Stack, or Cancel label.
A generic Remove is permitted only for an explicitly identified widget/stack
confirmation. Side-by-side Cancel/Remove controls use the proposed X coordinate
to select the nearest unambiguous safe label. Escape is also allowed. Every input
still requires a new screenshot before the next decision; the two app-removal
steps are never sent together. It blocks deletion/offload controls and unverified
menu inputs. A rejected menu input receives one replanning attempt using the
recognized safe labels and their coordinates on the same screenshot; no input has
been sent yet. The replacement passes through the same guard, and a second rejection
stops the run. The next removal step always waits for a fresh post-action frame.
OCR can miss text or misread a screen; this is an additional
check, not a guarantee against perception errors. OCR failures stop the run.

**Warm Up** opens a task brief for the app, activity, and stopping criterion.
Every warm-up begins with an account check: the agent opens the app's profile,
reads the signed-in handle from the screenshot, and confirms it matches the
persona's handle. A signed-out app, an account picker, or any other handle stops
the run with a request for input before any browsing or engagement; the agent
never signs in, signs out, switches accounts, or enters credentials.
**Create Content** opens a modal with an extensible content-type picker, starting
with **Slideshow**. Configure the destination app, topic, 2–20 slides, and the
existing phone photos to use (such as album, selection, and order). Caption and
extra instructions are optional; a blank caption asks the agent to write one
from the topic. This first version uses existing photos, not image generation.

The configuration can be edited while offline or while another task runs.
**Create Draft** requires a connected, available phone and valid details within
the planner's goal limit. It submits the structured brief to the existing content
workflow and requests a saved draft only, never publishing or scheduling it.
Missing photos, unsupported slideshow creation, or unavailable draft saving require
input. Form values remain in the current phone's Stage view when the modal closes.
These are model-driven goals; the modal does not itself generate or transfer images.

Stage runs allow at most **300 decisions or one hour**, whichever comes first.
Agent's ordinary messages retain the 30-decision/five-minute limit. Both paths
share source checks, fresh frames, cancellation, and stalled-input detection.
The Stage pane displays progress and Stop; Agent contains the full transcript.
Only one request can run per phone. Starting a stage preserves any composer draft.
Rerunning an interrupted stage starts from fresh observations of the current phone.

Validation: `Tests/DeviceWorkflowTests.swift` covers extended and bounded runs,
session submission, removal-target checks, real OCR on a synthetic dialog,
completion layout checks, and cancellation before dispatch. No physical-phone
cleanup has been verified by these tests.

## Codex through the Codex CLI

`CodexPhonePlanner` invokes `codex exec` once per observed step, using image attachments,
`--output-schema`, and `--output-last-message`. Its prompt arrives on stdin, and only the
final response file is decoded; stdout diagnostics never become phone input. See the
[noninteractive CLI documentation](https://learn.chatgpt.com/docs/non-interactive-mode).
The CLI uses existing authentication without ShortReel reading or copying credentials.

Each invocation uses a unique private temporary directory, `--ephemeral`, read-only
sandboxing, dedicated phone-planning instructions, and `--ignore-user-config`. Shell,
apps, plugins, hooks, browser/computer control, image generation, and multi-agent
features are disabled. The caller retains `CODEX_HOME` for CLI authentication, but
does not inherit the parent agent's thread attribution. Temporary screenshots,
instructions, schema, and response files are removed on success, failure, or cancellation.
There is no resumed CLI conversation to mix different phones' histories.

The model receives the goal, up to eight executed inputs with measured pixel-change
feedback, and the current frame plus at most two recent transitions. Only earlier
frames from the same source are included, with the current image last. Each response
contains a `screen` observation and one `decision`; inspection-only calls return just
`screen`. `PhonePlannerResponse` validates exact keys, observations, normalized coordinates,
timing, text limits, and keyboard names before converting to `PhoneVisionDecision`.
Compound launch/search commands are not in the schema. The existing visual runner
enforces fresh screenshots, per-phone source identity, stalled-action detection, Stop,
and the overall request deadline. The executor does not automatically replay Codex
inputs; the next model decision chooses any retry. Completion requires a fresh screen;
an app-opening goal cannot finish on Home, Spotlight, or an App Switcher preview.

The CLI process has a 90-second timeout and a 1 MB combined output limit; final JSON is
limited to 64 KB. Nonzero exits surface an actionable CLI/login message without exposing
raw stderr. A locked screen or genuinely ambiguous target can request clarification;
a browser page mentioning the requested app should return Home and continue through
Spotlight. An already foreground app can complete an opening request immediately.

Compile and run `Tests/CodexPhonePlannerTests.swift` using its header command. It tests
the actual process boundary with a fake CLI, plus decoding, navigation checks, concurrent
phone isolation, cleanup, cancellation, and timeout behavior. Setting
`SHORTREEL_CODEX_SMOKE=1` runs two additional real Codex calls against a generated browser
screenshot: one Home decision and one screen inspection. It sends no phone inputs and
requires a logged-in Codex CLI with access to the selected model. Live hardware behavior still needs
verification on a connected phone.

## Claude through Claude Code

`ClaudePhonePlanner` invokes `claude --print` per screen observation, with base64
JPEG content blocks on stream-JSON stdin. It uses the shared instruction file
and JSON schema. Only a single successful final `result.structured_output` is
decoded into a phone decision; intermediate text, malformed output, failed result
envelopes, and duplicate final results cannot become phone input.

Requests use `--safe-mode`, no built-in tools, an empty strict MCP configuration,
disabled skills/Chrome/hooks, noninteractive permissions, and no session
persistence. Safe mode preserves CLI login (unlike `--bare`). ShortReel filters
the environment, retains only the CLI's supported authentication variables and
normal process settings, and never reads credential files or logs raw output.
The process has a 90-second timeout, a 1 MB combined output limit, a three-turn
internal limit, and the same cancellation behavior as Codex. Managed enterprise
policy still applies to the CLI. There is no automatic provider fallback.

`Tests/ClaudePhonePlannerTests.swift` tests the process boundary using a fake CLI,
including shared instructions/schema, selected model, image isolation, result
validation, cancellation, timeout, and temporary-file cleanup. Set
`SHORTREEL_CLAUDE_SMOKE=1` to additionally run real screenshot navigation and
inspection against a generated browser image, without sending any phone input.
See Anthropic's [CLI reference](https://code.claude.com/docs/en/cli-reference) and
[streaming image input](https://code.claude.com/docs/en/agent-sdk/streaming-vs-single-mode).

For an already bonded phone, **Connect** now asks the Classic Bluetooth manager to connect to that exact saved address, then opens HID Control (PSM 17) followed by HID Interrupt (PSM 19). It also accepts phone-initiated channels and reuses them if they arrive first. Pairing or an ACL connection alone never marks the phone controllable: both usable HID sockets are required. A failed or cancelled attempt closes only its partial HID channels and leaves unrelated Bluetooth services alone.

## Identity and observations

`PhoneScreenCaptureService` enables CoreMediaIO screen-capture devices and recognizes external Apple muxed inputs whose model is `iOS Device`. It excludes ordinary webcams and Continuity Camera. Capture IDs are opaque: this Mac reports a privacy UUID for SOCIAL15PRO, not its USB UDID. Requiring a physical UDID in that field incorrectly hid the attached phone.

`DeviceManager` first identifies the trusted USB phone by its Bluetooth address. Automatic association prefers a unique physical UDID match when one is exposed. For privacy UUIDs, the friendly name stands in when it forms a unique pair: exactly one phone and one source carry it. Phones or sources sharing a name stay ambiguous and need an explicit screen-picker selection.

The capture engine keeps AVFoundation objects on one serial queue. It converts sample presentation timestamps through the capture session's synchronization clock to distinguish newly captured frames from late delivery. It encodes at most ten JPEG frames per second, bounded to a 1280-pixel long edge, and pre-decodes each frame to a CGImage on the capture queue so views never decode JPEG on the main actor. Published dimensions come from the encoded image.

Starting an AVFoundation graph does not mark the screen ready. Startup waits for the selected source's first usable frame with a capture timestamp later than startup, and times out after eight seconds if none arrives. The failed session is then closed, so a silent stream cannot leave the UI waiting indefinitely or enable visual input without an image. The same eight-second deadline applies to subsequent fresh-frame requests; stopping or disconnecting rejects pending requests. Video-connection state is diagnostic only during muxed-source startup. Bounded `PhoneScreen` logs report graph readiness, the first sample, rejected samples, the first encoded frame, and callback/frame totals on stop.

The runner checks source identity, frame ID, capture time, JPEG validity, and encoded dimensions. It checks cancellation and connection state again after model inference and before input. Completion requires a model decision based on a valid screen observation (and a separate completion review for UI-TARS); a successful Bluetooth write alone is not completion.

Home uses the Bluetooth driver's bottom-to-top AssistiveTouch pointer gesture. It does not open or read the floating menu. The visual runner requires a new frame after the input; delivery alone does not establish that Home appeared.

The swipe routing and frame checks are covered by injected tests and the application build. Live testing on September 19, 2026 verified the bottom-edge Home gesture, Spotlight search, and Safari launch on SR2 using Bluetooth AssistiveTouch input and USB screen capture. Pointer positioning is sent with the button released before a swipe begins.

Home navigation uses AssistiveTouch: tap its floating button at the position observed in the current frame, inspect the menu, then tap its Home control. Dismiss a remaining menu after Home appears. The planner uses the AssistiveTouch menu input if the floating button cannot be located; it does not use the bottom-edge Home swipe. Each tap is followed by a fresh screenshot. App Switcher and app-dismissal gestures retain their separate meanings.

All visual planners prefer a coordinate tap on the requested app’s visible Home or Dock icon. Coordinates come from the current phone screenshot, never a saved position. They return Home if needed and inspect for the icon. Spotlight is the fallback when the icon cannot be confidently located: open search, verify its focused field, enter the app name (replacing an old query), and select its matching installed-app result. Every input is followed by a fresh screen observation. If the app is already open, they continue the goal there. Explicit icon taps and coordinate requests retain their literal meaning.

## Bounds and limitations

- One request runs per device. Ordinary messages allow at most 30 decisions and five minutes; Stage actions allow 300 decisions and one hour. A suspended capture or model cannot later dispatch a result after cancellation or timeout.
- Repeating an equivalent input on a visually unchanged screen stops before the third dispatch. A small grayscale image comparison excludes the top and bottom edges and tolerates minor pixel changes; nearby taps count as equivalent. JPEG encoding noise and small pointer movements therefore do not reset the guard. Larger screen changes can still reset it; the overall limits remain in force.
- Local Vision text recognition supplies per-frame text targets. OCR-selected taps use those anchors rather than model coordinates. The native planner requires explicit user coordinates for unlabeled targets. UI-TARS uses image-selected coordinates normalized using resized-image pixel bounds for version 1.5, or the 0–1000 convention for older models and accepts only the supported phone actions. Coordinate bounds and structured output checks cannot guarantee perception accuracy. The next fresh frame supplies feedback. Ambiguous or inconsistent decisions stop for clarification.
- Text input uses the existing US keyboard map, at most 100 characters per visual step. Passwords, verification codes, ambiguous targets, and unobservable goals may require user input.
- Run history contains attempted actions and the model's short explanations. A completed result includes its claimed visual evidence, which the user can compare with the live phone preview.

Live testing on September 16, 2026 verified capture from the attached SOCIAL15PRO after the signed build: the USB screen delivered 591×1280 JPEGs at approximately three frames per second, with a first-frame capture age of about 0.11 seconds. USB trust and Bluetooth identity succeeded, and both Bluetooth HID channels opened. After the USB screen was disconnected, a direct “Open Settings” request reported **Sent**, confirming that the Bluetooth-only execution path remained available. That status does not prove Settings appeared on the phone.

Later live testing on the same phone verified **Open Safari** through the complete Grok loop: a dock-icon tap opened Safari, a new frame showed Safari's toolbar and address, and the request reported **Completed**. Separate explicit tap/type/Enter requests loaded `bloxwap.com`, confirming physical keyboard input. The initial compound visual request opened Safari but timed out on a later high-effort model call; low effort is now explicit. A synthetic production call with that setting completed in 5.84 seconds. These checks establish the observed navigation path, not reliability for arbitrary goals.

The explicit Connect path also succeeded on the installed build: the bonded connection callback returned success, then PSM 17 and PSM 19 opened in order, followed by fresh USB screen frames. Both input channels were ready about 2.2 seconds after Connect.

## Current UI-TARS verification results

The September 19, 2026 gesture diagnostic opened App Switcher on SR1 and SR2 over Bluetooth, with visible preview cards on both USB screens. SR2 also passed the model's post-gesture classification. The corrected driver starts at the exact bottom edge and moves without the old initial half-second press.

Local replay checks with the existing Q4 UI-TARS model distinguished Home, Home editing, App Switcher and foreground Safari in four captured examples. The critic rejected closing-app taps on Home editing and Safari, and accepted an upward swipe on the visible News preview. These are example checks, not a general accuracy guarantee.

In the final live SR1 “Close News” run, the model chose two upward card drags and observed that News remained visible. It then requested clarification after rejecting a revised proposal. The request did not complete. This verifies the new observation/review path and its bounded stop, not reliable app dismissal for every goal.

## Verification

Launch verification uses guidance for the observed layout rather than requiring App Switcher previews on every task. For explicit `open`/`launch` requests recognized by the existing command parser, Home permits a coordinate tap on a visible app icon, with Spotlight as a fallback. Codex’s navigation validator accepts bounded taps while continuing to reject typing on Home and premature completion. UI-TARS preserves the requested app name in its Home planning goal and sends proposed taps through its visual critic to check the target; a search-opening swipe can still pass the local mechanics check. Every executed input returns to a fresh screenshot to verify progress. No app name or icon coordinate is hard-coded. Other goals retain their original instructions and independent review.

Spotlight has its own observation label: Siri Suggestions or app results with a system Search field/keyboard are distinct from Home's grid and dock. The local UI-TARS replays of the reported SR1 Home screenshot and its live Spotlight result select a downward swipe and then typing `tiktok`, respectively. Tests cover direct Home/Dock taps, wrong-target rejection by the UI-TARS critic, the Spotlight fallback, rejecting typing and premature completion on Home, preserving the app name, and keeping close-app goals separate.

For a named app in Spotlight's Top Hit section, current-frame OCR locates the heading and matching app caption. The proposed tap must fall inside that app's result area; taps on web suggestions are rejected with the measured bounds. A matching target is allowed from this explicit goal-and-screen evidence, then the next frame must establish whether the app actually opened. Missing text anchors fall back to model review rather than guessing coordinates.

An empty Spotlight field and visible keyboard are also checked from current-frame text before allowing the requested app name to be typed. The final SR1 live run started in Spotlight, typed `tiktok`, tapped the installed-app Top Hit, and completed with the native TikTok login screen visible. Home-to-Spotlight was verified in the preceding run. Returning Home from Safari still failed with the existing Bluetooth Home gesture; App Switcher plus a background tap recovered Home during testing. That transport issue remains separate from the corrected launch verification.

Standalone tests in `Tests` cover capture source filtering and image encoding, visual loop order and post-action observation, malformed/stale/cross-device frames, model decision validation, cancellation, disconnects, limits, session history, and driver dispatch. The build/install command is `bun run shortreel`.

The install script signs local builds with an available Apple Development identity so macOS can retain Bluetooth and camera permissions across updates. Set `SHORTREEL_CODE_SIGN_IDENTITY` to choose a different local identity. Without a signing identity, updates may require granting those permissions again. Denied Bluetooth permission is reported immediately instead of waiting for a phone connection timeout.

Apple references: [USB screen-capture device discovery](https://developer.apple.com/documentation/coremediaio/kcmiohardwarepropertyallowscreencapturedevices), [capture synchronization clock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock), [Foundation Models attachments](https://developer.apple.com/documentation/foundationmodels/attachment), [WWDC26 Foundation Models vision](https://developer.apple.com/videos/play/wwdc2026/241/).
