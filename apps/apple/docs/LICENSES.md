# Third-party licenses (Rishi for Apple)

This document tracks the licensing attribution for third-party assets and
source vendored into `apps/apple/`. SwiftPM dependencies (Sentry, Readium,
USearch, swift-realtime-openai, ...) carry their own LICENSE files in the
SwiftPM checkout — they are not duplicated here. This file covers artifacts
that are checked into the repo directly.

## Phase 25 RAG — vendored models and tokenizers

### AllMiniLML6V2.mlmodel (Apache-2.0)

- Path: `apps/apple/Packages/RishiSearch/Sources/RishiSearch/Resources/AllMiniLML6V2.mlmodel`
- Source: Generated from `sentence-transformers/all-MiniLM-L6-v2` via
  `convert_minilm_to_coreml.py` from
  https://github.com/Abhishek6353/AllMiniLML6V2-coreml. The model file
  bundled here matches the `main` branch of that repo as of 2026-06-14.
- License: Apache License 2.0 (Hugging Face model card:
  https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2).
- Full attribution text:
  `apps/apple/Packages/RishiSearch/Sources/RishiSearch/Resources/LICENSE-AllMiniLML6V2.txt`
- Model contract: input `(input_ids, attention_mask)` int32 tensors of
  shape `[1, 64]`; output `var_570` is a single 384-dim L2-normalized
  embedding (pooling + normalization baked into the model graph).

### vocab.txt (Apache-2.0)

- Path: `apps/apple/Packages/RishiSearch/Sources/RishiSearch/Resources/vocab.txt`
- Source: BERT base uncased WordPiece vocabulary (30,522 lines) downloaded
  from `https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/raw/main/vocab.txt`.
- License: Apache License 2.0 (same as the model above).

### MiniLMTokenizer.swift (MIT)

- Path: `apps/apple/Packages/RishiSearch/Sources/RishiSearch/Embedder/MiniLMTokenizer.swift`
- Source: Ported from `Sources/Utils/MiniLMTokenizer.swift` in
  https://github.com/Abhishek6353/AllMiniLML6V2-coreml with local
  adaptations described in the file header and in
  `Resources/LICENSE-AllMiniLML6V2.txt`.
- License: MIT (code only; the original tokenizer code does not bundle
  any vocabulary or model weights). Full copyright notice preserved in
  `Resources/LICENSE-AllMiniLML6V2.txt`.

---

_Last updated: 2026-06-14 — Phase 25 Plan 04 (Core ML embedder + tokenizer
vendoring)._
