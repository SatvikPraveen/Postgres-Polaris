# Benchmarks

A small, reproducible performance harness built on `pgbench`.

```bash
make bench                                   # full sweep: 5 workloads x 5 client counts x 3 reps x 30 s
CLIENTS="1 8" DURATION=20 REPS=5 make bench  # custom sweep
WORKLOADS="spatial_knn" make bench           # one workload
make bench-report                            # re-summarise the latest run
```

## Workloads

| File | Path exercised |
|---|---|
| `oltp_checkout.sql` | Write transaction: order, 2 items, payment; FK checks, statement-level trigger, WAL |
| `point_lookup.sql` | Primary-key lookup plus `LATERAL` top-5 recent orders |
| `spatial_knn.sql` | GiST KNN (`<->`) over points of interest with geodesic distance |
| `fulltext_search.sql` | `websearch_to_tsquery` + `ts_rank_cd` over a GIN-indexed `tsvector` |
| `analytic_rollup.sql` | 30-day window, 3-way join, `GROUP BY ROLLUP` |

## Method

1. A dedicated database is built from `(scale, seed)` with `scripts/build_db.sh`, vacuumed and analysed, so every run starts from byte-identical data.
2. Each cell (workload x clients) runs a discarded warm-up, then a timed run. Repetitions are interleaved across cells, so slow drift such as thermal throttling spreads evenly instead of biasing one configuration.
3. `pgbench --random-seed` is fixed per repetition, so the request stream is reproducible.
4. Per-transaction latencies are sampled (`-l --sampling-rate`) and kept with the run.
5. `environment.json` records the server version, every non-default setting, the container image, host CPU and memory, the dataset provenance (`meta.dataset`), and the git commit, including whether the tree was dirty.

## Statistics (`analyze.py`, standard library only)

- **Throughput** is the mean of per-repetition TPS with a two-sided 95% Student-t interval. Repetitions are the independent units; individual transactions within one run are not.
- **CV** is the coefficient of variation across repetitions. Above 5% the host was noisy and the cell should be re-run.
- **Latency** is p50, p95 and p99 of the pooled samples. Each comes with a distribution-free 95% interval from binomial order statistics.
- **Scaling efficiency** is `TPS(c) / (c x TPS(1))`.

## Reporting results

Quote the table from `report.md` together with `environment.json`. Numbers measured on a laptop inside Docker are only comparable with other runs on the same machine. Treat them as relative evidence, such as before and after an index or setting change, not as absolute capacity.
