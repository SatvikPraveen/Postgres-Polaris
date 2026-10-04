# Learning Paths

The curriculum has 16 module directories, `sql/01_schema_design` to `sql/16_capstones`. Every file from module 02 onwards needs only the base dataset and can be re-run safely, so you can follow any order. This page suggests orders by role.

Run any file with `make module F=<path>`, or open it in `make psql` and work through it statement by statement. Each file starts with a comment block describing what it teaches. Setup is covered in [HOWTO_SETUP.md](HOWTO_SETUP.md).

Times are rough estimates for reading the file, running it and changing a few queries. They are not measured.

## Module map

| Module | Files | Topic |
|---|---|---|
| `01_schema_design` | `civics`, `commerce`, `mobility`, `geo`, `documents` | The five domain schemas of Polaris City (read only; `make build` runs them) |
| `02_constraints_indexes` | `constraints`, `indexing_basics`, `specialist_indexes` | Constraints; B-tree, GIN, GiST, BRIN, partial, covering and Bloom indexes; HypoPG |
| `03_dml_queries` | `practice_selects`, `window_cts_recursion`, `seed_data` | Joins, aggregates, grouping sets, window functions, CTEs, recursion; the data generator |
| `04_views_matviews` | `views`, `materialized_views` | View layers, materialized views, `REFRESH ... CONCURRENTLY` |
| `05_functions_triggers` | `plpgsql_basics`, `triggers_auditing`, `event_triggers` | Functions, volatility, error handling, row and statement triggers, JSONB audit trail, DDL guards |
| `06_jsonb_fulltext` | `jsonb_modeling_validation`, `fulltext_search_ranking` | JSONB modelling and validation, `JSON_TABLE`, full-text search, ranking, trigram matching |
| `07_geospatial` | `postgis_basics`, `spatial_indexes_queries`, `routing_nearest` | SRIDs, geometry vs geography, GiST, KNN, routing in SQL |
| `08_partitioning_timeseries` | `declarative_partitioning`, `time_bucketing_retention` | Range/list/hash partitioning, pruning, pg_partman, time buckets, retention |
| `09_data_movement` | `copy_bulk_operations`, `postgres_fdw_federation` | `COPY`, `ON_ERROR`, `MERGE` upserts, file_fdw, postgres_fdw push-down |
| `10_tx_mvcc_locks` | `transactions_isolation`, `mvcc_visibility_demos`, `lock_scenarios` | Isolation levels and anomalies, tuple visibility, VACUUM, lock conflicts, deadlocks |
| `11_perf_tuning` | `explain_analyze_playbook`, `index_advisor_patterns`, `stats_and_autovacuum` | Reading plans, pg_stat_statements, index advice, extended statistics, autovacuum |
| `12_security_rls` | `rls_policies`, `column_privacy_masks` | Row-level security for tenants, column grants, masking views, pgcrypto |
| `13_backup_replication` | `backup_restore_playbook`, `point_in_time_recovery`, `logical_replication_demo` | pg_dump/pg_restore, WAL and PITR, publications, slots, logical decoding |
| `14_async_patterns` | `listen_notify_pubsub`, `advisory_locks_coordination`, `pg_cron_scheduled_jobs` | LISTEN/NOTIFY, advisory locks, `SKIP LOCKED` queues, pg_cron |
| `15_testing_quality` | `data_quality_checks`, `pgtap_unit_tests`, `performance_regression_tests` | Rule-driven data quality, pgTAP, query performance regression tests |
| `16_capstones` | `citywide_analytics_dashboard`, `geo_accessibility_study`, `anomaly_detection_patterns`, `real_time_monitoring_views` | End-to-end projects |

## Shared foundation (all roles)

**Time:** 2-3 hours. **Prerequisites:** basic SQL (`SELECT`, `JOIN`, `GROUP BY`).

1. `examples/quick_demo.sql`: a tour of the dataset.
2. Skim `sql/01_schema_design/*.sql` to learn the five schemas and how they relate.
3. `sql/03_dml_queries/practice_selects.sql`
4. `sql/03_dml_queries/window_cts_recursion.sql`

