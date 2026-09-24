#!/usr/bin/env node
// Spike-only: ADR-0004 gate #3 - can the rewrite-role holder (SmolLM2-1.7B-Instruct,
// the model already resident for English break placement) place paragraph breaks in
// Chinese text well enough to be eligible for the zh profile?
//
// The call is byte-identical to production: this imports the product's own
// `createBreakPlacementHttpAdapter` (system prompt + request body + temp 0 +
// max_tokens 32) and the product's own `repairBreakIndices` parser. It only injects a
// fetch that records latency and raises the abort budget from the product's 300 ms to
// the spike's 5000 ms, so slow replies are measured rather than aborted.
//
// Not product code. See README.md §Gate #3 and results/breaks-eval.json.

import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const { createBreakPlacementHttpAdapter } = require(path.join(ROOT, "electron/breakPlacementHttpAdapter.js"));
const { repairBreakIndices } = require(path.join(ROOT, "electron/paragraphBreaks.js"));

const PORT = 8188;
const REPS = 5;
const CHAT_URL = `http://127.0.0.1:${PORT}/v1/chat/completions`;
const CASES = JSON.parse(readFileSync(path.join(HERE, "breaks-cases.json"), "utf8")).cases;

const timings = [];
const adapter = createBreakPlacementHttpAdapter({
  chatCompletionsUrl: () => CHAT_URL,
  requestTimeoutMs: 5000,
  fetchImpl: async (url, init) => {
    const started = performance.now();
    const response = await fetch(url, init);
    timings.push(performance.now() - started);
    return response;
  },
});

function numbersIn(reply) {
  return [...String(reply).matchAll(/(?<![\w.])-?\d+(?:\.\d+)?(?![\w.])/g)].map((m) => Number(m[0]));
}

function isNone(reply) {
  return /\bnone\b|\bno breaks?\b/i.test(String(reply));
}

function sameSet(a, b) {
  const left = [...new Set(a)].sort((x, y) => x - y);
  const right = [...new Set(b)].sort((x, y) => x - y);
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

async function waitForHealth(attempts = 240) {
  for (let i = 0; i < attempts; i += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${PORT}/health`);
      if (response.ok) return true;
    } catch {
      // not up yet
    }
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
  return false;
}

async function main() {
  const server = spawn(
    path.join(ROOT, "resources/bin/llama/llama-server"),
    ["--model", path.join(ROOT, "resources/models/smollm2-1.7b-instruct-q4_k_m.gguf"),
     "--port", String(PORT), "--ctx-size", "2048"],
    { stdio: ["ignore", "ignore", "ignore"] },
  );
  const stop = () => { try { server.kill(); } catch { /* already gone */ } };
  process.on("exit", stop);

  if (!(await waitForHealth())) {
    stop();
    throw new Error("llama-server did not become healthy");
  }

  const results = [];
  for (const testCase of CASES) {
    const reps = [];
    for (let rep = 0; rep < REPS; rep += 1) {
      const before = timings.length;
      const reply = await adapter.placeParagraphBreaks(testCase.sentences);
      const parsed = repairBreakIndices(reply, testCase.sentences.length);
      reps.push({
        reply,
        indices: parsed.indices,
        formatValid: parsed.formatValid,
        repairUsed: parsed.repairUsed,
        sentenceOne: !isNone(reply) && numbersIn(reply).includes(1),
        exact: sameSet(parsed.indices, testCase.expected),
        latencyMs: Math.round(timings.slice(before).reduce((a, b) => a + b, 0)),
      });
    }
    results.push({ ...testCase, reps });
    const exact = reps.filter((rep) => rep.exact).length;
    console.log(
      `${testCase.id.padEnd(24)} expected=[${testCase.expected}] ` +
      `exact ${exact}/${REPS}  fmt ${reps.filter((r) => r.formatValid).length}/${REPS}  ` +
      `s1 ${reps.filter((r) => r.sentenceOne).length}/${REPS}  ` +
      `median ${Math.round(median(reps.map((r) => r.latencyMs)))}ms  reply="${reps[0].reply.replace(/\n/g, " | ")}"`,
    );
  }

  const all = results.flatMap((testCase) => testCase.reps);
  const warm = timings.slice(2); // first calls carry the warm-up; report the rest
  const summary = {
    model: "SmolLM2-1.7B-Instruct-Q4_K_M",
    repsPerCase: REPS,
    cases: results.length,
    formatValidRate: all.filter((rep) => rep.formatValid).length / all.length,
    sentenceOneRate: all.filter((rep) => rep.sentenceOne).length / all.length,
    exactRate: all.filter((rep) => rep.exact).length / all.length,
    repairedRate: all.filter((rep) => rep.repairUsed).length / all.length,
    latencyMs: {
      median: Math.round(median(warm)),
      min: Math.round(Math.min(...warm)),
      max: Math.round(Math.max(...warm)),
      overProductTimeout300: warm.filter((value) => value > 300).length,
      samples: warm.length,
    },
    perCase: results.map((testCase) => ({
      id: testCase.id,
      bucket: testCase.bucket,
      sentences: testCase.sentences.length,
      expected: testCase.expected,
      answers: [...new Set(testCase.reps.map((rep) => JSON.stringify(rep.indices)))],
      exact: testCase.reps.filter((rep) => rep.exact).length,
      formatValid: testCase.reps.filter((rep) => rep.formatValid).length,
      sentenceOne: testCase.reps.filter((rep) => rep.sentenceOne).length,
      medianMs: Math.round(median(testCase.reps.map((rep) => rep.latencyMs))),
    })),
  };

  mkdirSync(path.join(HERE, "results"), { recursive: true });
  writeFileSync(path.join(HERE, "results/breaks-eval.json"), JSON.stringify(summary, null, 2));
  console.log("\n" + JSON.stringify({ ...summary, perCase: undefined }, null, 2));
  stop();
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
