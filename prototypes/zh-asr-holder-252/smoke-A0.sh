#!/usr/bin/env bash
# Spike-only smoke runner for ADR-0004 gate #1, candidate A0
# (SenseVoiceSmall via FluidAudio). TTS clips only: coarse screening per
# README.md - these numbers/transcripts never count toward the A1/A2 accuracy bar.
#
# Usage: ./smoke-A0.sh
# Records raw JSON lines in results/A0-smoke.jsonl.
set -euo pipefail
cd "$(dirname "$0")"

BIN=harness-fluidaudio/.build/release/zh-smoke
# FluidAudio's ModelRegistry reads REGISTRY_URL (default https://huggingface.co);
# this network reaches hf-mirror.com but not huggingface.co directly.
export REGISTRY_URL="${REGISTRY_URL:-https://hf-mirror.com}"
mkdir -p results

if [[ ! -x "$BIN" ]]; then
  echo "building $BIN ..." >&2
  (cd harness-fluidaudio && swift build -c release)
fi

echo "== cold: first invocation pays the ~471 MB download, so load_ms includes it ==" | tee results/A0-smoke.jsonl
"$BIN" --wav smoke/cmn-short.wav --lang auto | tee -a results/A0-smoke.jsonl

echo "== warm: model cached - one line per clip ==" | tee -a results/A0-smoke.jsonl
run() { "$BIN" --wav "smoke/$1.wav" --lang "$2" | tee -a results/A0-smoke.jsonl; }
run cmn-short auto
run cmn-sent auto
run yue-sent auto
run yue-sent yue   # probes the forced-language index table (yue -> 3)
run cmn-dev auto
run cmn-dev cmn    # probes zh -> 1

echo "== raw records: results/A0-smoke.jsonl ==" >&2
