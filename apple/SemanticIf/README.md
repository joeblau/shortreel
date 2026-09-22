# Laya Core ML classifier

ShortReel runs the [Laya Core ML](https://github.com/mizorewww/laya-coreml)
multilingual classifier directly in Swift. `SemanticIfScoring` remains the
interface used by the warm-up runner; its name is retained for compatibility.
The Qwen/MLX backend, shared-prefix scorer, Metal warm-up, and old parity
executable have been removed. There is no Python service, Python runtime,
MLX dependency, or CUDA build plugin in the app.

## Model and runtime

- Model: `aac6fef/laya-multilingual-coreml`.
- Revision: `8139e9089273319512c730218903784074133187`.
- Runtime contract: laya-coreml revision `4619e0483f07adf39068532e85b42ec2347edb83`.
- Native `CoreML` with CPU + GPU, FP16 weights, 1,024-token capacity and
  enumerated input shapes. The separate 96-token ANE model is too small for
  the full warm-up criteria and OCR evidence.
- Swift Transformers 1.3.4 supplies tokenization and model downloads only.
- First load downloads about 680 MB and compiles the model. Assets and compiled
  output stay in `~/Library/Application Support/ShortReel/laya-coreml/<revision>/`.
  Subsequent loads use the verified cache without a network request.
- `SHORTREEL_LAYA_MODEL_DIR` can point to an already downloaded, pinned bundle.
  Asset sizes and SHA-256 checksums are verified before inference. A missing or
  damaged asset produces a load error, surfaced in the Agent menu.

The choice adapter ports upstream prompt construction, mask-marker placement,
shape padding, temperature buckets and softmax. Temperatures are clamped to
`[0.5, 5]` as in the linked upstream revision. Oversized **evidence** throws
instead of being silently truncated. Question/option budgets follow upstream.
The existing caller falls back to its screenshot planner on inference errors.

The existing 0.12 top-two probability margin is retained as a routing policy;
it is not a measured accuracy guarantee for the new model. Diagnostics identify
`laya-coreml-choice-v1` and hash the model revision plus encoded input. The
legacy `peakMemoryBytes` field is zero because GPU peak allocation is not
reported by this adapter.

## Account and failure-mode decisions

Laya classifies the account screen as `profile`, `signed-out`, or `unknown`.
Swift then compares the expected username exactly, ignoring case and a leading
`@`, using OCR with confidence at least 0.6. Conflicting handles, no handle,
an unknown screen, or an uncertain classification produce `unreadable`.
A sign-in classification takes precedence over any visible username.

This division is deliberate: direct four-way account questions performed poorly
with both the multilingual and specialized typed-decision checkpoints. The
surface classifier plus exact identifier check passes all 16 existing account
fixtures. Its probabilities describe screen type, not username equality.

Other warm-up steps ask Laya which contract failure mode is supported, preserving
all option IDs and recovery branches. Success criteria are context. Uncertain
failure classifications remain with the screenshot planner. Live phone behavior
and general task accuracy are not established by the fixture tests.

## Validation

Fast tests use checked-in reference vectors:

```sh
swift test --package-path apple/SemanticIf
```

For real native tokenization, inference parity, and all account fixtures:

```sh
hf download aac6fef/laya-multilingual-coreml \
  --revision 8139e9089273319512c730218903784074133187 \
  --local-dir apple/.build/laya-multilingual-coreml
SHORTREEL_LAYA_MODEL_DIR="$PWD/apple/.build/laya-multilingual-coreml" \
  swift test --package-path apple/SemanticIf
```

The reference cases cover Unicode, literal mask tokens, prefix budgeting,
account screens, token IDs, marker positions, calibrated probabilities, and
output selection. The native probability tolerance is 0.002. Additional tests
reject oversized evidence, invalid options, and invalid numerical results.
Standalone account and visual-runner suites in `apple/Tests` exercise confidence,
exact identity checks, and recovery behavior.

The `scripts/` directory is not shipped with the app. To regenerate upstream reference vectors,
use the development-only Python script with the pinned upstream checkout:

```sh
uv venv --python 3.12 /tmp/shortreel-laya-reference
uv pip install --python /tmp/shortreel-laya-reference/bin/python \
  'laya-coreml @ git+https://github.com/mizorewww/laya-coreml@4619e0483f07adf39068532e85b42ec2347edb83'
/tmp/shortreel-laya-reference/bin/python apple/SemanticIf/scripts/laya_reference.py \
  apple/.build/laya-multilingual-coreml
```

The old `Fixtures/` directory and pure Semif prompt tests are historical records;
they do not establish parity or accuracy for Laya. Current reference vectors live
in `Tests/SemanticIfTests/Fixtures/`. Attribution is in `apple/ThirdParty/laya-coreml`.
