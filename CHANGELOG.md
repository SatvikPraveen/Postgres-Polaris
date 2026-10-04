# Changelog

All notable changes are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.1.0] - 2026-10-04

The first release in which every file runs. The previous version did not build, and most modules failed on their first statement.

### Added
- **Synthetic data generator.** Deterministic and scalable, using a counter-based RNG. It ships with provenance (`meta.dataset`), content fingerprints (`meta.fingerprint()`), planted effects with known parameters, and 2,755 labelled anomalies.
- **Single build entry point.** `sql/build.sql` builds everything; the first container boot builds the dataset automatically.
- **pgTAP suite.** 361 tests covering schema, constraint rejection paths, dataset invariants and regressions.
- **Verification tooling.** `scripts/check_modules.sh` proves all 39 modules are standalone and idempotent. `scripts/reproduce.sh` checks for bit-identical datasets across planner settings. `scripts/backup_demo.sh` verifies each restore by fingerprint.
- **Benchmark harness.** Five pgbench workloads, environment capture, and statistics with confidence intervals.
- **CI.** GitHub Actions on PostgreSQL 17 and 18.
- **Capstones scored against ground truth.** Anomaly detectors report precision, recall and F1. The service-equity estimate is compared with the planted gradient. Also a 15-minute-city accessibility study and SQL routing (Dijkstra and A*).
- **Documentation.** Dataset card, reproducibility guide, citation metadata.

### Changed
- **Docker image.** Multi-arch `postgres:17-bookworm` with PostGIS 3.6, pg_cron, pg_partman 5, pgTAP, HypoPG, pgvector and pg_stat_kcache. Server configuration is versioned in the repo, and data checksums are on.
- **Consistent identity.** One container, database and user name everywhere.
- **Geodesic measurement.** All distances, areas and lengths use geodesic `geography`. Web Mercator overstated them by about 19% at this latitude.
- **Order totals trigger.** It is now statement-level with transition tables, and recomputes amounts in a single consistent update.

### Fixed
- **Broken function bodies.** Single-`$` bodies that never compiled.
- **Seed data.** It violated its own foreign keys and used enum values that did not exist.
- **Order totals.** The trigger violated `chk_order_total` on every item insert.
- **Duplicate keys.** Unique constraints and indexes were declared twice. Clock-dependent CHECK constraints were removed.
- **PostgreSQL 18 compatibility.** Fractional `Actual Rows` in EXPLAIN output, and the replacement of `pg_stat_io.op_bytes`.
- **Commit identity.** Author and committer identity normalised across the full history.

## [1.0.0] - 2025

- Initial curriculum outline.
