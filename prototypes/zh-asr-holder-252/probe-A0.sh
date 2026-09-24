#!/usr/bin/env bash
# Spike-only probes for ADR-0004, candidate A0 (SenseVoiceSmall via FluidAudio).
# Closes two data gaps the smoke run left open:
#   1. O3  - ITN: does the holder emit Arabic digits / % for spoken numbers?
#            (decides who owns requirements §5.3 pass 4: holder vs rules)
#   2. §5.8- yue colloquial normalisation: does the holder standardise
#            唔/咗/佢/嘅-class tokens upstream (§5.3.6's premise), or pass them
#            through verbatim? (informs the yue output-scope decision)
# TTS clips only: coarse screening, never the accuracy bar.
set -euo pipefail
cd "$(dirname "$0")"
BIN=harness-fluidaudio/.build/release/zh-smoke
export REGISTRY_URL="${REGISTRY_URL:-https://hf-mirror.com}"
mkdir -p results

gen() { say -v "$1" -o "smoke/$2.aiff" "$3" && afconvert -f WAVE -d LEI16@16000 -c 1 "smoke/$2.aiff" "smoke/$2.wav" && rm -f "smoke/$2.aiff"; }

# --- 1. ITN / number probes (cmn) ----------------------------------------
gen Tingting itn-money   "这个项目花了一千零二十三块钱，占比百分之五十。"
gen Tingting itn-decimal "圆周率大约是三点一四。"
gen Tingting itn-date    "会议定在二零二五年三月九号。"

# --- 2. yue colloquial probes ---------------------------------------------
gen Sinji yue-col-1 "我唔知道佢去咗边度。"
gen Sinji yue-col-2 "呢本书系我嘅，佢睇咗好开心。"
gen Sinji yue-col-3 "今日冇雨，我哋去街市买餸。"

echo "== ITN probes (cmn, auto) ==" | tee -a results/A0-smoke.jsonl
for f in itn-money itn-decimal itn-date; do
  "$BIN" --wav "smoke/$f.wav" --lang auto | tee -a results/A0-smoke.jsonl
done

echo "== yue colloquial probes (auto then forced yue) ==" | tee -a results/A0-smoke.jsonl
for f in yue-col-1 yue-col-2 yue-col-3; do
  "$BIN" --wav "smoke/$f.wav" --lang auto | tee -a results/A0-smoke.jsonl
  "$BIN" --wav "smoke/$f.wav" --lang yue  | tee -a results/A0-smoke.jsonl
done
