# prototypes/zh-asr-holder-252

Throwaway measurement spike for **ADR-0004 gate #1** ([ADR-0004](../../docs/adr/0004-mandarin-cantonese-dictation.md),
status: proposed): which local transcription-role holder can serve **Mandarin (`cmn`) and
Cantonese (`yue`) → written Simplified Chinese (`zh-Hans`)** inside the ADR-0001 sub-1s
warm-latency budget on M-series, with a licence the project can ship under?

Scoped by [requirements.md §5](../../docs/planning/requirements.md) (§5.2 holder contract,
§5.9 eval corpora, §5.13 gates) and pre-read by
[`zh-extension-impact.md` §6](../../docs/planning/zh-extension-impact.md) (desktop research;
this spike replaces those `[需核验]` cells with measured numbers). Naming anchor: the
roadmap line ADR-0004 scopes — issue [#252](https://github.com/Nabzx/openstream/issues/252)
("multiple languages + auto-detect"). Methodology mirrors the repo's own benchmarks
([#178](https://github.com/Nabzx/openstream/issues/178)/[#203](https://github.com/Nabzx/openstream/issues/203),
`spike/llm-cleanup-latency`): set the pass line **before** running, keep raw data next to
the conclusion.

**Answer: pending.** See `RESULTS.md`. ADR-0004 stays `proposed` until this passes.

## Decision this spike feeds

- **Gate #1 — holder benchmark**: accept/reject the transcription-role holder choice for
  zh. If accepted, it also fixes: single-holder-both-varieties vs dual-holder-per-profile
  (switch restarts the holder; never two speech models resident — ADR-0001 consequence),
  the `zh-Hans` normalisation source, and whether output needs tag/emo stripping.
- **Feeds gate #2**: this spike's corpus is the first version of the `cmn`/`yue` eval
  corpus ([#171](https://github.com/Nabzx/openstream/issues/171) lineage — but recorded
  against the *new* holder's protocol; the old #171 recipe curls whisper-server and is stale).
- **Feeds gate #3 (rewrite holder for zh break placement)**: the same transcripts are the
  input set for judging whether the rewrite-role holder can do zh sentence breaks, or
  whether zh dictation degrades to prose (deny-by-default).

This is a measurement spike, not a build: no OpenStream code changes come out of it.

## Contract under test (from requirements §5.2 — holder must satisfy all)

| # | Requirement | What the harness checks |
|---|---|---|
| C1 | Local-first; nothing leaves the machine | run fully offline after weights are staged; no network at inference |
| C2 | Fits the transcription-role shell | can be wrapped to speak the NDJSON-stdio protocol (below) with ≤ ~50 lines of glue |
| C3 | Input = mono 16 kHz / 16-bit PCM WAV (F7 unchanged) | harness feeds exactly this |
| C4 | Output = UTF-8 text | UTF-8 validity + script check (zh-Hans vs zh-Hant vs colloquial) |
| C5 | Warm end-of-speech → text-ready **< 1 s** per variety, per length class | warm latency distribution (see §Metrics) |
| C6 | Weights verified on download; fetch honours mirrors (F12) | document sha + `REGISTRY_URL`/mirror story per candidate |
| C7 | Never two speech models resident (ADR-0001/F9) | memory measurement alongside the rewrite model |
| C8 | Licence shippable under the project's MIT posture | licence verdict per candidate (see §Pass criteria) |

NDJSON-stdio shell contract (identical shape to
[`transcription-helper`](../../native/transcription-helper/Sources/transcription-helper/main.swift)):

```
startup:  {"event":"ready"}  (after the model is loaded)   or  {"event":"error",...} then exit(1)
request:  {"id":"1","cmd":"transcribe","wav":"<base64 WAV>"}
reply:    {"id":"1","status":"ok","text":"...","ms":312}   or  {"id":"1","status":"error","reason":"..."}
          {"id":"1","cmd":"ping"} -> {"id":"1","status":"ok"}
```

## Candidates (desktop shortlist — see zh-extension-impact §6.1; pins re-verified at run time)

| id | Candidate | Runtime path | Pin source | Notes |
|---|---|---|---|---|
| **A0** | **SenseVoiceSmall** | **FluidAudio (already the repo's pinned ASR dependency, `0.15.6`)** | `FluidInference/sensevoice-small-coreml` | **Primary path (added 2026-09-09 after a local check):** the pinned checkout already carries `SenseVoiceManager`/`SenseVoiceModels`. Same NDJSON shell as today's `transcription-helper` (smallest glue of any candidate), one holder for cmn+yue, NAR. Also present: `FluidInference/paraformer-large-zh-coreml` (Mandarin-only). See zh-extension-impact §6.4 |
| A | SenseVoiceSmall | sherpa-onnx (Swift/C++ binding, macOS) | HF `FunAudioLLM/SenseVoiceSmall` + sherpa-onnx tag | Official zh+yue+en+ja+ko; NAR; strong zh/yue claims. **Fallback** if A0 fails a criterion (e.g. licence or ANE behaviour) |
| B | SenseVoiceSmall | llama.cpp/GGUF single binary (funasr llama-cpp runtime, FSMN-VAD built in) | `QwenAudio/SenseVoice` releases + GGUF HF repo | Alt packaging; closest shape to whisper.cpp flow |
| C | sherpa-onnx streaming Paraformer trilingual **zh-cantonese-en** | sherpa-onnx (streaming) | HF `csukuangfj/sherpa-onnx-streaming-paraformer-trilingual-zh-cantonese-en` | Dedicated Cantonese training; low-RTF streaming family |
| D | Whisper large-v3 / large-v3-turbo | whisper.cpp (existing build path); optional WhisperKit cross-check | whisper.cpp pinned commit; Argmax `whisperkit-coreml` | Baseline + **must re-test** the #310 latency verdict (FluidAudio large-v3-turbo: 10–20 s load, seconds/utterance) |
| E | Apple SFSpeechRecognizer (`zh-CN`/`zh-HK`) | system API | OS version recorded | Native-rewrite-only lens: on-device/offline/latency/permission must be proven; no self-managed weights |
| F | Fun-ASR (QwenAudio) Nano family | watchlist only | — | Escalate **only** if A–E all fail |

Excluded before running: iFlytek/Xinghuo (cloud or Android-licensed-SDK only —
[`zh-extension-impact.md` §6.1.1](../../docs/planning/zh-extension-impact.md)).

> **Candidate correction (2026-09-09).** The desktop shortlist in
> [`zh-extension-impact.md` §6.1](../../docs/planning/zh-extension-impact.md) predates a local
> check of the pinned dependency: **FluidAudio `0.15.6` — already the engine behind
> `native/transcription-helper` — ships SenseVoiceSmall and Paraformer-large-zh as CoreML
> (ANE) managers**, so the zh holder can stay inside the existing dependency, NDJSON shell
> and model-cache machinery; glue (C2) becomes the smallest of any candidate. sherpa-onnx /
> GGUF packaging drops to a fallback; whisper and SFSpeechRecognizer stay as comparison
> rows. Code-level evidence in zh-extension-impact §6.4.
>
> **Smoke tier (recorded here before the first run).** `smoke/` clips may be produced with
> macOS `say` (this machine has `Tingting` zh_CN and `Sinji` zh_HK) to pre-screen rows
> L2/O1/O2/O3/S1/M1 for A0 without human recordings. Smoke results **never** count toward
> the A1/A2 accuracy bar, and the real `samples/cmn|yue/` corpus is still required for
> gate #1 to pass.

## Inputs: corpus and sample layout

```
samples/
  cmn/  yue/          — real human speech, per variety
    short/ sentence/ paragraph/     — length classes (<3 s / ~5–10 s / ~15–30 s)
    dev-context/                   — code identifiers + spoken commands (en + zh aliases) mixed
    reference/*.txt                — paired references
  smoke/                            — TTS samples, coarse screening only (never for the accuracy bar)
  README.md                         — capture recipe (device, mic, 16 kHz mono 16-bit WAV, script)
```

- Target size and the CER pass line are set in this README's *Pass criteria* **before**
  the first capture (repo discipline: no p-hacking).
- Dev-context subset is mandatory for judging holder behaviour on
  `getUserID`-style identifiers inside Chinese speech and on zh command phrases
  (`新段落`, `蛇形命名`, `删掉那个文件`…).

## Metrics: raw record schema (consumed by `analyze.py`)

Each transcribed clip appends one JSON line to `results/<candidate>.jsonl`:

```jsonc
{
  "candidate": "A", "runtime": "sherpa-onnx", "model": "SenseVoiceSmall",
  "variety": "cmn", "class": "sentence", "clip_id": "cmn-sent-012",
  "clip_ms": 8120, "wav_bytes": 259840,
  "request_ms": 0, "reply_ms": 8124,             // warm: reply_ms - request_ms
  "text": "...", "reference": "...", "cer": 0.041,
  "tags_stripped": true,                         // <|zh|>/emo/event tokens seen + removed?
  "has_terminal_punct": true, "itn_used": true,  // holder output shape -> which zh rules pass owns it
  "load_ms": 3400, "resident_mb": 312, "download_mb": 480, "licence": "FunASR v1.1 (attr)"
}
```

Computed per (candidate, variety, class): n, warm median / p90, CER (character error rate;
word error rate only when reference is en/digits), plus cold-load time, resident memory
(measured with the rewrite model loaded — C7), download size, and a licence verdict string.
`analyze.py` renders the tables for `RESULTS.md` and prints per-row pass/fail against
§Pass criteria; raw jsonl is the archive.

## Pass criteria (set before running — fill the numbers, then run)

| Row | Criterion | Threshold (pre-registered) |
|---|---|---|
| L1 | Warm latency, per variety × class | median < 1000 ms; p90 < 1000 ms (target: p90 < 900 ms to leave cleanup/delivery headroom inside the sub-1 s budget) — fill exact targets here |
| L2 | Cold load / profile-switch cost | record; acceptable only if documented as product cost (Home “starting”) — suggest < ~5 s target, decide here |
| A1 | CER per variety (real-speech, all classes) | fill before capture (e.g. cmn ≤ X%, yue ≤ Y%) |
| A2 | CER dev-context subset (per variety) | fill before capture |
| O1 | Script: zh-Hans readable output for both varieties | yes/no + mapping workload note (zh-Hant/colloquial glyphs from yue holder?) |
| O2 | Tag/emo stripping needed | yes → zh orthography pass owns it; no → note |
| O3 | Punctuation/ITN | does the holder supply `。`/punct or ITN? determines zh §5.3 pass 2/4 ownership |
| S1 | Download size | within `docs/planning/app-size.md` guardrail |
| M1 | Resident memory with rewrite model | within the machine's ceiling (ADR-0001/F9, C7) |
| P1 | Licence | no unacceptable attribution/display/field-of-use burden per `docs/research/model-licensing.md` posture |

## Pre-registered expected outcomes (hypotheses to confirm or refute)

1. **A/B (SenseVoiceSmall) is the most likely sub-1s path** (NAR; official “5–15× faster
   than Whisper-small/large” claims). Biggest unknowns: rich-output tag stripping and the
   yue output script (Traditional/colloquial?) → O1/O2 rows.
2. **C (trilingual streaming Paraformer) is the strongest yue candidate** (dedicated
   Cantonese training, streaming low-RTF), but macOS inference path and offline CER are
   unverified.
3. **D (Whisper large-v3/turbo) will sit at or over the line on paragraph-length clips**
   (echoing the #310 FluidAudio verdict) — kept as the baseline/fallback because the
   whisper.cpp build path already exists here.
4. **E (SFSpeechRecognizer)** — if on-device `zh-CN`/`zh-HK` latency passes on macOS 26,
   the native rewrite should prefer it (in-process, system-managed, no self-downloaded
   weights); if not, it stays a reference row.
5. Single-holder-both-varieties is preferred over dual holders unless CER forces the
   switch; if a switch is needed, its cost and memory are measured, not assumed.

## Files

| | |
| --- | --- |
| `README.md` | this spec (protocol, criteria, method) |
| `RESULTS.md` | the run: machine/env, tables, verdict → feeds ADR-0004 |
| `harness-fluidaudio/` | **candidate A0 adapter** (Swift package): SenseVoiceSmall via FluidAudio. One-shot `--wav` mode for the smoke tier, and the NDJSON-stdio shell for the corpus run |
| `smoke-A0.sh` | smoke tier only: builds A0, replays the TTS clips, writes `results/A0-smoke.jsonl` |
| `measure-A0.sh` | paragraph-class latency + peak-RSS measurement (A0 vs Parakeet holder vs `llama-server`) |
| `probe-A0.sh` | O3 probes: ITN behaviour (numbers/percent/decimal/date) + yue colloquial normalisation |
| `replay-A0.py` | **corpus driver**: replays `samples/**/*.wav` through the NDJSON shell, writes `results/A0.jsonl` with latency + CER |
| `analyze.py` | `results/A0.jsonl` → per (variety, class) median/p90 + CER, with pass/fail against the pre-registration |
| `zh-breaks-eval.mjs` + `breaks-cases.json` | **gate #3**: drives the product's own break-placement adapter + parser against SmolLM2 on a 10-case author-read zh set → `results/breaks-eval.json` |
| `smoke/` | TTS clips (`say` Tingting zh_CN / Sinji zh_HK → 16 kHz mono WAV); screening only, never the accuracy bar |
| `samples/` | **real-speech corpus** layout + capture recipe (`samples/README.md`); still to be recorded — the gate #1 blocker |
| `run-<id>.sh` | one script per remaining candidate: pinned fetch/build, start adapter, replay corpus, write `results/<id>.jsonl` |
| `adapter-<id>.mjs` | the NDJSON-stdio shell per remaining (non-Swift) candidate (C2) |

## Re-running

Per candidate: `./run-<id>.sh` (requires the staged weights + target Mac), then
`python3 analyze.py` regenerates `RESULTS.md`. Everything is reproducible from the pins;
record OS/machine/memory in RESULTS first.
