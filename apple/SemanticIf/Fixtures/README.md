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
`apple/ShortReel/Services/DevicePrompts/SemanticIfPrompt.swift`). The parity
harness (issue #13) replays these rows and compares prompt hashes and
answer-slot probabilities against Semif's recorded MLX runs.
