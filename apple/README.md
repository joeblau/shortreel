# ShortReel for Apple

The native macOS controller, shared phone protocol, and iOS runner live here.
Run the commands in this document from `apple/` (`cd apple` from the repository root).
From the repository root, `bun run shortreel` still builds and launches the Mac app,
and `bun run runner` builds the optional iPhone runner.


A macOS app that farms social-media warm-up activity across real iPhones. It pairs with phones over Bluetooth by emulating an AssistiveTouch HID keyboard, reads each phone's screen over USB, and drives the UI with an agent that plans actions from what it sees on screen.

## Requirements

- macOS 15+
- Xcode with command line tools
- [Bun](https://bun.sh)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (optional — the project regenerates itself when available)
- [Codex CLI](https://learn.chatgpt.com/docs/cli), signed in with `codex login`, with access to `gpt-6-astra`
- [go-ios](https://github.com/danielpaulus/go-ios) (`bun shortreel` installs it when missing)
- An iPhone paired over USB and Bluetooth, with AssistiveTouch enabled

## Getting started

```sh
bun shortreel
```

This regenerates the Xcode project (when XcodeGen is installed), builds `ShortReel.app` in Release, signs it with your local Apple Development identity when one is available, installs it to `/Applications`, and launches it. Set `SHORTREEL_CODE_SIGN_IDENTITY` to pick a specific signing identity.

Grant the app Bluetooth and Camera permissions when macOS asks — the phone screen arrives as a camera source.

Codex is the default screenshot planner. Bluetooth/AssistiveTouch sends inputs and
USB supplies screenshots; this setup needs no iPhone runner or Developer Mode.
Existing installations retain their saved planner choice; select **Codex** in Agent.

## How it works

- **Bluetooth HID** (`ShortReel/Services/BluetoothHID`) — publishes an HID-over-GATT-style record on Classic Bluetooth so a paired iPhone's AssistiveTouch treats the Mac as a keyboard controller.
- **Screen capture** (`ShortReel/Services/PhoneScreenCapture`) — reads the USB-connected iPhone's screen, which macOS exposes as a camera device.
- **Prompt planning** (`ShortReel/Services/DevicePrompts`) — uses Codex by default, with Claude as an alternative, to interpret screenshots, generate one command, and verify the result on the next screenshot. Both share the same instructions and action validation. ShortReel executes validated tap/swipe/key actions over Bluetooth. UI-TARS and the local Mac model remain available.

See `docs/device-visual-loop.md` and `docs/tapkit-reverse-engineering.md` for the full protocol details.

Select a phone and open **Stage → Clear Home Screen** to keep Instagram, YouTube,
TikTok, and X while moving other apps off the Home Screen into App Library without
deleting them. Cleanup also removes Home Screen widgets and widget stacks. The
agent observes and verifies each interaction, including the Dock, folders, and
additional pages. Stage shows progress and Stop; Agent shows
the complete run. **Warm Up** accepts a task brief specifying
what to do and when to finish. **Create Content** opens a configuration modal
with **Slideshow** as its first content type. Choose the destination app, topic,
slide count, existing photos, caption, and instructions, then create a draft
for review. Stage actions run for up to 300 decisions or one hour. See [Stage actions](docs/device-visual-loop.md#stage-actions) for behavior
and current verification limits.

## Tests

Standalone test suites live in `Tests/` and compile directly with `swiftc`/`clang` — each file's header comment contains its build command, e.g.:

```sh
swiftc ShortReel/Services/BluetoothHID/HIDServiceRecord.swift Tests/HIDServiceRecordTests.swift -o /tmp/shortreel-sdp-tests
/tmp/shortreel-sdp-tests
```

## Local classification with Laya Core ML

Warm-up account and failure-mode checks use Laya directly through Apple's Core ML
runtime. Select **Agent → Load Local Checks Model…** to download and load it;
a warm-up run also requests loading when needed. The first load downloads about
680 MB and compiles the model. Later loads work from the local cache. The app
needs no Python installation, MLX, CUDA, or package-plugin approval.

Laya recognizes account screen types; Swift compares readable usernames exactly.
Low-confidence or ambiguous account checks stay on the existing unreadable
recovery path. Inference failures and uncertain failure-mode checks fall back to
the screenshot planner. See [classifier setup and tests](SemanticIf/README.md).

## Codex and Claude

To use **Codex**, install a current [Codex CLI](https://learn.chatgpt.com/docs/cli),
run `codex login`, and select **Codex** in the Agent planner menu. It uses
`gpt-6-astra` through your existing CLI authentication. Screenshots and task
context are sent to OpenAI; ShortReel performs each validated phone input and
captures a new screen before asking for another action. Each phone request has
separate temporary files and history. Codex also handles **Test App Switcher**
and does not need the UI-TARS model service. The planner choice applies to all
phones and is saved between app launches; Codex is the default for new installations.

**Claude** is available in the same planner menu when [Claude Code](https://code.claude.com/docs/en/cli-reference)
is installed. Run `claude auth login` once. It uses the existing Claude Code login
and sends phone screenshots to Anthropic. Set `SHORTREEL_CLAUDE_PATH` if its
executable is outside the usual local/Homebrew paths. A current CLI with
`--safe-mode` support is required.

The menu's inline **Model** section lets you choose Claude's `sonnet`, `opus`, or `haiku`
alias, or enter a custom vision-capable model ID for either provider. Codex keeps
`gpt-6-astra` as its default. Each provider's model choice is saved separately.
Provider/model changes stop active requests; the menu is disabled during a run.
Existing saved Astra selections now display as Codex.

Both providers read the same `PhonePlannerContext` instructions and task/history
format, and return the same `PhonePlannerResponse` schema. Workflows, gesture
execution, screenshot freshness checks, and cleanup safeguards are shared.
Neither CLI is given shell, filesystem, browser, or MCP tools. Each step uses a
separate temporary directory and no persisted CLI conversation.

Codex is discovered on `PATH`, in `~/.bun/bin`, `~/.local/bin`, `~/.cargo/bin`,
Homebrew locations, or the Codex app bundle. For a custom installation, launch
ShortReel with `SHORTREEL_CODEX_PATH` set to the absolute executable path. A
current CLI with `exec --ignore-user-config` support is required. ShortReel
ignores personal Codex configuration for these planner calls, retaining CLI
authentication while disabling shell, app, plugin, hook, and browser features.
See [the visual-loop documentation](docs/device-visual-loop.md#codex-through-the-codex-cli)
for the response protocol and testing.

## Optional local UI-TARS planner

To install its runtime, run `SHORTREEL_INSTALL_UITARS=1 bun shortreel` and select
**UI-TARS** in Agent. ShortReel runs
[UI-TARS-1.5-7B](https://huggingface.co/ByteDance-Seed/UI-TARS-1.5-7B) on this
Mac with llama.cpp's `llama-server`, downloading
the model on first use (about 5 GB) and listening only on loopback. Only the
selected phone's screenshot and request go to that local model. To point
UI-TARS at a hosted model service instead, finish `npx -p @ui-tars/cli -p uuid
ui-tars start` (`-p uuid` supplies a runtime dependency `@ui-tars/sdk` 1.2.3
does not declare); ShortReel reads `~/.ui-tars-cli.json` when it exists. The
local Mac model remains available in the Agent provider menu.

## Optional iPhone runner (requires Developer Mode)

The default Codex + Bluetooth setup does not use this runner. For XCTest input,
enable Developer Mode on each test phone, restart it, confirm
Enable, and leave it unlocked. Sign in to your development team in Xcode's
Accounts settings, then build the two signed runner apps:

```sh
SHORTREEL_DEVELOPMENT_TEAM=YOURTEAMID bun scripts/runner.ts
SHORTREEL_INCLUDE_RUNNER=1 bun run scripts/shortreel.ts
```

The build command needs XcodeGen. Both the stub app and XCTest host need valid
provisioning profiles covering the test phones. The opt-in Mac build packages both
signed apps; ShortReel automatically installs and starts one runner per trusted
USB phone matched by UDID/Bluetooth identity. Settings → iPhone Runner shows
startup errors and offers Retry Runner. A connected runner supplies input;
Bluetooth/AssistiveTouch remains the fallback when no runner is ready.

Check remaining prerequisites without changing phone state:

```sh
bun scripts/runner.ts --check
```

For the default live test, select a phone with a verified live screen and connected
Bluetooth input, select Codex, and request: “Open Safari and go to
example.com.” Watch the agent tap Safari’s visible icon (or find it through Spotlight), then open the requested page. A passed
build or preflight check does not verify real inference or phone input.
