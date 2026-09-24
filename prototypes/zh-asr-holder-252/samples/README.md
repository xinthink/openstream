# samples/ — capture recipe (cmn / yue)

Gate #1 needs **real human speech**; the `smoke/` TTS clips never count toward A1/A2.
This directory is the corpus layout the replay script (`replay-A0.py`) expects.

## Layout

```
samples/
  cmn/
    short/          < 3 s
    sentence/       ~5–10 s
    paragraph/      ~15–30 s
    dev-context/    code identifiers + spoken command phrases mixed in
  yue/              same four classes
  reference/        <clip-id>.txt, one plain-text line per clip (paired by basename)
```

- One speaker is fine for the first cut; note the speaker in the filename if you add more
  (`cmn-sent-012-a.wav`).
- Also capture **dev-context** clips: say a real identifier (`getUserName`,
  `snake_case`), then a zh command phrase (`新段落`, `蛇形命名`, `逗号`), then an English
  command — this is what A2 measures.

## Recording

- 16 kHz mono 16-bit PCM WAV, exactly what `F7`/candidate contract C3 specifies.
- `say` output works as a format reference, but do **not** use TTS for these clips.
- Any mic is acceptable for a first pass; record the device in `RESULTS.md`.
- Keep a natural pace. Do not read the reference text as a script in a robot voice.
- Quick format check after capture:
  `afinfo samples/cmn/sentence/foo.wav` → `1 ch, 16000 Hz, Int16`.

## Pre-registration (fill before the first capture — repo discipline)

Copy these into `RESULTS.md` first; do not tune them after seeing the numbers.

| Row | Threshold |
|---|---|
| A1 CER, cmn (all classes) | cmn ≤ ____ % |
| A1 CER, yue (all classes) | yue ≤ ____ % |
| A2 CER, dev-context (per variety) | cmn ≤ ____ % / yue ≤ ____ % |
| L1 warm latency | median < 1000 ms; p90 < 1000 ms (target p90 < 900 ms) |

## Running the replay

```bash
./replay-A0.py        # drives the A0 harness over this corpus -> results/A0.jsonl
python3 analyze.py    # results/A0.jsonl -> per-class table + CER
```
