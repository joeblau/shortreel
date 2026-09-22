> Historical Qwen/MLX fixtures. The runtime and parity executable have been retired.
> Current Laya validation is documented in [../README.md](../README.md).

# SemanticIf fixtures

`decisions.jsonl` is a verbatim copy of `examples/decisions.jsonl` from
[TheoLeeCJ/SemIf](https://github.com/TheoLeeCJ/SemIf) (branch `master`,
retrieved 2026-09-21), reproduced under the MIT License:

> MIT License
>
> Copyright (c) 2026 TheoLeeCJ
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
> SOFTWARE.

Each line is one decision row (`id`, `state`, `question`, `options`) in the
shape consumed by `SemanticIfPrompt` (see
`apple/SemanticIf/Sources/SemanticIf/SemanticIfPrompt.swift`). The parity
harness (issue #13) replays these rows and compares prompt hashes and
answer-slot probabilities against Semif's recorded MLX runs.

## Parity fixtures (issue #13)

All files below are from [TheoLeeCJ/SemIf](https://github.com/TheoLeeCJ/SemIf)
(branch `master`, retrieved 2026-09-21), reproduced under the MIT License
quoted above. `SHA256SUMS` in this directory pins each file's bytes; the
harness verifies the pins before scoring, and the mapping back to Semif's own
published checksum files is recorded here so anyone can re-derive the fixtures
from the upstream repo.

| File | Provenance | Verification |
| --- | --- | --- |
| `decisions.jsonl` | Verbatim copy of `examples/decisions.jsonl`. | sha256 `7df55381…` (also asserted by the #9 tests). |
| `decisions-bf16.jsonl` | Verbatim copy of `docs/media/openjev-mlx-results.jsonl`: Semif's BF16 MLX scoring of the three `decisions.jsonl` rows on the pinned checkpoint. Semif's `results/mlx/2026-09-17-*` directories contain **no** decisions.jsonl rows (their cli-smoke inputs are shape-benchmark rows); this media artifact is the only published BF16 scoring of these inputs. | sha256 `ab0e291b…` equals the entry in Semif's `docs/media/SHA256SUMS` (`shasum -a 256 -c SHA256SUMS` passes in that directory). |
| `authored144.jsonl` | Verbatim copy of `benchmarks/data/authored144.jsonl` (144 input rows, same `id`/`state`/`question`/`options` shape; benchmark metadata fields are ignored by the scorer). | sha256 `8162d1c7…`. |
| `authored144-bf16.jsonl` | Derived from `results/mlx/2026-09-17-bf16-fixed/authored144.jsonl.gz`: gunzipped, then the per-row `model` metadata block — verified byte-identical across all 144 rows — was removed to keep the fixture small. All compared fields (`id`, `option_ids`, `probabilities`, `option_logits`, `answer_token_ids`, `input_tokens`, `input_ids_sha256`, `prompt_sha256`, `prompt_version`, `readout`, `probability_status`, `forward_seconds`, `total_seconds`) are preserved verbatim. The shared model block records `Qwen/Qwen3.5-4B` @ `851bf6e8…`, backend `mlx`, dtype `["mlx.core.bfloat16", "mlx.core.float32"]`, mlx 0.32.2 / mlx-lm 0.32.0 (commit `a63e24c3…`, the pinned normalization fix), transformers 5.17.0, `mlx-direct-v1`, 256 MiB allocator cache limit. | Stored `.gz` bytes: sha256 `c474462f…` per Semif's `results/mlx/SHA256SUMS`. Gunzipped payload before stripping: sha256 `433d245f…` per Semif's `results/mlx/UNCOMPRESSED_SHA256SUMS`. Reproduce with: `gzip -dc authored144.jsonl.gz \| python3 -c 'import json,sys; [print(json.dumps({k: r[k] for k in ("id","option_ids","probabilities","option_logits","answer_token_ids","input_tokens","input_ids_sha256","prompt_sha256","prompt_version","readout","probability_status","forward_seconds","total_seconds")}, ensure_ascii=False)) for r in map(json.loads, sys.stdin)]'`. |

Observed parity numbers (the gate result) are recorded in `PARITY.md` in this
directory.

## Shared-mode fixture (issue #17)

`shared-decisions.jsonl` holds four decision rows that share one exact state
(the `support-1` row's state from `decisions.jsonl`) with four different
criteria — the multi-criterion shape Semif's `shared` mode serves ("prefill
once, then independent batch-1 suffixes"). Row `shared-success` repeats
`support-1`'s question and options verbatim, so its prompt hash and scores can
also be compared 1:1 against Semif's published direct-mode row for `support-1`
in `decisions-bf16.jsonl`. Observed shared-vs-direct numbers and the measured
speedup are recorded in `SHARED.md` in this directory.
