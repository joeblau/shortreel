# SemIf shared mode (issue #17) — recorded results

Run: 2026-09-21, Mac15,8 (Apple M3 Max), macOS 27.0, `SEMIF_MODEL_DIR=/tmp/semif10-harness/models`,
checkpoint `Qwen/Qwen3.5-4B` @ `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a`,
mlx-swift 0.31.4 / mlx-swift-lm 3.31.4.

Command:

```
SEMIF_MODEL_DIR=/tmp/semif10-harness/models swift test --package-path apple/SemanticIf \
  --filter testSharedMatchesDirectOnPinnedCheckpoint
```

## What was compared

Shared mode (`SemanticIfModel.scoreShared`) prefills the shared state into a
KV cache once, deep-copies the cache per criterion, and forwards only the
suffix tokens (Semif's `shared.py` MPS path: "prefill once, then independent
batch-1 suffixes"). Direct mode (`SemanticIfModel.score`) runs one full
forward per row. This is the cache-correctness check of Semif's
`docs/MLX.md` "Cache correctness" section: shared results must equal direct
results for the same rows.

Two batches, each 4 criteria over one exact shared state:

| Batch | State | Prefix tokens | Suffix tokens (total) |
| --- | --- | --- | --- |
| `shared-decisions.jsonl` fixture | the `support-1` state from `examples/decisions.jsonl` | 65 | 299 |
| Long-state batch (built in the test) | 80-line synthetic deploy log, same 4 criteria | 3481 | 299 |

## Correctness (shared vs direct, same process, same checkpoint)

| Batch | Argmax agreement | max \|Δp\| | Tolerance |
| --- | --- | --- | --- |
| Fixture (4 rows) | **100 % (4/4)** | **2.899e-4** | 0.12 (parity gate) |
| Long state (4 rows) | **100 % (4/4)** | **6.163e-4** | 0.12 (parity gate) |

Per-row (fixture): `shared-success` 0.000e+00, `shared-rollback` 2.899e-4,
`shared-health` 0.000e+00, `shared-time` 0.000e+00. Prompt hashes and input
token counts are identical between shared and direct for every row (the split
is proven exact: prefix + suffix == full prompt).

Cross-check against Semif's published BF16 direct-mode rows: fixture row
`shared-success` repeats `examples/decisions.jsonl`'s `support-1` verbatim, and
its shared-mode result matches the published row in
`docs/media/openjev-mlx-results.jsonl` (fixture `decisions-bf16.jsonl`) with
identical prompt hash, identical argmax (`yes`), and max |Δp| **1.861e-5**.

## Measured speedup (prefill once vs N full forwards)

| Batch | Direct (4 full forwards) | Shared (1 prefill + 4 suffixes) | Speedup |
| --- | --- | --- | --- |
| Fixture | 2.550 s | 2.078 s (encode 0.056, prefill 0.371, replicate 0.008, suffixes 1.627) | **1.23x** |
| Long state | 46.879 s | 10.709 s (encode 0.572, prefill 9.001, replicate 0.004, suffixes 1.110) | **4.38x** |

The speedup scales with the shared-state size, as expected: with a 65-token
prefix the criterion/options suffix dominates each prompt and the win is
modest; with a 3481-token prefix the state is prefilled once instead of four
times and the suffixes are ~75 tokens each. Cache deep-copies (replicate) are
negligible (<10 ms total in both batches).