**You can now** navigate the `civics`, `commerce`, `mobility`, `geo` and `documents` schemas, write window functions and recursive CTEs against them, and anchor time windows on `meta.as_of()` rather than `now()`.

## Application developer

**Time:** 12-16 hours. **Prerequisites:** the shared foundation; experience writing an application against a SQL database.

| Order | File | Focus |
|---|---|---|
| 1 | `sql/02_constraints_indexes/constraints.sql`, `indexing_basics.sql` | Let the database enforce rules; pick an index type |
| 2 | `sql/05_functions_triggers/plpgsql_basics.sql`, `triggers_auditing.sql` | Business logic and auditing in the database |
| 3 | `sql/06_jsonb_fulltext/jsonb_modeling_validation.sql`, `fulltext_search_ranking.sql` | Flexible documents and search without another service |
| 4 | `sql/09_data_movement/copy_bulk_operations.sql` | Bulk loads and `MERGE` upserts |
| 5 | `sql/10_tx_mvcc_locks/transactions_isolation.sql`, `lock_scenarios.sql` | Lost updates, write skew, retries, deadlocks |
| 6 | `sql/12_security_rls/rls_policies.sql` | Tenant isolation with `SET ROLE` and session settings |
| 7 | `sql/14_async_patterns/listen_notify_pubsub.sql`, `advisory_locks_coordination.sql` | Events and job queues inside PostgreSQL |
| 8 | `sql/15_testing_quality/pgtap_unit_tests.sql` | Unit tests for schema and functions |

**You can now** choose an isolation level and handle serialization failures, build a `SKIP LOCKED` job queue, enforce tenant boundaries with RLS, and cover your schema with pgTAP tests that run in CI.

## Data analyst

**Time:** 10-14 hours. **Prerequisites:** the shared foundation.

| Order | File | Focus |
|---|---|---|
| 1 | `sql/04_views_matviews/views.sql`, `materialized_views.sql` | A reusable reporting layer |
| 2 | `sql/06_jsonb_fulltext/jsonb_modeling_validation.sql` | Querying semi-structured fields with SQL/JSON and `JSON_TABLE` |
| 3 | `sql/07_geospatial/postgis_basics.sql`, `spatial_indexes_queries.sql` | Distances, containment and neighbourhood joins |
| 4 | `sql/08_partitioning_timeseries/time_bucketing_retention.sql` | Time buckets, gap filling, roll-ups |
| 5 | `sql/15_testing_quality/data_quality_checks.sql` | Checking the data before reporting on it |
| 6 | `examples/analytics_showcase.sql` | Worked analytical queries |
| 7 | `sql/16_capstones/citywide_analytics_dashboard.sql` | Capstone: KPIs, period-over-period, cohorts, `ROLLUP` |

**You can now** build a KPI layer with materialized views that refresh without blocking readers, compute period-over-period and cohort metrics, answer spatial questions with PostGIS, and back a number with a data-quality check.

## DBA / SRE

**Time:** 16-20 hours. **Prerequisites:** the shared foundation; comfort with a shell and Docker.

| Order | File | Focus |
|---|---|---|
| 1 | `sql/02_constraints_indexes/indexing_basics.sql`, `specialist_indexes.sql` | Index types and their costs |
| 2 | `sql/10_tx_mvcc_locks/mvcc_visibility_demos.sql`, `lock_scenarios.sql` | Dead tuples, VACUUM, freezing, lock monitoring |
| 3 | `sql/11_perf_tuning/explain_analyze_playbook.sql` | Reading `EXPLAIN (ANALYZE, BUFFERS)`, pg_stat_statements |
| 4 | `sql/11_perf_tuning/index_advisor_patterns.sql`, `stats_and_autovacuum.sql` | Unused and missing indexes, HypoPG, statistics, autovacuum settings |
| 5 | `sql/08_partitioning_timeseries/declarative_partitioning.sql` | Partition maintenance with pg_partman |
| 6 | `sql/12_security_rls/column_privacy_masks.sql` | Least privilege and PII handling |
| 7 | `sql/13_backup_replication/*.sql`, then `make backup` | Logical backups, PITR concepts, logical replication |
| 8 | `sql/14_async_patterns/pg_cron_scheduled_jobs.sql` | Scheduled maintenance |
| 9 | `sql/15_testing_quality/performance_regression_tests.sql`, `make bench` | Detecting slowdowns with measurements |
| 10 | `sql/16_capstones/real_time_monitoring_views.sql` | Capstone: a health view over the statistics views |

