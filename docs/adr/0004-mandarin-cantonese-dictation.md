---
status: proposed
---

# Mandarin and Cantonese dictation (zh: cmn + yue → zh-Hans)

[ADR-0002](0002-no-one-model-dictation-engine.md) closed the language question with
"English-only stands": the #176 map had reopened language scope only to evaluate a
one-model dictation engine without a translation requirement, and with that approach
rejected, English-only held. That position carried its own escape hatch — *"unless
revisited on its own"*. This ADR is that revisit: the product now targets Chinese
speakers, scoped as **two spoken varieties, one written script**.

**Decision: OpenStream adds a Chinese (`zh`) dictation profile on top of the English
baseline. Spoken Mandarin (普通话, `cmn`) and Cantonese (广东话, `yue`) are
transcribed, rules-cleaned, and delivered as written Simplified Chinese (`zh-Hans`).**

Scope, from [`docs/planning/requirements.md`](../planning/requirements.md) §5 (the
normative spec; this ADR records the decision and its consequences, not the details):

- **Spoken `cmn` and `yue` → written `zh-Hans`.** No Traditional-Chinese (`zh-Hant`)
  output profile and no script-conversion setting. A transcription holder that emits
  Traditional or Cantonese-colloquial glyphs is normalised to `zh-Hans` by a
  deterministic mapping pass in the rules engine — never by a model.
- **English remains the default profile** (`dictationLanguage: en | cmn | yue`,
  default `en`). Shipped behaviour changes only when the user selects a zh variety.
  Two profiles total (en, zh); the zh profile's spoken variety is chosen explicitly.
  Auto-detection between `cmn` and `yue` is deferred.
- **Both command grammars (en + zh) stay active regardless of profile**: utterances
  may mix languages (English code identifiers inside Chinese speech, English commands
  while dictating Chinese). Command matching is textual — a phrase transcribed to the
  same characters (`句号`, `新段落`, `蛇形命名`) works pronounced in either variety.
- **All §0 hard invariants and ADR-0001 apply unchanged to Chinese text**: cleanup
  stays a deterministic rules engine (< 1 ms); no model rewrites dictated words;
  deny-by-default break safety; the desktop window is never opened from the dictation
  pipeline.

## Why

- **The audience is Chinese-speaking developers.** A developer dictation tool that
  cannot take Chinese input excludes exactly the users it is built for; spoken
  Cantonese coverage (Guangdong, Hong Kong) is part of that requirement, with written
  output deliberately standardised on Simplified Chinese.
- **The roadmap already pointed here.** #252 ("multiple languages + auto-detect",
  v1.1) is on the books; this ADR scopes its first slice down to something
  implementable (`cmn`/`yue` → `zh-Hans`) instead of leaving it open-ended.
- **Nothing architectural blocks it.** The transcription role already exists
  (ADR-0003); cleanup is a profile-switchable rules engine; settings and the model
  supervisor have the hooks. The two-stage shape ADR-0002 fixed is untouched.
- **The invariants survive.** Local-first and no-LLM-rewrite hold for Chinese text —
  "Chinese" adds a language profile, not a cloud backend and not a translation model.

## Status: proposed, not accepted

Adoption is gated exactly the way ADR-0002's own benchmark gated its decision —
measured evidence before the architecture commit:

1. **Transcription-holder benchmark for `cmn` and `yue`** on the target M-series
   hardware: warm end-of-speech → text-ready inside the sub-1s budget (ADR-0001), and
   an accuracy bar set *before* the run. Primary candidate: **SenseVoiceSmall as CoreML
   on the ANE via FluidAudio** — the pinned dependency already ships the manager
   (`Sources/FluidAudio/ASR/SenseVoice/`, weights `FluidInference/sensevoice-small-coreml`;
   zh/yue/en/ja/ko, non-autoregressive, language auto-detect), so the zh holder can keep
   today's NDJSON shell and model-download machinery; `paraformer-large-zh` is available
   there too (Mandarin-only). Fallbacks / comparisons (non-binding, mirroring the
   #178/#203 method): whisper.cpp `large-v3`-class multilingual models (proven Apple
   Silicon build path in this repo; covers both varieties), sherpa-onnx packaging, and —
   for the native rewrite — Apple's on-device `SFSpeechRecognizer` (`zh-CN`/`zh-HK`),
   which must be proven against offline, latency and permission constraints. Weights
   licensing (FunASR Model License for SenseVoice) stays a gate; evidence in
   `zh-extension-impact.md` §6.4.
