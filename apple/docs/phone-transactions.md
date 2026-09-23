# Phone transactions

Agent and Stage converge in `DevicePromptSession` and run through
`PhoneVisualRunner`. The model-chosen next-action loop is removed.

TikTok Watch uses the reviewed graph in `Contracts/tiktok-watch.json`. The provider
only extracts the frozen one- or two-word niche query. After exact account checking,
the graph opens Search, types the query, chooses a top-three suggestion, selects
Videos, opens candidates, watches, and swipes once between completed items.
Laya receives concise UI evidence separately from captions, OCR, and counters.
Swift verifies query-field OCR, the strict >10,000 heart threshold, playback
continuity, item counts, and changed creator/caption after each swipe. The graph's
declared recovery branches replace the separate whole-phase failure classifier
for this flow; phase budgets, fresh-frame checks, and account guards remain.
Visible progress-bar observations can prove replay when numeric timers are hidden.
They require stable creator/caption and forward progress to the end before a reset;
elapsed time alone never counts. Two consistent measured progress intervals may
establish an overlong video; a readable duration takes precedence.

1. Simple app-opening requests use a built-in `PhoneTransactionPlan`, including
   empty Home Screens and unlabeled Dock icons. Other requests use Codex or Claude
   to compile the program without device tools. Warm-up compiles at most three
   phases concurrently for other warm-up flows, reports progress, and assembles them in registered order.
   Validation rejects unknown destinations, duplicate IDs, unreachable states,
   states without terminal exits, unsupported commands, and invalid budgets.
   Warm-up phases must exactly match the registered script.
   Warm-up's account phase is built in for every supported network: it reuses
   the app-opening graph, opens the profile, and uses the Laya account check plus
   exact OCR handle matching. Codex cannot regenerate these navigation steps.
2. The immutable program is journaled before input. States declare visible
   conditions, fixed commands, postconditions, and named destinations. Typed text
   is literal. A visual locator resolves coordinates from the current screen;
   it receives no execution history and cannot choose operations or completion.
3. Laya scores current OCR and factual screen inspection against the declared
   conditions. The selected branch authorizes its fixed command. A checkpoint
   records phase, state, branch, visit counts, and resolved input before dispatch.
   A failed write prevents input.
   Built-in branches and states also declare required screen surfaces. Spotlight
   typing requires a fresh Spotlight observation, and opening Search must be
   verified as Spotlight before the query state is entered. A classifier choice
   cannot override these preconditions or the required post-input surface.
   Classification retains every saved branch as an alternative; surface guards
   reject incompatible selections afterward. Filtering alternatives before
   scoring made clear Home Screen observations classify as unknown. Home's
   condition asks only for the screen itself, without requiring wallpaper details.
4. A fresh frame verifies the declared result. Verification gets at most three
   observations and never resends the command. State, phase, run, and time budgets
   bound all loops. Source changes, stale frames, disconnection, and cancellation
   stop execution. Late model callbacks cannot dispatch.
5. Restarting the app clears prior conversation history and queued requests.
   Interrupted Watch navigation does not leave a restart review gate. Other
   uncertain input leaves only a review flag; a new Watch can still start from
   fresh screen evidence, but other requests require review. Acknowledgement
   starts eligible queued work without a second Resume click. Reconnecting within the same app
   launch keeps the current conversation. Interrupted runs never auto-resume.

Preparation has its own bounded deadline and does not consume the user's viewing
time. ShortReel captures the full phone JPEG over USB, Codex or Claude describes
the visible screen, and Laya evaluates that evidence and local OCR. The visual
observer receives the current state's specific visual question (or the command's
postcondition) and returns facts without selecting an action. Classifier evidence
excludes diagnostic enum names, irrelevant screen metadata, and empty OCR sections.
The visual model
then locates the fixed command's target. Every subsequent observation uses
a fresh capture. History shows the observed evidence and matched condition.

Warm-up keeps registered phase order, exact account matching, completion counts,
contract budgets, and single-submit checkpoints. Video completion requires a
locally measured replay with stable creator/caption anchors plus classification.
Duration skips require a readable over-limit timer. Failure IDs select equally
named saved recovery branches within fixed attempt limits. Missing recoveries and
terminal failures stop. Submission verification cannot contain commands.

Cleanup retains the removal guard and requires a fresh two-direction page sweep
after the last edit, finishing on Home. Content creation retains submission guards
and draft-only compilation instructions. Test App Switcher remains a fixed
command followed by a fresh inspection.

Codex and Claude support workflow compilation. UI-TARS and Apple Intelligence
currently cannot compile this structured program; Agent and Stage ask users to
choose Codex or Claude before sending input. Their diagnostic adapters remain.
Laya must load successfully; there is no preference or error fallback that
bypasses classification.

Execution is deterministic for a saved program and a sequence of classifications.
Compilation and perception still use ML: the same natural-language request can
produce a different plan, and perception can be wrong. A changed request starts a
new transaction rather than changing a running graph. The automated suite does
not exercise a live phone.

Run `apple/Tests/run-transactions.sh` for runner, queue/journal, and Stage tests.
Run `swift test --package-path apple/SemanticIf` for classifier tests. Set
`SHORTREEL_LAYA_MODEL_DIR` to include native inference and transaction fixtures.
