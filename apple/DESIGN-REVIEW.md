# Design Review — Stage Inspector

Scope: the inspector's **Stage** segment (`DeviceStageView.swift`) plus the
chrome it inherits from `DevicePromptInspector` / `DeviceInspectorHeader` in
`DeviceGalleryView.swift:344-433`, and the two sheets it opens (Warm Up,
Create Content). SwiftUI/macOS, so the catalog's React greps were adapted
(`.buttonStyle` ≈ variant, `Form`/`.formStyle(.grouped)` ≈ Card, `prompt:` ≈
placeholder, `.frame(width:height:)` ≈ fixed layout width).

Screenshots in `design-review/`: `stage-inspector-dark.png`,
`stage-inspector-light.png`, `stage-warmup-sheet.png`. The Create Content
sheet was reviewed from code; it is structurally identical to Warm Up.

The previous inspector review's Stage findings (grouped card, separators,
segment hard-cut) are resolved — the list is now plain rows, and the
segment swap has a 150 ms ease-out. This review starts from that baseline.

## Verdict

The Stage panel's biggest lever is **state and hierarchy in the pipeline
list**. The three rows are a sequence (clean → warm up → create), but they
render as three identical rows with three identical 40 pt play circles —
nothing is primary, nothing says what has run, and the last result is
detached from its row in a text block below. Make the *next* stage the one
prominent button, put each stage's last outcome on its own row, and the
panel reads as a pipeline instead of a menu. Everything else is polish.

## Findings

| # | Check | Where | Finding | Fix |
|---|---|---|---|---|
| 1 | HIER-1 / BTN-1 (P1) | `DeviceStageView.swift:26-49`, `stage-inspector-dark.png` | Three rows, same weight, same neutral button; no per-stage state. The header comment says cleanup is "the primary action" but nothing in the UI is primary. Last result renders as a separate block (`:59-80`), away from its row. | One `.borderedProminent` play on the next stage; `.bordered` on the rest. Leading glyph shows the stage's last outcome (done / failed / needs input) instead of only its number. Move the one-line status under the row title. |
| 2 | FORM-2 (P1) | `DeviceStageView.swift:236` | Niche placeholder is `"What this persona browses, e.g. street photography"`. | `prompt: Text("Street photography")` — a bare example; the field already has a persistent "Niche" label. |
| 3 | LAY-6 (P2) | `DeviceStageView.swift:274, 355`, `stage-warmup-sheet.png` | Sheets are hard-sized `540 × 660`. In a 765 pt window the sheet is clipped and the **Session** section — including the required Niche field — sits below the fold, while the footer says "stops at the limit above". | Fixed width only; let height follow content with a cap: `.frame(width: 540).frame(minHeight: 440, maxHeight: 660)` and drop the fixed 660. |
| 4 | HIER-2 (P2) | `DeviceStageView.swift:195-202`, `stage-warmup-sheet.png` | When a persona is chosen the Platform segmented control is disabled but still shows four options — four dead segments to explain one fact. | When locked, render `LabeledContent("Platform", value: warmUp.platform.displayName)`; show the picker only when no persona is selected. |
| 5 | IMG-2 (P2) | `DeviceStageView.swift:36-44` | Play buttons are `.controlSize(.large)` 40 pt circles; the leading number glyphs are body-size. The action column, not the anchor column, is what the eye lands on. | `.controlSize(.regular)` (28 pt) on the non-primary rows; keep `.large` only on the prominent one from #1. |
| 6 | IMG-1 (P2) | `DeviceStageView.swift:213, 314` | Section headers mix styles: "Phase" and "Slideshow" carry a symbol, "Agent profile", "Session", "Content", "Details" don't. | Drop the two symbols — plain `Section("Phase")` — so one header style applies. |
| 7 | LAY-3 (P2) | `DeviceStageView.swift:27` (`spacing: 10`), `:157, 296` (`spacing: 6`) | Off-grid one-offs. | 8 and 8 (or 4 for the title/subtitle pair). |
| 8 | MOT-6 (P2) | `DeviceStageView.swift:52-57`, validation captions `:247, 351` | Unavailable / validation states are bare secondary captions. | `Label(reason, systemImage: "exclamationmark.triangle")` in the footer; in the list, a `ContentUnavailableView` when the phone is gone. |

