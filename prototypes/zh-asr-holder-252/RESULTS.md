# RESULTS — zh transcription-role holder benchmark

> Status: **smoke tier run 2026-09-23; accuracy bar still pending.** Everything below
> comes from **TTS clips** (`say`), which `README.md` restricts to coarse screening.
> These numbers do **not** clear gate #1: A1/A2 (CER on real speech) still need human
> `cmn`/`yue` recordings. Candidate A0 (SenseVoiceSmall via FluidAudio) was added to the
> spec after the first draft — see README §Candidates and
> [`zh-extension-impact.md` §6.4](../../docs/planning/zh-extension-impact.md).

## Environment

- Machine / chip / RAM: `Mac14,7` / Apple M2 / 24 GB
- macOS: 26.6.2 (25G83); Xcode 27.0; Swift 6.4
- Candidate A0: FluidAudio 0.15.6 (path dependency into the product's pinned checkout),
  SenseVoiceSmall `fp16` encoder on the ANE, preprocessor fp32/CPU
- Weights: `FluidInference/sensevoice-small-coreml`, fetched with
  `REGISTRY_URL=https://hf-mirror.com` (direct `huggingface.co` is unreachable from this
  network; `example.com` and `hf-mirror.com` are fine). Cache:
  `~/Library/Application Support/FluidAudio/Models/sensevoice-small/`
- Harness: `harness-fluidaudio/` (Swift package; one-shot `--wav` mode and the NDJSON
  shell). Runner: `./smoke-A0.sh`; raw records: `results/A0-smoke.jsonl`.

## A0 smoke run

Clips: `smoke/*.wav`, 16 kHz mono Int16 WAV (the F7/C3 input contract), generated with
`say` (`Tingting` zh_CN, `Sinji` zh_HK).

| clip | variety | clip (s) | `lang` | load (ms) | infer (ms) | transcript |
|---|---|---|---|---|---|---|
| cmn-short | cmn | 2.90 | auto | 531 | 131 | 你好这是一段普通话的测试 |
| cmn-sent | cmn | 6.62 | auto | 513 | 143 | 我们在做一个本地优先的语音听写工具所有音频都不会离开这台电脑 |
| yue-sent | yue | 4.37 | auto | 513 | 157 | 你好呢个系粤语嘅测试我想试下专写 |
| yue-sent | yue | 4.37 | **yue (3)** | 524 | 146 | 你好呢个系粤语嘅测试我想试下转写 |
| cmn-dev | cmn | 4.47 | auto | 465 | 147 | butget user name 改成蛇形命名逗号然后继续 |
| cmn-dev | cmn | 4.47 | **cmn (1)** | 547 | 145 | butget user name 改成蛇形命名逗号然后继续 |
| cmn-para | cmn | 26.03 | auto | 658 | 280 | 我们在做一个本地优先的语音听写工具…同时确认输出里有没有标点符号（全篇无标点） |
| yue-para | yue | 16.60 | auto | 533 | 247 | 你好呢个系一个粤语嘅段落测试…亦都唔需要任何账号（白话文，无标点） |

- **Cold** (first invocation, includes the download): `load_ms = 720,925` (~12 min) for
  the ~471 MB fetch plus first CoreML load. **Warm** start: **465–658 ms** to load the
  cached model. **Warm inference: 131–280 ms** across 2.9–26.0 s clips — the paragraph
  class is the slowest and still ~3.5× inside the sub-1 s budget.
- Full transcripts are in `results/A0-smoke.jsonl`; the paragraph rows above are elided
  only for width.
- Forcing the language index changed one yue token (`专写` → `转写`), which is weak but
  positive evidence for the index table in the harness (`yue`→3, `cmn`→1, auto→0).

## Pass/fail against the pre-registered criteria (smoke scope only)

| Row | Result | Verdict |
|---|---|---|
| L1 warm latency | 131–280 ms inference across 2.9–26.0 s clips (paragraph class included) | **pass (smoke)**; re-check on real speech |
| L2 cold load / switch cost | cached ≈ 0.5–0.7 s; first run 720.9 s incl. 471 MB download | record — first-use cost is a product fact (Setup / #249 parity) |
| A1 CER per variety | not measured (TTS) | **pending** |
| A2 CER dev-context | not measured; `getUserName` → `get user name` / `butget user name` | **pending**; A2 risk is real |
| O1 script | Simplified glyphs for cmn; yue emits **colloquial Cantonese written form** (`呢个系…嘅`) | **open issue** — see below |
| O2 tag/emo stripping | no `<\|zh\|>`/emotion tags surfaced (FluidAudio strips them in `decode`) | handled upstream |
| O3 punctuation / ITN | **no punctuation**; **no ITN** — spoken numbers pass through as words (`一千零二十三`, `百分之五十`, `三点一四`, `二零二五年三月九号` all verbatim) | zh rules own **every** mark **and every number**; §5.3 pass 4 is entirely rules-side (spec assumption confirmed) |
| S1 download size | fp16 471.5 MB; **int8 225 MB** (upstream: accuracy-neutral, peak RAM 0.54→0.32 GB); fp32 897 MB | likely inside the app-size guardrail; same order as Parakeet (~470 MB) |
| M1 resident memory | holder 49 MB RSS (A0) vs 38 MB (current Parakeet); llama-server 1463 MB peak; upstream fp16 peak RAM 0.54 GB / int8 0.32 GB | **pass (smoke)** — see §Resident memory |
| P1 licence | FunASR Model License v1.1: free use/modify/share; **§2.2 must attribute source/author and retain model names**; no display/field-of-use clause; §7 jurisdiction left blank | **conditionally acceptable** — see §Licence |

## Findings that touch the spec's assumptions

1. **`yue` output is colloquial Cantonese, not standard written Chinese.** The holder
   does normalise Traditional → Simplified glyphs (`個→个`, `係→系`, `語→语`), but it
   writes *what was said* (`呢个系…嘅`) rather than the standard written form (`这个是…的`).
   requirements §5.1 promises standard written `zh-Hans`, and §5.10 puts Cantonese
   colloquial output out of scope; §5.2.4 assumes a **static hanzi-mapping pass** closes
   the gap. This smoke says the gap is **lexical/grammatical**, not just glyph-level:
   common function words (`嘅→的`, `系→是`, `唔→不`, `咗→了`, `佢→他`) are mappable
   deterministically, but Cantonese word order (`畀本书我`) is not. That is a **scope
   decision for ADR-0004 / requirements §5.1**, not something to settle inside a rules
   pass.
2. **The holder emits no punctuation and (untested) may do no ITN.** Parakeet punctuates
   from prosody; SenseVoice does not. That removes the #320-class "stray punctuation
   around a spoken break" problem for zh, and it means §5.3's "no forced terminal
   punctuation" is the natural behaviour — but it also means zh prose is unpunctuated
   unless the speaker says `逗号`/`句号`. Worth stating explicitly in §5.3.
3. **Dev-context identifiers are weak.** `getUserName` came through as `get user name`
   (and the leading `把` was absorbed into `butget`). This is exactly the A2 subset the
   spike exists to measure; keyword boosting (#322, generalised) looks necessary rather
   than optional for the dev-context promise.
4. **One holder serves both varieties** (C7-friendly): A0 is a single model; the variety
   is an input index, so no second resident speech model is needed for cmn/yue.
5. **No ITN — confirmed by probe (`probe-A0.sh`, 2026-09-23).** Spoken numbers come out
   as number words in every case tried: `一千零二十三块钱` (not `1023`),
   `百分之五十` (not `50%`), `三点一四` (not `3.14`), `二零二五年三月九号` (not
   `2025年3月9号`). The zh number/currency/percent pass (§5.3 pass 4) is therefore
   wholly owned by the rules engine — the spec's assumption holds, and the holder needs
   no ITN configuration work.
6. **The holder does zero Cantonese-colloquial normalisation — §5.3.6's premise is
   false for A0.** Probe clips with 唔/佢/咗/嘅/睇/冇/哋 all came through **verbatim**
   (auto and forced `yue` alike): `我唔知道佢去咗边度`, `呢本书系我嘅佢睇咗好开心`,
   `今日冇雨我哋去街市买`. So whatever standardisation reaches standard written
   Chinese must come from the rules engine (or not at all) — the §5.8 scope decision
   cannot be dodged by hoping the holder does it. One accuracy datapoint for A1: the
   Cantonese-specific char `餸` was **dropped** (`买餸` → `买`), so rare-colloquial
   coverage is imperfect.

## Resident memory (C7/M1, measured 2026-09-23)

Peak RSS sampled while each process was alive (M2 / 24 GB):

| Process | Peak RSS |
|---|---|
| A0 holder (`zh-smoke`, SenseVoiceSmall fp16/ANE, load + inference) | **49 MB** |
| Current holder (`transcription-helper`, Parakeet TDT v3, after load) | **38 MB** |
| Rewrite role (`llama-server` + SmolLM2-1.7B q4_k_m, `--ctx-size 2048`) | **1463 MB** |

Reading:

- CoreML/ANE weights are **not** charged to process RSS on Apple Silicon: both holders
  sit at ~40–50 MB although each loads ~470 MB of weights. The number that matters for
  the ceiling is the upstream conversion card's **peak RAM: 0.54 GB (fp16) / 0.32 GB
  (int8)**.
- The rewrite role dominates: **1463 MB measured** against the ~1 GB estimate in
  `docs/planning/app-size.md` §Tier 2 — the doc understates it by ~45%.
- C7 ("never two speech models resident") holds regardless: A0 is a *single* holder for
  both varieties, so selecting zh replaces Parakeet rather than adding a second speech
  model.
- **Design recommendation: use the int8 encoder.** Upstream reports it accuracy-neutral
  (AISHELL-1 test CER 3.09 → 3.09%) at half the disk (225 MB) and ~40% less peak RAM
  (0.32 GB) — the cheapest way to keep the zh profile inside the current memory ceiling.

## Licence (P1): FunASR Model License v1.1

Chain of title (fetched 2026-09-23 through `hf-mirror.com` and the GitHub raw mirror):

- `FunAudioLLM/SenseVoiceSmall` (the weights): `license: other`, `license_name:
  model-license`, `license_link:
  https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE`.
- `FluidInference/sensevoice-small-coreml` (the conversion A0 loads):
  `license: other`, `license_name: sensevoice-upstream` — it defers to the upstream
  terms and ships **no separate licence file**.

FunASR Model Open Source License Agreement v1.1, Copyright (C) 2023-2028 Alibaba Group:

| Clause | Text (abridged) | Consequence |
|---|---|---|
| §2.1 License | "free to use, copy, modify, and share" | Redistribution and commercial use are permitted |
| §2.2 Restrictions | "you must attribute the source and author information and retain relevant model names" | An **attribution + model-name-retention** obligation |
| §4.2 | no unjustified denigration, else "automatic forfeiture of all licenses" | A conduct clause MIT/OSI licences do not carry |
| §5 | licence terminates automatically on violation | — |
| §7 | "governed by the laws of [Country/Region]" — placeholder unfilled | Jurisdiction unspecified in the published text |

Against this repo's posture (`docs/research/model-licensing.md`): that note rejected
Llama 3.2 because of a **prominent "Built with Llama" display requirement** plus a
field-of-use Acceptable Use Policy. FunASR v1.1 has **neither** — no display obligation
and no prohibited-use list — so it is materially lighter. Its obligation is the same
class the repo already carries for whisper/ggml: retain notices and name the component.

**Verdict: conditionally acceptable for an MIT installer.** The weights are not MIT, so
the README/About must name SenseVoice and the FunASR licence — the same documentation
gap `model-licensing.md` flagged for Llama — but there is no display or field-of-use
burden. §4.2 and the blank §7 jurisdiction are the two items worth a human/legal read.
This is an engineer's reading, not legal advice.



## Gate #3: rewrite-role zh break placement (measured 2026-09-23)

Can the holder already resident for English break placement (SmolLM2-1.7B-Instruct
Q4_K_M) place paragraph breaks in Chinese well enough to be eligible for the zh profile?

Method: `zh-breaks-eval.mjs` drives the **product's own**
`createBreakPlacementHttpAdapter` (byte-identical system prompt and request body; only the
abort budget is raised from the product's 300 ms to 5000 ms so slow replies are measured
rather than aborted) and parses replies with the **product's own** `repairBreakIndices`.
10 author-read cases (3–10 sentences, four single-topic controls, one enumeration decoy),
5 warm reps each. Raw: `results/breaks-eval.json`.

| id | sentences | expected | model answer | exact | median ms |
|---|---|---|---|---|---|
| zh-4-topicshift | 4 | [3] | 2, 3, 4 | 0/5 | 147 |
| zh-3-onetopic | 3 | none | 2, 3 | 0/5 | 121 |
| zh-4-earlybreak | 4 | [2] | 2, 4 | 0/5 | 118 |
| zh-5-debug | 5 | [4] | 2, 4, 5 | 0/5 | 145 |
| zh-6-two-shifts | 6 | [4] | 2, 4, 5, 6 | 0/5 | 202 |
| zh-6-onetopic-none | 6 | none | 2, 4, 5, 6 | 0/5 | 203 |
| zh-6-decoy-enumeration | 6 | none | 2, 4, 5 | 0/5 | 156 |
| zh-8-dev | 8 | [4] | 2, 4, 5, 6, 7 | 0/5 | 265 |
| zh-10-long | 10 | [5, 9] | 2, 4, 6, 7, 9 | 0/5 | 250 |
| zh-7-three-topics | 7 | [4] | 2, 4, 5, 6 | 0/5 | 215 |

Aggregate (50 calls):

| Metric | Value |
|---|---|
| Format validity (`STRICT_REPLY`) | **50/50 (100%)** |
| Sentence-1 violations | **0/50** |
| Exact match vs author ground truth | **0/50** |
| `none` on the single-topic controls | **never** |
| Repair needed | 0/50 |
| Warm latency | median **200 ms**, min 94, max 795; **8/48 > the product's 300 ms timeout** |

**Verdict: gate #3 fails.** The format is learnable — the same shape
`spike/list-boundaries-125` found: well-formed output, wrong content. On Chinese the
holder over-breaks nearly every sentence and never answers `none`, so a zh paragraph
would be shredded into one-line paragraphs. Per `requirements.md` §5.4 this is exactly
the fail-closed case: **zh dictation v1 renders as prose with no automatic breaks** until
a zh-capable rewrite holder exists. No zh prompt tuning or model swap is needed to make
that call — the rewrite role stays English-only and the zh path never calls it.

## Verdicts against the pre-registered hypotheses

1. SenseVoiceSmall (A0) sub-1s? — **supported on TTS smoke**: 131–280 ms warm inference
   across 2.9–26.0 s clips (paragraph class included).
2. Trilingual streaming Paraformer (C) strongest yue? — untested; A0 already covers yue,
   so C is now fallback-only.
3. Whisper paragraph at/over the line (#310 echo)? — untested (A0 made it unnecessary).
4. SFSpeechRecognizer on-device viable? — untested (native-rewrite lens only).
5. Single holder vs dual holder — A0 is single-holder for both varieties.

## Decision output

- **Holder recommendation: A0 (SenseVoiceSmall via FluidAudio) leads**, and the smoke
  cleared latency (L1), format (C3/O2), script (O1), memory (M1) and the licence read
  (P1). It is still subject to the **real-speech accuracy bar (A1/A2)**.
- **Encoder choice: int8** (225 MB disk, ~0.32 GB peak RAM, upstream-verified
  accuracy-neutral) is the recommended variant for the product wiring.
- **Gate #3 is resolved — FAIL** (§Gate #3 above): the resident rewrite holder cannot
  place zh breaks (0/50 exact, never `none`), so **zh v1 ships as prose with no
  automatic paragraph breaks**. That closes an ADR-0004 open question without any zh
  prompt or model work.
- **ADR-0004 status: stays `proposed`.** Gate #1 is not passed — TTS cannot answer
  A1/A2, and the yue output-scope question below is now a spec decision.
- **Next (in order)**: (1) record real `cmn` and `yue` clips — short / sentence /
  paragraph / dev-context, per README §Inputs — and replay them through the harness
  NDJSON shell to produce CER; (2) settle the yue output-scope question in ADR-0004
  (`zh-extension-impact.md` §5.8); (3) get a legal read on FunASR §4.2 / §7; (4) then
  the gated implementation work (zh rules profile, zh command grammar, settings, UI).
