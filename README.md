<div align="center">

# PostgreSQL Polaris

**A reproducible PostgreSQL laboratory: a 16-module curriculum, a synthetic city with planted ground truth, and the tooling to prove every result.**

[![CI](https://github.com/SatvikPraveen/Postgres-Polaris/actions/workflows/ci.yml/badge.svg)](https://github.com/SatvikPraveen/Postgres-Polaris/actions/workflows/ci.yml)
![PostgreSQL](https://img.shields.io/badge/PostgreSQL-17%20%7C%2018-336791?logo=postgresql&logoColor=white)
![PostGIS](https://img.shields.io/badge/PostGIS-3.6-5A9E3C)
![Tests](https://img.shields.io/badge/pgTAP-361%20tests-success)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

</div>

---

Most database tutorials stop at "the query ran". Polaris asks a stricter question: **did it return the right answer?**

The database ships with *Polaris City*, a deterministic synthetic city of about 420,000 rows. It covers residents, merchants, orders, transit, sensors, streets and 311 complaints, all generated inside PostgreSQL. Known effects are planted into the data, and anomalies are labelled. So a regression either recovers the true coefficient or it does not, and an anomaly detector gets a precision and recall, not an impression.

```sql
-- Does complaint resolution time depend on neighbourhood income?
WITH c AS (
    SELECT ln(extract(epoch FROM resolved_at - submitted_at) / 86400) AS log_days, category,
           ln(n.median_income / 58000.0) / 0.35                        AS income_z
    FROM documents.complaint_records JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
    WHERE resolved_at IS NOT NULL
), within AS (
    SELECT log_days - avg(log_days) OVER w AS y, income_z - avg(income_z) OVER w AS x
    FROM c WINDOW w AS (PARTITION BY category)
)
SELECT round(regr_slope(y, x)::numeric, 3) AS estimated,
       (SELECT true_value FROM meta.planted_effects
         WHERE effect = 'complaint_resolution_income_gradient')     AS planted
FROM within;
```
```
 estimated | planted
-----------+---------
    -0.258 |   -0.25
```

## Highlights

- **Ground truth built in.** Ten planted effects in `meta.planted_effects` and 2,755 labelled anomalies in `meta.ground_truth`. The capstones score themselves against both.
- **Deterministic at any scale.** A counter-based RNG makes the data depend only on `(scale, seed)`, not on plans, memory or parallelism. `make reproduce` proves it, and PostgreSQL 17 and 18 produce identical fingerprints.
- **Verified, not just written.** 361 pgTAP tests cover schema, every constraint's rejection path, and data invariants. All 39 module files are checked to run standalone and idempotently on a fresh database, in CI, on two major versions.
- **Modern PostgreSQL.** The curriculum uses PostgreSQL 17 and 18 features: `JSON_TABLE`, `MERGE ... RETURNING`, `COPY ... ON_ERROR`, `EXPLAIN (SERIALIZE, MEMORY)` and `pg_stat_io`. It also uses PostGIS 3.6, pg_partman 5, pg_cron, HypoPG, pgvector and pg_stat_kcache.
- **Measured performance.** A pgbench harness records its full environment and reports throughput and latency percentiles with 95% confidence intervals.

## Quick start

Requires Docker with Compose v2 and about 4 GB of RAM. It runs natively on x86-64 and Apple Silicon.

```bash
git clone https://github.com/SatvikPraveen/Postgres-Polaris.git
cd Postgres-Polaris
make bootstrap      # create .env files, build the image
make up             # start PostgreSQL 17; first boot generates the city (~30 s)
make psql           # you are in
```

```sql
SELECT generator_version, scale, seed, as_of FROM meta.dataset;
\i /examples/quick_demo.sql          -- a five-minute guided tour
```

Run `make help` for every target. `make ui` adds Adminer (`:8080`) and pgAdmin (`:8081`).

## Curriculum

Each module is a set of commented, executable SQL files. Run one with `make module F=<path>`, or all of them with `make build-all`.

| # | Module | What you build and measure |
|---|---|---|
| 01 | [Schema design](sql/01_schema_design) | Five normalised domains, enums, PostGIS geometry, JSONB documents |
| 02 | [Constraints and indexes](sql/02_constraints_indexes) | CHECK, exclusion and deferrable constraints. B-tree, hash, GIN, GiST, SP-GiST, BRIN (minmax-multi) and bloom indexes. HypoPG what-if indexes |
| 03 | [Queries](sql/03_dml_queries) | Joins, grouping sets, window frames (`GROUPS`, `EXCLUDE`), recursive CTEs with `SEARCH`/`CYCLE` |
| 04 | [Views](sql/04_views_matviews) | Updatable and `security_invoker` views, materialized views with `REFRESH CONCURRENTLY` |
| 05 | [Functions and triggers](sql/05_functions_triggers) | PL/pgSQL, `BEGIN ATOMIC`, generic audit triggers, transition tables, event triggers |
| 06 | [JSONB and full-text](sql/06_jsonb_fulltext) | jsonpath, `JSON_TABLE`, GIN operator classes, ranked search, trigram typo tolerance |
| 07 | [Geospatial](sql/07_geospatial) | Geodesic measurement, KNN, spatial indexes, Dijkstra and A* routing in SQL |
| 08 | [Partitioning](sql/08_partitioning_timeseries) | Range, list and hash partitioning, pruning, `DETACH CONCURRENTLY`, pg_partman, exact time-bucket rollups |
| 09 | [Data movement](sql/09_data_movement) | `COPY` with error tolerance, file_fdw, postgres_fdw federation with remote-plan inspection |
| 10 | [Transactions and MVCC](sql/10_tx_mvcc_locks) | Isolation anomalies and the lock-conflict matrix measured live, page-level MVCC, freezing |
| 11 | [Performance tuning](sql/11_perf_tuning) | Plan reading, join strategies, spills, extended statistics, an index advisor, autovacuum |
| 12 | [Security](sql/12_security_rls) | Row-level security as real roles, column privileges, `security_barrier`, pgcrypto |
| 13 | [Backup and replication](sql/13_backup_replication) | Logical decoding, filtered publications, PITR primitives, PostgreSQL 17 incremental backup |
| 14 | [Async patterns](sql/14_async_patterns) | LISTEN/NOTIFY, advisory locks, `SKIP LOCKED` queues, pg_cron |
| 15 | [Testing and quality](sql/15_testing_quality) | Data-quality rule engine, pgTAP, timing and plan-shape regression detection |
| 16 | [Capstones](sql/16_capstones) | Anomaly detection scored by F1, service-equity estimation, 15-minute-city accessibility, monitoring |

Suggested orders for developers, analysts, DBAs and researchers are in [docs/LEARNING_PATHS.md](docs/LEARNING_PATHS.md).

## The dataset

| Domain | Tables | Rows at scale 1 |
|---|---|---:|
| Civics | citizens, permits, tax payments, voting records | 50,083 |
| Commerce | merchants, licences, orders, order items, payments | 212,371 |
| Mobility | stations, hourly inventory, trip segments, sensor readings | 198,627 |
| Geography | 24 neighbourhoods, 1,067 road segments, 600 points of interest | 1,691 |
| Documents | 311 complaints with free text, versioned JSONB policies | 5,135 |

Change the size with `make build SCALE=5 SEED=7`. The [dataset card](docs/DATASET.md) documents the generative model, every planted effect with its recovered estimate, the ground-truth labels and the known limitations.

## Verification

| Command | What it proves |
|---|---|
| `make test` | 361 pgTAP assertions: schema shape, every constraint rejects bad data with the right SQLSTATE, money adds up, no event after `as_of`, polygons tile the city |
| `make test-modules` | All 39 module files run twice, with `ON_ERROR_STOP`, each on its own fresh database |
| `make reproduce` | Two builds under different planner settings produce identical content fingerprints for every table |
| `make backup` | A `pg_dump` restore is fingerprint-identical to its source |
| `make check` | All of the above, plus linting. This is what CI runs on PostgreSQL 17 and 18 |

## Benchmarks

```bash
make bench                                   # 5 workloads x 5 client counts x 3 repetitions
CLIENTS="1 8" DURATION=20 REPS=5 make bench  # custom sweep
```

The workloads cover an OLTP checkout, point lookups, GiST nearest-neighbour search, ranked full-text search and an analytical rollup. Each run writes its environment, raw per-transaction latency samples and a report. The report gives mean TPS with Student-t confidence intervals and p50, p95 and p99 latency with distribution-free intervals. See [benchmarks/README.md](benchmarks/README.md).

## Repository layout

```
docker/        image (PostgreSQL 17/18 + extensions), compose stack, server config, first-boot init
sql/           build.sql entry point and modules 00-16
tests/         pgTAP suites and benchmark queries
examples/      runnable showcases (quick tour, analytics, geospatial, tuning, security)
benchmarks/    pgbench workloads, runner, statistical analysis
scripts/       build, run, module check, reproduce, verified backup, reset
data/          small sample files used by the COPY and file_fdw lessons
docs/          setup, troubleshooting, learning paths, exercises, plan library, dataset card
```

## Documentation

- [Setup guide](docs/HOWTO_SETUP.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Learning paths](docs/LEARNING_PATHS.md)
- [Exercises by module](docs/MODULE_MAP_EXERCISES.md)
- [EXPLAIN plan library](docs/EXPLAIN_PLAN_LIBRARY.md)
- [Dataset card](docs/DATASET.md)
- [Reproducibility](docs/REPRODUCIBILITY.md)

## Citing

If you use Polaris in research or teaching, please cite it using [CITATION.cff](CITATION.cff). GitHub's "Cite this repository" button reads it. When reporting results, include `generator_version`, `scale` and `seed` from `meta.dataset`.

## Contributing

Pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) lists the rules every module must satisfy; CI enforces them.

## License

[MIT](LICENSE) © Satvik Praveen