[EXPLAIN_PLAN_LIBRARY.md](EXPLAIN_PLAN_LIBRARY.md) is a useful companion for steps 3 and 4.

**You can now** diagnose a slow query from its plan and pg_stat_statements, decide whether an index is worth building before building it, tune autovacuum per table, take and verify a backup, set up a logical replication slot and monitor its lag, and build a dashboard of blocking sessions, bloat and wraparound risk.

## Data / ML researcher

**Time:** 12-18 hours. **Prerequisites:** the shared foundation; basic statistics (regression, precision and recall).

The dataset is synthetic with known structure, so analyses can be checked against the truth:

- `meta.planted_effects` lists each planted effect with its true parameter, for example `complaint_resolution_income_gradient` (-0.25), `peak_hour_bus_delay_ratio` (3.0), `turnout_age_slope` (0.035) and `merchant_popularity_zipf_exponent` (1.10).
- `meta.ground_truth` labels every injected anomaly by `entity`, `entity_id` and `label`: sensor `spike`, `dropout` and `level_shift`, and `order_amount_outlier`.
- `meta.dataset` records scale, seed and generator version; `meta.fingerprint()` hashes every table. The same `(scale, seed)` always produces the same data (`make reproduce` checks this).

```sql
SELECT effect, parameter, true_value FROM meta.planted_effects ORDER BY domain;
SELECT entity, label, count(*) FROM meta.ground_truth GROUP BY 1, 2;
```

| Order | File | What you verify |
|---|---|---|
| 1 | `sql/03_dml_queries/seed_data.sql` (read the header and section 0) | How the counter-based generator and the effects are defined |
| 2 | `sql/03_dml_queries/practice_selects.sql`, `examples/analytics_showcase.sql` | Recover the peak delay ratio and the Zipf exponent |
| 3 | `sql/08_partitioning_timeseries/time_bucketing_retention.sql` | A simple bucket-level detector scored against `meta.ground_truth` |
| 4 | `sql/15_testing_quality/data_quality_checks.sql` | Data-quality rules scored for precision, recall and F1 |
| 5 | `sql/16_capstones/citywide_analytics_dashboard.sql` | Fixed-effects OLS estimate of the income gradient, with standard error and 95% CI, against the true -0.25 |
| 6 | `sql/16_capstones/anomaly_detection_patterns.sql` | Z-score, robust MAD, seasonal and CUSUM detectors, compared per label |
| 7 | `sql/16_capstones/geo_accessibility_study.sql` | An equity study whose correct answer is a null result: no access-income effect was planted |

Open exercises with no reference solution in the repo:

- Estimate `turnout_age_slope` and `turnout_income_slope` from `civics` and compare them with the planted logit coefficients.
- Recover `peak_hour_road_speed_factor` (0.70) and `order_growth_exponent` (0.85).
- Rebuild a scratch database at another seed (`scripts/build_db.sh -s 1 -r 7 -d seed7`) and check whether your estimator is stable across seeds or whether you tuned it to seed 42.

**You can now** estimate an effect in SQL and report it with an interval, score an anomaly detector honestly against labels, recognise when a null result is the right answer, and make a result reproducible by citing `(scale, seed, generator_version)`.

## Combining paths

The paths overlap. A full-stack route is the shared foundation, the application developer path, then the DBA/SRE steps you have not done. Everyone should finish with at least one file from `sql/16_capstones`. `make build-all` runs all modules in order if you want every object in place to explore.
