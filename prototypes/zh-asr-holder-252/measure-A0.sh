#!/usr/bin/env bash
# Spike-only measurement runner for ADR-0004 gate #1, candidate A0.
# Adds the paragraph length class (L1) and resident memory (C7/M1):
#   - A0 SenseVoiceSmall (via FluidAudio)
#   - the current Parakeet holder, for comparison
#   - the rewrite-role llama-server + SmolLM2 GGUF, so "never two speech models"
#     can be judged against the documented ~1 GB baseline (app-size.md)
# TTS clips only: coarse screening, never the accuracy bar.
#
# Usage: ./measure-A0.sh
set -euo pipefail
cd "$(dirname "$0")"

ROOT=../../..
BIN=harness-fluidaudio/.build/release/zh-smoke
FIFO=results/.measure-in
export REGISTRY_URL="${REGISTRY_URL:-https://hf-mirror.com}"
mkdir -p results

gen() { # voice name text
  say -v "$1" -o "smoke/$2.aiff" "$3"
  afconvert -f WAVE -d LEI16@16000 -c 1 "smoke/$2.aiff" "smoke/$2.wav"
  rm -f "smoke/$2.aiff"
}

# --- 1. paragraph length class (target 15-30 s) ---------------------------
gen Tingting cmn-para "我们在做一个本地优先的语音听写工具。所有音频都不会离开这台电脑，也不会有任何账号或者订阅。目标是让写代码的人按住一个键说话，松手以后文字就落在光标的位置。今天测试一个比较长的段落，看看延迟是不是仍然在预算之内，同时确认输出里有没有标点符号。"
gen Sinji yue-para "你好，呢個係一個粵語嘅段落測試。我想試下比較長嘅句子，睇下轉寫會唔會準確，同埋延遲會唔會超出預算。所有音頻都唔會離開呢部電腦，亦都唔需要任何帳號。"

for f in cmn-para yue-para; do
  "$BIN" --wav "smoke/$f.wav" --lang auto | tee -a results/A0-smoke.jsonl
done

# --- 2. resident memory ---------------------------------------------------
rss_of() { ps -o rss= -p "$1" 2>/dev/null | tr -d ' ' || true; }

measure_idle() { # label binary logfile
  local label=$1 binary=$2 log=$3 pid kb
  rm -f "$FIFO"; mkfifo "$FIFO"
  "$binary" < "$FIFO" > "$log" 2>/dev/null &
  pid=$!
  exec 3>"$FIFO"
  local ready=no
  for _ in $(seq 1 240); do
    if grep -q '"event":"ready"' "$log" 2>/dev/null; then ready=yes; break; fi
    sleep 0.5
  done
  if [[ "$ready" != yes ]]; then
    echo "{\"event\":\"rss\",\"candidate\":\"$label\",\"error\":\"not ready in 120s\"}" | tee -a results/A0-smoke.jsonl
  else
    sleep 3
    kb=$(rss_of "$pid")
    echo "{\"event\":\"rss\",\"candidate\":\"$label\",\"resident_mb\":$(( ${kb:-0} / 1024 ))}" | tee -a results/A0-smoke.jsonl
  fi
  kill "$pid" 2>/dev/null || true
  exec 3>&-
  rm -f "$FIFO"
}

measure_idle "A0-sensevoice" "$BIN" results/.rss-a0.log
measure_idle "parakeet-current" "$ROOT/resources/bin/transcription-helper" results/.rss-pk.log

# --- 3. rewrite role (llama-server + SmolLM2), measured not assumed -------
LLAMA=$ROOT/resources/bin/llama/llama-server
MODEL=$ROOT/resources/models/smollm2-1.7b-instruct-q4_k_m.gguf
if [[ -x "$LLAMA" && -f "$MODEL" ]]; then
  "$LLAMA" --model "$MODEL" --port 8199 --ctx-size 2048 > results/.rss-llama.log 2>&1 &
  LPID=$!
  for _ in $(seq 1 360); do
    curl -sf http://127.0.0.1:8199/health >/dev/null 2>&1 && break
    sleep 0.5
  done
  sleep 2
  kb=$(rss_of "$LPID")
  echo "{\"event\":\"rss\",\"candidate\":\"llama-server-smollm2\",\"resident_mb\":$(( ${kb:-0} / 1024 ))}" | tee -a results/A0-smoke.jsonl
  kill "$LPID" 2>/dev/null || true
else
  echo "{\"event\":\"rss\",\"candidate\":\"llama-server-smollm2\",\"error\":\"binary or model missing\"}" | tee -a results/A0-smoke.jsonl
fi

echo "== raw records: results/A0-smoke.jsonl ==" >&2
