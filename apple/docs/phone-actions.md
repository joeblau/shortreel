# Phone action catalog

UI-TARS chooses **one action from the current screenshot**. ShortReel validates it, sends it to the selected phone, then captures a fresh frame before asking for the next action. The runtime catalog lives in `UITarsActionDecoder.actionSpace` and is embedded directly in the planner prompt. The key list is generated from `PhoneKey.allCases`.

These are individual input operations. Tasks such as opening Safari, entering a URL, closing all apps, or changing a setting are composed by the model with screen observations between steps.

## Coordinates and arguments

- Coordinates cover the complete phone screenshot, with `(0,0)` at top left. **Built-in UI-TARS 1.5 uses resized-image pixels**, aligned to 28-pixel dimensions; for example, a 589×1280 frame uses a 588×1288 coordinate space. The prompt supplies those bounds for every frame. Older models retain the normalized **0–1000** convention.
- Supply coordinates for every tap, press, swipe, drag, and scroll. No implicit target is substituted.
- A point is `'(250,750)'`. A box is `'[100,200,300,400]'`; its center becomes the input point.
- ShortReel divides X and Y by their respective model-coordinate bounds before dispatching **0–1** coordinates to Bluetooth or the iOS runner. Never use coordinates from the Mac window. Models named UI-TARS 1.5 select pixel mode automatically; custom endpoint names can set `coordinateSpace: "uiTars15"` in `~/.ui-tars-cli.json`, or explicitly select `"normalized1000"`.
- All model arguments are quoted strings, including numbers. Durations are in seconds. Invalid, nonfinite, missing, or unexpected arguments are rejected before input.
- Off-screen coordinates are rejected, never clamped. The computed end of a scroll must also remain on screen.
- Every response has the form `Thought: brief visible evidence`, followed by `Action: one_action(...)`. Output is parsed as data, never executed as code.

## Pointer and touch actions

| Action | Parameters and defaults | Purpose |
| --- | --- | --- |
| `click(start_box='(x,y)')` | Required point or box | Tap a visible control. `tap` is an alias. |
| `double_tap(start_box='(x,y)')` | Required point or box | Two quick taps at the same position, such as selecting a word or an app-supported zoom gesture. `double_click` and `left_double` are aliases. |
| `long_press(start_box='(x,y)', duration='0.8')` | Required point; optional duration **0.2–3**, default **0.8** | Hold a visible control to expose its context menu or selection handles. |
| `swipe(start_box='(x1,y1)', end_box='(x2,y2)')` | Required distinct endpoints; optional timing parameters below | Move a finger in the specified direction. |
| `drag(start_box='(x1,y1)', end_box='(x2,y2)', duration='0.4', press_duration='0.5', hold_duration='0')` | Required distinct endpoints; all timing parameters optional | Move between exact points; optionally hold before moving and before releasing. |
| `scroll(start_box='(x,y)', direction='down', distance='300')` | All required; direction **up/down/left/right**, positive distance in the model's screenshot units | Navigate content in the stated direction. The finger moves in the opposite direction. |

Both `swipe` and `drag` accept:

| Optional argument | Range | Default when timing is supplied |
| --- | --- | --- |
| `duration` | **0.1–3 seconds** | **0.4** |
| `press_duration` | **0–3 seconds** | **0** |
| `hold_duration` | **0–3 seconds** | **0** |

With no timing arguments, they use the existing driver swipe: approximately 0.3 seconds over Bluetooth, or the runner’s 0.4-second default. The touch stays down throughout a timed drag. A double tap is one gesture; subsequent model decisions still wait for a fresh frame.

Examples below use the normalized 0–1000 convention. For UI-TARS 1.5, use the corresponding positions within the pixel bounds supplied in the prompt.

| Interaction | Example action |
| --- | --- |
| Tap a result | `click(start_box='(260,240)')` |
| Select a word | `double_tap(start_box='(450,400)')` |
| Open a context menu | `long_press(start_box='(450,400)', duration='0.8')` |
| Reposition an item | `drag(start_box='(250,300)', end_box='(750,600)', press_duration='0.8', duration='0.7')` |
| Adjust a slider | `drag(start_box='(350,500)', end_box='(700,500)', duration='0.4')` |
| Scroll down in a list | `scroll(start_box='(500,750)', direction='down', distance='500')` |
| Reveal a row’s swipe actions | `swipe(start_box='(850,450)', end_box='(250,450)')` |
| Pull to refresh | `swipe(start_box='(500,250)', end_box='(500,700)')` |
| Open Spotlight from Home | `swipe(start_box='(500,250)', end_box='(500,750)')` |
| Request Control Center | `swipe(start_box='(950,10)', end_box='(950,650)', press_duration='0.3')` |
| Request Notification Center | `swipe(start_box='(500,10)', end_box='(500,650)', press_duration='0.3')` |
| Dismiss a visible app card | `swipe(start_box='(500,600)', end_box='(500,50)')` |

