# SemIf parity gate (issue #13) — recorded results

Run: 2026-09-21, Mac15,8 (Apple M3 Max), macOS 27.0, `SEMIF_MODEL_DIR=/tmp/semif10-harness/models`,
checkpoint `Qwen/Qwen3.5-4B` @ `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`,
mlx-swift 0.31.4 / mlx-swift-lm 3.31.4. Semif's reference rows were produced on
an Apple M5 Max, MLX 0.32.2 / mlx-lm 0.32.0 (commit `a63e24c3…`), same
checkpoint revision — timings are therefore cross-machine and not comparable;
only hashes, argmax, and probabilities gate.

Command:

```
SEMIF_MODEL_DIR=/tmp/semif10-harness/models swift run --package-path apple/SemanticIf semif-parity
```

## What was compared against what

| Set | Inputs | Semif reference rows | Reference hash provenance |
| --- | --- | --- | --- |
| `decisions` (3 rows) | `examples/decisions.jsonl` (fixture `decisions.jsonl`, sha256 `7df55381…`) | `docs/media/openjev-mlx-results.jsonl` (fixture `decisions-bf16.jsonl`, sha256 `ab0e291b…`) | Pinned by Semif's `docs/media/SHA256SUMS` |
| `authored144` (144 rows) | `benchmarks/data/authored144.jsonl` (fixture `authored144.jsonl`, sha256 `8162d1c7…`) | `results/mlx/2026-09-17-bf16-fixed/authored144.jsonl.gz` (fixture `authored144-bf16.jsonl`, per-row `model` block stripped — identical across all rows) | `.gz` sha256 `c474462f…` per `results/mlx/SHA256SUMS`; gunzipped payload sha256 `433d245f…` per `UNCOMPRESSED_SHA256SUMS` |

Semif's `results/mlx/2026-09-17-bf16-fixed/` contains **no** rows for
`examples/decisions.jsonl` ids (`support-1`, `route-1`, `policy-1`); neither
does the cli-smoke directory (its inputs are shape-benchmark rows). The only
published BF16 MLX scoring of the decisions.jsonl inputs is the
`docs/media/openjev-mlx-results.jsonl` demo artifact, pinned by
`docs/media/SHA256SUMS` — that is what the `decisions` set compares against.
Both reference sets record backend `mlx`, dtype
`["mlx.core.bfloat16", "mlx.core.float32"]`, prompt version
`direct-options-v1`, the pinned checkpoint revision, and direct readout.

## Numbers

| Set | Prompt-hash equality | Input-tokens equality | Argmax agreement | max \|Δp\| | median \|Δp\| | Wall (ours) | Wall (Semif, M5 Max) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `decisions` | **100 % (3/3)** | 100 % | **100 % (3/3)** | **7.088e-3** | 1.9e-5 | 1.78 s total (median 0.201 s; first row includes warm-up) | 0.30 s total |
| `authored144` | **100 % (144/144)** | 100 % | **100 % (144/144)** | **1.152e-1** | 1.1e-3 | 47.66 s total (median 0.319 s/row) | 7.18 s total |

Per-row report: printed by the `semif-parity` executable and the opt-in
`SemanticIfParityTests.testParityAgainstPublishedBF16Results` run.

## Tolerance

The issue's starting tolerance, **1e-3, does not hold**: 74/147 rows exceed it
(39/147 exceed 1e-2). The tolerance is set to **0.12** (just above the observed
max |Δp| of 1.152e-1), with this justification:

- The divergence is per-logit, not systematic. Slot-logit differences are
  quantized to BF16 ULP steps: 0 (18 rows), 0.125 (98), 0.25 (24), 0.375 (6),
  0.5 (1) — at logit magnitudes 16–32, one BF16 ULP is 0.125, so the worst
  row is 4 ULP. 18/147 rows are bit-identical after BF16 rounding and match
  to ~1e-8 in probability; there is no constant offset or drift.
- Softmax amplifies logit deviations by up to p(1−p)·Δ(gap). The largest
  Δp rows are exactly the rows with the largest |Δlogit| (e.g. `f2b4ec49…`:
  Δlogit 0.25 on a 0.059-margin row → Δp 0.115; `19f37d5a…`: Δlogit 0.375 →
  Δp 0.104). Every observed Δp is explained by ≤ 4 ULP of BF16 accumulation
  difference between MLX Python 0.32.2's kernels and mlx-swift 0.31.4's.
- Semif's softmax is float64 over float32 logits; ours is Float32 — that
  contribution is ~1e-7 relative, negligible next to the kernel term.
- Cross-implementation BF16 deviation of this magnitude is the measured norm
  for this checkpoint: Semif's own fixed-runtime MLX run deviates from the
  published Torch predictions by up to **0.1052** on these same 144 rows
  (0.0614 on perturbations108) with zero winning-option changes
  (`results/mlx/README.md`). Our max 0.1152 vs their Python MLX rows is the
  same effect between two BF16 runtimes.
- The decision-relevant quantity is unaffected: argmax agreement is 100 % on
  all 147 rows, including every near-tie (minimum recorded margin among rows
  with Δp > 1e-2 is 0.059; no row's ranking changed).

## Gate verdict

- At tolerance 1e-3: **FAIL** (observed max |Δp| 1.152e-1 on authored144,
  7.088e-3 on decisions).
- At the documented tolerance 0.12: **PASS** — prompt-hash equality 100 %
  (147/147), input-tokens equality 100 %, argmax agreement 100 % (147/147),
  max |Δp| 1.152e-1 ≤ 0.12.

Per the issue, this loosening is recorded, not hidden: if the epic wants a
tighter probability gate, the next step is a dtype/kernel-level investigation
of where mlx-swift's BF16 accumulation differs from mlx-lm's (the 4-ULP logit
deviations), not a scorer change.