Verified clean: TYPE-1..4 (system text styles, no centering, no caps),
LAY-1/2/4/5 (plain rows, no borders, sane grouping), COL-1..6 (system
semantic colors only; dark/light parity confirmed in both screenshots; green
reserved for the connection glyph), BTN-2..5 (verb labels "Run on SR1",
"Create Draft", "Stop", "Cancel"; system button states), FORM-1/3/4 (grouped
Form rows carry persistent labels), MODAL-1/2 and MOT-1..4 (system sheet,
150 ms opacity context transition on the segment), HIER-3..6, IMG-3.

## P1 detail

**1 — Hierarchy from state, one primary.** HIER-1: "size and color create
in-group hierarchy; metrics sit in tight proximity to their subject." BTN-1:
one primary per view. The panel has neither. The session already knows each
workflow's last entry (`session.entries` carries `workflow` and `status`), so
the row can own its outcome and the panel can decide which stage is next.

```swift
// DeviceStageView.body — replace the ForEach row
let last = Dictionary(grouping: session.entries.filter { $0.workflow != nil },
                      by: { $0.workflow! }).compactMapValues(\.last)
let next = DeviceWorkflow.allCases.first { last[$0]?.status != .completed } ?? .createContent

ForEach(Array(DeviceWorkflow.allCases.enumerated()), id: \.element.id) { index, workflow in
    let entry = last[workflow]
    HStack(spacing: 8) {
        stageGlyph(index: index, status: entry?.status)
            .frame(width: 20)
        VStack(alignment: .leading, spacing: 4) {
            Text(workflow.title)
            if let entry {
                Text(entry.status.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Button { … } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(workflow == next ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
        .buttonBorderShape(.circle)
        .accessibilityLabel("Run \(workflow.title) on \(device.name)")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
}

@ViewBuilder
private func stageGlyph(index: Int, status: DevicePromptStatus?) -> some View {
    switch status {
    case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .needsInput: Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
    default:         Image(systemName: "\(index + 1).circle")
    }
}
```

(`AnyButtonStyle` is a small type-eraser, or use two `if` branches. Status
colors follow the vocabulary the Agent history already uses, so red stays
reserved for `failed` — COL-4.) The running-state block at `:59-80` then
shrinks to the Stop button plus the current step line, since the title and
status now live on the row.
Sources: [1802939950645584131](https://x.com/zander_supafast/status/1802939950645584131),
[1802684455670136954](https://x.com/zander_supafast/status/1802684455670136954).

**2 — No "e.g." in placeholders.** "e.g." isn't recognized across languages
and reads badly through VoiceOver ("enter e g street photography"). The Form
row already shows "Niche" as a persistent label, so the placeholder's only job
is an example.

```diff
- TextField("Niche", text: $warmUp.niche,
-           prompt: Text("What this persona browses, e.g. street photography"))
+ TextField("Niche", text: $warmUp.niche, prompt: Text("Street photography"))
```

Source: [1879858975426122119](https://x.com/zander_supafast/status/1879858975426122119).

## Systemic recommendations

- **Give `DevicePromptStatus` its symbol and color.** The prior review put
  status glyph/color helpers privately in `DevicePromptHistory`. Finding #1
  is the second consumer; promote them onto the enum so the Agent list, the
  Stage rows, and any future gallery badge agree by construction.
- **One sheet scaffold.** `warmUpConfiguration` and `contentConfiguration`
  duplicate the title block, grouped Form, Divider, caption, validation line,
  and Cancel/primary footer. A `WorkflowSheet(title:subtitle:caption:reason:primary:)`
  wrapper fixes #3 (sizing), #6 (header style), #7 (spacing), and #8
  (validation presentation) in one place and keeps the next workflow's sheet
  consistent for free.
- **Spacing scale stays 4 / 8 / 12 / 16 / 24.** The sheets already use 24
  for their outer padding and 12 for the footer; the two `6`s and the `10`
  are the only stragglers.

## Outside catalog (reviewer judgment)

- **Row 1 runs on the phone immediately; rows 2 and 3 open a form.** The
  three buttons look identical, so the first click on "Clear Home Screen"
  rearranges a real iPhone's Home Screen with no configuration step and no
  confirmation. The catalog's MODAL-1 covers *how* to confirm, not *whether*;
  I'd still treat this as the panel's most consequential inconsistency. Either
  give cleanup a small sheet with the same footer pattern (Cancel / "Clear
  Home Screen on SR1"), or make its button visually distinct from the two
  that open forms. If #1 lands, the prominent-button-is-next convention at
  least means a first-time user's default click is the intended one.
- The persona narrative in the Warm Up sheet renders as a four-line caption
  block inside the form (`:186-190`, `lineLimit(3)` isn't holding it to
  three at this width). Two lines with a disclosure, or the first sentence
  only, would keep the form scannable.