These coordinates are illustrations, not routines or verified targets. The model must locate the control/card in the actual screenshot and inspect the result. System edge gestures depend on the phone’s configuration and current screen.

## Text and keyboard

`type(content='Hello')` types into the currently focused field. It supports at most **100 printable US keyboard characters per visual step**. Newlines are rejected; submit with a separate Enter action after observing the text. Escape quotes and backslashes inside the argument.

Use `hotkey(key='name')` for any of these **21 canonical keys**:

| Key | Phone operation |
| --- | --- |
| `enter` | Submit/Return |
| `escape` | Escape; dismissal depends on the focused UI |
| `backspace` | Delete before the insertion point |
| `deleteForward` | Delete after the insertion point |
| `space` | Space |
| `tab` | Move keyboard focus forward |
| `shiftTab` | Move keyboard focus backward |
| `arrowUp` | Up arrow |
| `arrowDown` | Down arrow |
| `arrowLeft` | Left arrow |
| `arrowRight` | Right arrow |
| `selectAll` | Command-A |
| `copy` | Command-C |
| `cut` | Command-X |
| `paste` | Command-V |
| `undo` | Command-Z |
| `redo` | Command-Shift-Z |
| `search` | Command-Space |
| `addressBar` | Command-L; use when a browser is visibly open |
| `appSwitcher` | Bottom-edge swipe and hold |
| `assistiveTouch` | Bluetooth secondary-button action, normally configured to open the AssistiveTouch menu |

Clipboard actions operate on the **phone’s clipboard**, not the Mac’s. Shortcut effects depend on keyboard focus and the foreground app; an acknowledged input does not prove it worked.

Accepted aliases include `return`, `esc`, `shift+tab`, `cmd+a/c/x/v/z/l/space`, `cmd+shift+z`, and the corresponding `command+...` spellings. `hotkey(key='home')` is an alias for `press_home()`.

## System gestures and flow control

| Action | Parameters | Behavior |
| --- | --- | --- |
| `press_home()` | None | Home gesture over Bluetooth; Home button through XCTest. Leaves the current app without closing it. |
| `open_app_switcher()` | None | One bottom-edge swipe-and-hold gesture. Does not dismiss cards. Alias for the `appSwitcher` key. |
| `open_assistive_touch()` | None | Alias for the `assistiveTouch` key; Bluetooth only. |
| `wait(seconds='1')` | Optional **0.25–3 seconds**, default **2** | Wait, then capture again. |
| `finished()` | None | Complete only when the current screenshot proves the goal. Put the visible evidence in Thought. |
| `call_user()` | None | Stop and explain what information or intervention is needed. |

## Driver support and limits

Bluetooth supports the pointer gestures and keyboard operations above through AssistiveTouch. The iOS XCTest runner supports tap count, press duration, continuous drag timing, App Switcher, and the expanded keyboard set. AssistiveTouch’s menu is not an XCTest operation; that request reports unsupported rather than substituting another action.

Runner **wire protocol version 3** carries the new tap/hold/drag fields and keys. Rebuild and install the matching runner; the supervisor rejects incompatible versions so an older runner cannot silently ignore gesture parameters.

This catalog does not expose multi-touch pinch/rotate, arbitrary key combinations, raw pointer-down/up state, device locking, volume buttons, app termination APIs, or blanket alert acceptance. Pinch exists separately in the runner transport but is not offered to this Bluetooth-compatible model action set. Unsupported actions stop without sending input. Model tasks continue to use fresh frames, cancellation, bounded execution, and stalled-action detection.

Validation: decoder/parameter tests, driver-dispatch tests, runner serialization tests, and application/test-bundle builds. Newly added gestures and shortcuts still require physical-device testing.

Implementation references: [Apple’s HID keyboard usage definitions](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDUsageTables.h) and the XCTest coordinate gesture declarations in the installed Xcode SDK. The runner test-bundle build checks the concrete XCTest methods against that SDK.

UI-TARS 1.5 coordinate conversion follows the upstream [smartResizeForV15 implementation](https://github.com/bytedance/UI-TARS-desktop/blob/main/packages/ui-tars/action-parser/src/actionParser.ts). Pixel coordinates above 1000 are valid within the image's height; genuinely off-screen coordinates remain rejected.

### App-card flick execution

An upward card drag on a screen classified as App Switcher is prepared as a 160 ms flick toward the top edge, with no initial press hold and no endpoint hold. This final gesture is reviewed before execution. Bluetooth keeps constant speed through the final pressed movement and immediately sends a distinct button-up report, with no pause or deceleration before release. Explicit held drags retain their endpoint hold, and opening App Switcher still uses the separate bottom-edge swipe-and-hold gesture.

`Tests/HIDPointerDragTests.swift` covers motion through release, timing, explicit holds, cancellation, and release after transport failure.
