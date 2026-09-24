#!/usr/bin/env python3
"""Spike-only: replay a recorded cmn/yue corpus through candidate A0.

Drives the harness (`harness-fluidaudio` NDJSON shell), writes one record per clip to
`results/A0.jsonl`, and prints them. See `samples/README.md` for the corpus layout and
the pre-registration discipline; `analyze.py` renders the tables.

Not product code.
"""
import base64
import json
import os
import subprocess
import sys
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BIN = ROOT / "harness-fluidaudio/.build/release/zh-smoke"
RESULTS = ROOT / "results"
OUT = RESULTS / "A0.jsonl"
VARIETIES = ["cmn", "yue"]
CLASSES = ["short", "sentence", "paragraph", "dev-context"]

# Punctuation/whitespace are dropped before CER: the holder emits no punctuation at
# all (RESULTS.md O3), so keeping marks would charge the holder for a rules-engine job.
DROP = set(" \t\n\r。，、；：？！…—「」『』《》（）()\"'“”‘’.,!?;:[]{}-")


def normalize(text: str) -> str:
    return "".join(ch for ch in text.lower() if ch not in DROP)


def cer(reference: str, hypothesis: str):
    ref, hyp = normalize(reference), normalize(hypothesis)
    if not ref:
        return None
    previous = list(range(len(hyp) + 1))
    for i, rc in enumerate(ref, 1):
        current = [i]
        for j, hc in enumerate(hyp, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (rc != hc)))
        previous = current
    return previous[-1] / len(ref)


def find_reference(variety: str, clip: Path):
    for candidate in (
        ROOT / "samples" / variety / "reference" / f"{clip.stem}.txt",
        ROOT / "samples" / "reference" / f"{clip.stem}.txt",
    ):
        if candidate.exists():
            return candidate.read_text(encoding="utf-8").strip()
    return None


def wav_ms(path: Path) -> int:
    with wave.open(str(path), "rb") as handle:
        return int(1000 * handle.getnframes() / handle.getframerate())


def collect():
    clips = []
    for variety in VARIETIES:
        for klass in CLASSES:
            directory = ROOT / "samples" / variety / klass
            if directory.is_dir():
                clips += [(variety, klass, path) for path in sorted(directory.glob("*.wav"))]
    return clips


def main() -> None:
    if not BIN.exists():
        sys.exit(f"missing harness binary {BIN} - build it: (cd harness-fluidaudio && swift build -c release)")
    clips = collect()
    if not clips:
        sys.exit("no clips under samples/<variety>/<class>/ - see samples/README.md")

    RESULTS.mkdir(exist_ok=True)
    environment = dict(os.environ)
    environment.setdefault("REGISTRY_URL", "https://hf-mirror.com")
    process = subprocess.Popen(
        [str(BIN)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, env=environment, bufsize=1,
    )
    ready = json.loads(process.stdout.readline() or "{}")
    if ready.get("event") != "ready":
        sys.exit(f"harness did not become ready: {ready}")
    print(f"# harness ready (load_ms={ready.get('load_ms')})", file=sys.stderr)

    records = []
    for index, (variety, klass, clip) in enumerate(clips, 1):
        payload = base64.b64encode(clip.read_bytes()).decode()
        started = time.perf_counter()
        process.stdin.write(json.dumps({
            "id": str(index), "cmd": "transcribe", "wav": payload, "lang": variety,
        }) + "\n")
        process.stdin.flush()
        reply = json.loads(process.stdout.readline())
        elapsed_ms = int((time.perf_counter() - started) * 1000)
        text = reply.get("text", "") if reply.get("status") == "ok" else ""
        reference = find_reference(variety, clip)
        record = {
            "candidate": "A0", "runtime": "FluidAudio", "model": "SenseVoiceSmall-fp16",
            "variety": variety, "class": klass, "clip_id": clip.stem,
            "clip_ms": wav_ms(clip), "wav_bytes": clip.stat().st_size,
            "reply_ms": elapsed_ms, "text": text, "reference": reference,
            "cer": None if reference is None else cer(reference, text),
            "status": "ok" if reply.get("status") == "ok" else reply.get("reason"),
            "licence": "FunASR Model License v1.1 (attribution)",
        }
        records.append(record)
        print(json.dumps(record, ensure_ascii=False))

    process.stdin.close()
    process.terminate()
    with OUT.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
    print(f"\nwrote {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
