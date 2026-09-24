#!/usr/bin/env python3
"""results/A0.jsonl -> per (variety, class) latency + CER table, with pass/fail.

Thresholds come from `samples/README.md`'s pre-registration section and must be filled
**before** the corpus run. `None` means "not pre-registered yet" and prints as pending.

Spike-only tooling; not product code.
"""
import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
IN = ROOT / "results/A0.jsonl"

# Fill these in before running (samples/README.md pre-registration).
THRESHOLDS = {
    "median_ms": 1000,
    "p90_ms": 900,
    "cer": {"cmn": None, "yue": None},          # e.g. 0.08  (<= 8% CER)
    "dev_context_cer": {"cmn": None, "yue": None},
}


def p90(values):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, int(round(0.9 * (len(ordered) - 1))))]


def verdict(ok):
    return "pass" if ok else "FAIL"


def main() -> None:
    if not IN.exists():
        sys.exit(f"missing {IN} - run replay-A0.py first")
    rows = [json.loads(line) for line in IN.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not rows:
        sys.exit(f"{IN} is empty")

    groups = {}
    for row in rows:
        groups.setdefault((row["variety"], row["class"]), []).append(row)

    print("| variety | class | n | median ms | p90 ms | CER |")
    print("|---|---|---|---|---|---|")
    for (variety, klass), items in sorted(groups.items()):
        latencies = [item["reply_ms"] for item in items]
        cers = [item["cer"] for item in items if item.get("cer") is not None]
        cer_text = f"{statistics.mean(cers) * 100:.1f}%" if cers else "—"
        print(
            f"| {variety} | {klass} | {len(items)} | {statistics.median(latencies):.0f} | "
            f"{p90(latencies):.0f} | {cer_text} |"
        )

    print()
    print("## Pass / fail against the pre-registration")
    print()
    for variety in ("cmn", "yue"):
        latencies = [row["reply_ms"] for row in rows if row["variety"] == variety]
        cers = [row["cer"] for row in rows
                if row["variety"] == variety and row["class"] != "dev-context" and row.get("cer") is not None]
        dev = [row["cer"] for row in rows
               if row["variety"] == variety and row["class"] == "dev-context" and row.get("cer") is not None]
        if latencies:
            median, p90v = statistics.median(latencies), p90(latencies)
            print(f"- L1 {variety}: median {median:.0f} ms {verdict(median < THRESHOLDS['median_ms'])}; "
                  f"p90 {p90v:.0f} ms {verdict(p90v < THRESHOLDS['p90_ms'])}")
        for label, values, key in (
            ("A1", cers, "cer"),
            ("A2 dev-context", dev, "dev_context_cer"),
        ):
            limit = THRESHOLDS[key][variety]
            if not values:
                print(f"- {label} {variety}: no scored clips (missing references?)")
            elif limit is None:
                print(f"- {label} {variety}: CER {statistics.mean(values) * 100:.1f}% — threshold not pre-registered (pending)")
            else:
                mean = statistics.mean(values)
                print(f"- {label} {variety}: CER {mean * 100:.1f}% {verdict(mean <= limit)} (limit {limit * 100:.1f}%)")


if __name__ == "__main__":
    main()
