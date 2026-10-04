#!/usr/bin/env python3
"""Summarise a Polaris benchmark run.

Usage: python3 benchmarks/analyze.py benchmarks/results/<run-dir>

Reads runs.csv and latency/*.log.gz produced by benchmarks/run.sh and writes
summary.csv and report.md into the same directory.

Statistics
  Throughput  mean of per-repetition TPS with a two-sided 95% Student-t
              confidence interval (repetitions are the independent units;
              transactions within a run are not independent).
  CV          coefficient of variation across repetitions; values above 5%
              mean the host was noisy and the run should be repeated.
  Latency     p50/p95/p99 of sampled per-transaction latencies pooled over
              repetitions, each with a distribution-free 95% confidence
              interval from binomial order statistics.
  Scaling     efficiency(c) = TPS(c) / (c * TPS(1)).

Standard library only, so it runs anywhere Python 3.8+ exists.
"""
from __future__ import annotations

import csv
import gzip
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

# Two-sided 97.5% quantiles of Student's t for df = 1..30; normal beyond.
T975 = [12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
        2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
        2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042]


def t_crit(df: int) -> float:
    return T975[df - 1] if 1 <= df <= 30 else 1.96


def mean_ci(xs: list[float]) -> tuple[float, float, float]:
    m = statistics.fmean(xs)
    if len(xs) < 2:
        return m, float("nan"), float("nan")
    sd = statistics.stdev(xs)
    return m, t_crit(len(xs) - 1) * sd / math.sqrt(len(xs)), sd


def quantile_ci(sorted_xs: list[float], q: float) -> tuple[float, float, float]:
    """Point estimate and distribution-free 95% CI for the q-quantile."""
    n = len(sorted_xs)
    if n == 0:
        return (float("nan"),) * 3
    k = min(n - 1, max(0, math.ceil(q * n) - 1))
    half = 1.96 * math.sqrt(n * q * (1 - q))
    lo = min(n - 1, max(0, math.floor(q * n - half) - 1))
    hi = min(n - 1, max(0, math.ceil(q * n + half) - 1))
    return sorted_xs[k], sorted_xs[lo], sorted_xs[hi]


def load_latencies(run: Path) -> dict[tuple[str, int], list[float]]:
    """pgbench -l lines: client_id txn_no time_us script_no epoch epoch_us."""
    out: dict[tuple[str, int], list[float]] = defaultdict(list)
    for f in sorted((run / "latency").glob("*")):
        name = f.name.split(".")[0]                    # <workload>_c<clients>_r<rep>
        try:
            workload, c, _rep = name.rsplit("_", 2)
            clients = int(c[1:])
        except ValueError:
            continue
        opener = gzip.open if f.suffix == ".gz" else open
        with opener(f, "rt") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3 and parts[2].isdigit():
                    out[(workload, clients)].append(int(parts[2]) / 1000.0)  # ms
    return out


def fmt(x: float, nd: int = 2) -> str:
    return "n/a" if x != x else f"{x:,.{nd}f}"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    run = Path(sys.argv[1]).resolve()
    rows = list(csv.DictReader(open(run / "runs.csv")))
    if not rows:
        print("runs.csv is empty", file=sys.stderr)
        return 1
    env = json.loads((run / "environment.json").read_text()) if (run / "environment.json").exists() else {}

    tps: dict[tuple[str, int], list[float]] = defaultdict(list)
    failed: dict[tuple[str, int], int] = defaultdict(int)
    for r in rows:
        key = (r["workload"], int(r["clients"]))
        tps[key].append(float(r["tps"]))
        failed[key] += int(r.get("failed") or 0)
    lat = load_latencies(run)

    summary = []
    for (w, c) in sorted(tps):
        m, half, sd = mean_ci(tps[(w, c)])
        base = statistics.fmean(tps[(w, 1)]) if (w, 1) in tps else float("nan")
        xs = sorted(lat.get((w, c), []))
        p50, p50lo, p50hi = quantile_ci(xs, 0.50)
        p95, p95lo, p95hi = quantile_ci(xs, 0.95)
        p99, p99lo, p99hi = quantile_ci(xs, 0.99)
        summary.append({
            "workload": w, "clients": c, "reps": len(tps[(w, c)]),
            "tps_mean": m, "tps_ci95": half, "tps_cv_pct": 100 * sd / m if m and sd == sd else float("nan"),
            "scaling_efficiency": m / (c * base) if base == base else float("nan"),
            "lat_samples": len(xs),
            "p50_ms": p50, "p50_lo": p50lo, "p50_hi": p50hi,
            "p95_ms": p95, "p95_lo": p95lo, "p95_hi": p95hi,
            "p99_ms": p99, "p99_lo": p99lo, "p99_hi": p99hi,
            "failed_txn": failed[(w, c)],
        })

    with open(run / "summary.csv", "w", newline="") as fh:
        wr = csv.DictWriter(fh, fieldnames=list(summary[0]))
        wr.writeheader()
        wr.writerows(summary)

    ds = env.get("dataset", {})
    host = env.get("host", {})
    proto = env.get("protocol", {})
    lines = [
        f"# Benchmark report `{run.name}`",
        "",
        f"PostgreSQL {env.get('server_version', '?')} on {host.get('os', '?')} {host.get('arch', '?')}, "
        f"{host.get('cpus', '?')} CPUs. Dataset scale {ds.get('scale', '?')}, seed {ds.get('seed', '?')}, "
        f"generator {ds.get('generator_version', '?')}. Commit `{env.get('git_commit', '?')}`"
        f"{' (dirty tree)' if env.get('git_dirty') else ''}.",
        "",
        f"Protocol: {proto.get('repetitions', '?')} repetitions x {proto.get('duration_s', '?')} s per cell, "
        f"{proto.get('warmup_s', '?')} s discarded warm-up, latency sampling rate {proto.get('latency_sampling_rate', '?')}.",
        "",
        "| workload | clients | TPS (mean +/- 95% CI) | CV % | scaling eff. | p50 ms [95% CI] | p95 ms [95% CI] | p99 ms [95% CI] | failed |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for s in summary:
        lines.append(
            f"| {s['workload']} | {s['clients']} | {fmt(s['tps_mean'], 0)} +/- {fmt(s['tps_ci95'], 0)} | "
            f"{fmt(s['tps_cv_pct'], 1)} | {fmt(s['scaling_efficiency'])} | "
            f"{fmt(s['p50_ms'])} [{fmt(s['p50_lo'])}, {fmt(s['p50_hi'])}] | "
            f"{fmt(s['p95_ms'])} [{fmt(s['p95_lo'])}, {fmt(s['p95_hi'])}] | "
            f"{fmt(s['p99_ms'])} [{fmt(s['p99_lo'])}, {fmt(s['p99_hi'])}] | {s['failed_txn']} |")
    noisy = [s for s in summary if s["tps_cv_pct"] == s["tps_cv_pct"] and s["tps_cv_pct"] > 5]
    if noisy:
        lines += ["", f"Warning: {len(noisy)} cell(s) have CV above 5%; the host was noisy. Re-run with more repetitions."]
    (run / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
