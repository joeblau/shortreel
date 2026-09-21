# Design Review — Inspector

Scope: the device inspector (`DevicePromptInspector`, `DevicePromptHistory`,
`DevicePromptView`, `DeviceStageView`). SwiftUI/macOS, so the catalog's
React greps were adapted (`Form`/`.formStyle(.grouped)` ≈ Card, `Divider`
≈ `divide-y`, `.buttonStyle` ≈ variant). Screenshots in `design-review/`.

## Verdict

The inspector's biggest lever is **containers and repetition**: the grouped
Form draws a card around a device header that duplicates the gallery card,
another card around the request list with a divider under every row, and
every row ends in the same filled orange pill — so nothing in the pane is
primary. Strip the containers, give each row a leading status glyph, and
tier the composer's three controls, and the pane reads as one list plus one
composer instead of boxes-in-boxes.

## Findings

| # | Check | Where | Finding | Fix |
|---|---|---|---|---|
| 1 | LAY-1 / LAY-2 (P1) | `DeviceGalleryView.swift:279-338`, `inspector-dark-before.png` | Grouped Form renders 2 cards (device header, Requests) + a divider under every request row + the bordered composer: 4 non-list surfaces in a 360pt pane. | Plain scroll list, whitespace between rows, no dividers; keep the composer as the single emphasized surface. |
| 2 | HIER-2 (P1) | `DeviceGalleryView.swift:281-311` | Device header card (icon + name + status) repeats the gallery card the user just clicked, and sits in its own card. | One compact header line (name · status dot) shared by both segments; drop the icon. |
| 3 | HIER-3 / COL-4 (P1) | `DevicePromptView.swift:147-160`, screenshot: 4× "Needs clarification" pills | Status is a trailing filled capsule on every row; repeated it becomes noise and competes with the prompt text. No leading anchor to scan by. | Leading status glyph column (checkmark / question / xmark / spinner) in its semantic color; status word as the secondary line when there's no message, tooltip + accessibility label otherwise. |
| 4 | BTN-1 tiers (P1) | `DevicePromptView.swift:48-88` | Composer row is three bordered controls of the same tier (example menu, planner picker, Run) — Run is prominent, but the other two aren't distinguished. | Example menu → tertiary icon-only borderless; planner picker stays secondary; Run stays the one prominent button. |
| 5 | HIER-6 (P2) | `DevicePromptView.swift:73-78` | "⌘ Enter" text inside the Run button — macOS surfaces shortcuts via menus/tooltips, not inline. | Plain "Run" + `.help("… (⌘↩)")`. |
| 6 | LAY-3 (P2) | `padding(10)`, `padding(9)`, `spacing: 5/6/7/10`, `7×7` dots, `horizontal 7 / vertical 3` | Off-grid one-offs. | Snap to 4/8/12/16. |
| 7 | MOT-6 (P2) | `DevicePromptView.swift:135-137` | Empty history is a bare tertiary "No requests yet." | `ContentUnavailableView` with a symbol and a next-action hint. |
| 8 | MOT-1 (P2) | `DeviceGalleryView.swift:265-270` | Stage ↔ Agent segment swap is a hard cut. | Context transition: `.transition(.opacity)` + 150ms ease-out on `segment`. |
| 9 | LAY-1 (P2) | `DeviceStageView.swift:11-17` | Stage list is its own grouped card + separators for three rows. | Same plain-row treatment as the request list; empty state handled once in the inspector. |

## P1 detail

**1 — Whitespace over containers / borders.** `Form { … }.formStyle(.grouped)`
on macOS draws a filled rounded card per Section and a separator between
rows. Zander: borders make the eye see the border, not the content. Fix is
a `ScrollView { LazyVStack }` with 16pt horizontal / 12pt vertical row
padding and no separators; the composer keeps its `.bar` background and top
`Divider` because it is a fixed, functionally distinct region.
Sources: [2084623671444799847](https://x.com/zander_supafast/status/2084623671444799847),
[2080000671781110136](https://x.com/zander_supafast/status/2080000671781110136).

**2 — Less content, stronger hierarchy.** The header card carries no
information the gallery card doesn't; the only thing the pane needs is *which*
phone. A single `headline` line with a status dot answers that in 20pt instead
of a 64pt card. Source: [2053925539019165904](https://x.com/zander_supafast/status/2053925539019165904).

**3 — Visual anchoring.** Uber's ride list: a consistent leading glyph column
lets the user recognize shape before reading. Failed / needs-input / done are
exactly the states a user scans for. Red is reserved for `failed` (the moment
it's a signal — COL-4); orange for `needsInput`; green for `completed`;
secondary for `sent`/`cancelled`. Source:
[1996927463679529069](https://x.com/zander_supafast/status/1996927463679529069),
[1988234478452359457](https://x.com/zander_supafast/status/1988234478452359457).

**4 — Button tiers.** Primary: Run. Secondary: planner popup (neutral
bordered). Tertiary: examples, as a borderless `lightbulb` icon with a
tooltip — a first-run helper shouldn't share visual weight with the planner.
Source: [1802684455670136954](https://x.com/zander_supafast/status/1802684455670136954).

## Systemic recommendations

- **Stop using `.formStyle(.grouped)` for lists in the inspector.** It's the
  source of findings 1, 2 and 9 at once. Keep grouped forms for the settings
  sheet (`DeviceDetailView`), where key/value sections are what the style is
  for.
- **Status vocabulary lives in one place.** `DevicePromptStatus` should own
  its symbol and color (alongside `displayName`) so the history row, any
  future toolbar badge, and the gallery card agree. Applied as private
  helpers in `DevicePromptHistory` for now; promote to the enum if a second
  consumer appears.
- **Spacing scale: 4 / 8 / 12 / 16.** Inspector rows use 16/12; intra-row
  4; control rows 8.

## Outside catalog (reviewer judgment)

- The privacy/planner caption above the composer is two lines, always on.
  It's a real disclosure (the Grok variant tells the user screenshots leave
  the Mac), so it stays — but it's the heaviest text in the footer. Consider
  showing it only when the provider changes or as the picker's popover.
- `DeviceScreenCard` (gallery) shares the off-grid values (`spacing: 5`,
  `7×7` dot, `Color.black.opacity(0.18)` literal) — out of scope here.
- `.menuStyle(.borderlessButton)` is deprecated on macOS 14+; the gallery
  card still uses it.

## Verified clean

TYPE-1 (only single-line centering), TYPE-2, TYPE-4 (all semantic text
styles), COL-1/COL-2/COL-3 (system semantic colors, parity in both modes —
`inspector-light-before.png`), FORM-2 (placeholder is a bare example),
MODAL-1 (no confirmations in scope), BTN-2 (verb labels). FORM-1 is a
chat-composer pattern (Messages/Mail have no visible label); accessibility
label present — accepted as platform convention rather than flagged P0.

## Applied

All nine findings were applied in this pass and verified in a Release build
(`bun shortreel`). After-captures: `design-review/inspector-dark-after.png`
(Agent, empty history) and `design-review/inspector-stage-dark-after.png`.
Request sessions are in-memory, so the relaunch cleared the history; the
populated row layout (glyph column + prompt + secondary line) was not
screenshotted to avoid driving the connected phones.