2. **Eval corpora** for `cmn` and `yue` (built like #171, but captured against the new
   holder's protocol — the old #171 recipe curls whisper-server and is stale).
3. **Rewrite-role zh gate** for break placement: the current holder (SmolLM2-1.7B) is
   English-centric; zh break placement is eligible only after it passes a zh eval set,
   else zh dictation degrades to prose (deny-by-default, fail-closed). **Evaluated
   2026-09-23 — FAIL.** Driven through the product's own break-placement adapter and
   parser on a 10-case author-read zh set, the holder returned 100% well-formed number
   lists and never broke the sentence-1 rule, but matched the intended breaks **0/50**
   times: it over-breaks almost every sentence and never answers `none`, and 8/48 warm
   calls exceeded the product's 300 ms timeout. **Consequence: v1 zh dictation renders
   as prose with no automatic breaks** — no zh prompt tuning or model swap is needed to
   make that call; the rewrite role stays English-only and the zh path never calls it.
   Evidence: `prototypes/zh-asr-holder-252/RESULTS.md` §Gate #3.

Until these gates pass, this ADR stays `proposed` and the requirements.md §5 extension
is **not in force**.

## Consequences

- **ADR-0002 is partially superseded.** "English-only stands" no longer describes the
  language scope: English is the default profile, not the whole product. The rest of
  ADR-0002 — the two-stage dictation shape and the rejection of a one-model engine —
  is untouched. ADR-0002's status line is updated to record this.
- **ADR-0003's role decision extends, not changes.** The role may now be held by a
  different model for zh, and the holder need not leave FluidAudio: the pinned
  dependency already ships SenseVoiceSmall (zh/yue/en/ja/ko) and Paraformer-large-zh as
  CoreML managers, while Parakeet TDT v3 (no Chinese) stays in the role for en. The
  supervisor never keeps two speech models resident (ADR-0001 memory consequence); a
  profile switch restarts the transcription holder under the existing lifecycle, and the
  NDJSON-stdio shell contract is unchanged. Evidence: `zh-extension-impact.md` §6.4.
- **The rules engine grows a zh profile** (~est. +300–400 lines) with its own full
  test suite: orthography normalisation, full-width punctuation, gated breaks, Chinese
  numbers/currency, fillers, self-correction, reduplication exceptions, no forced
  terminal punctuation. Spoken triggers and `voiceEditCommands` gain zh entries; the
  Commands page and `commandReference` go bilingual. English rules are untouched.
- **Settings schema** gains `dictationLanguage: en | cmn | yue` (F10). Renderer and
  overlay need a CJK font fallback (JetBrains Mono has no hanzi glyphs).
- **IME interplay becomes a verification item**: push-to-talk and the recording-only
  Escape handler must not fight active Chinese input sources (拼音/五笔/粤拼); confirm
  on real `zh-CN`/`zh-HK` sources.
- **Download size grows** with the zh transcription weight (large-v3-class is
  multi-GB); validate against the `docs/planning/app-size.md` guardrail and first-run
  UX (#249 parity for the zh role).
- **The native rewrite plan must change** (`docs/planning/native-swift-rewrite.md`):
  its "reuse FluidAudio for ASR" assumption (§2a) does not cover Chinese; the
  feasibility table, port surface and effort estimate need the zh rules and the
  transcription-role question added.
- **Risk is dominated by Cantonese transcription accuracy** (fewer on-device options
  than Mandarin) and by rules fidelity for Chinese (reduplication, fillers,
  colloquialisms are corpus-driven, not guessable). Both are owned by the gates above
  and the open questions in requirements.md §5.12.
