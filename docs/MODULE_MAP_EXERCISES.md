# Module Map and Exercises

This page maps every directory under `sql/` to its files, the concepts it teaches and the
main objects it creates, then gives 2-4 exercises per module with worked solutions.

Every solution on this page was executed against a fresh copy of the frozen base dataset
(scale 1, seed 42, PostgreSQL 17 + PostGIS 3.6). Output excerpts are pasted verbatim from
those runs. Timings, OIDs, LSNs and transaction ids will differ on your machine; every other
value should match exactly if you built the dataset with `scale=1 seed=42`.

## How to run the exercises

The base database (`sql/build.sql` without `-v modules=1`) contains the schemas, the
domain tables, the integrity constraints and the synthetic data (`make build` rebuilds it). That is enough
for modules 00, 01 and 03. Every other module creates its own objects; the exercise section
says which file to run first, for example:

```bash
make module F=sql/04_views_matviews/views.sql
# or: scripts/run_sql.sh sql/04_views_matviews/views.sql
# or, directly in the container
docker exec -i -w /sql/04_views_matviews polaris-db \
  psql -U polaris -d polaris -X -v ON_ERROR_STOP=1 -f /sql/04_views_matviews/views.sql
```

Two rules apply to every query in the curriculum:

- The dataset's "now" is `meta.as_of()` (2025-12-31 23:59:59 UTC). Recency filters use it,
  never `now()` or `CURRENT_DATE`, otherwise they return nothing once the wall clock moves on.
- Distances and areas in metres use `::geography`. Geometries are stored in SRID 4326.

## Module map

| Directory | Files | Concepts taught | Main objects created |
|---|---|---|---|
| `00_init` | `000_schemas.sql`, `005_extensions.sql`, `010_comments_conventions.sql`, `999_reset_demo_data.sql` | Schema layout, extension set, naming and commenting conventions, resetting to the pristine dataset | Schemas `civics`, `commerce`, `mobility`, `geo`, `documents`, `analytics`, `audit`, `auth`; extensions (PostGIS, pg_trgm, pgcrypto, hypopg, pg_partman, pgTAP, ...); `analytics.document_table()`, `analytics.undocumented_tables()` |
| `01_schema_design` | `civics.sql`, `commerce.sql`, `mobility.sql`, `geo.sql`, `documents.sql` | Normalised OLTP design, enums, identity keys, foreign keys, JSONB and tsvector columns, PostGIS geometry columns, maintenance triggers | 19 domain tables (for example `civics.citizens`, `commerce.orders`, `mobility.trip_segments`, `geo.neighborhood_boundaries`, `documents.complaint_records`), their enums and base indexes; helpers such as `geo.find_nearby_pois()`, `documents.search_complaints()`, `mobility.station_utilization()` |
| `02_constraints_indexes` | `constraints.sql`, `indexing_basics.sql`, `specialist_indexes.sql` | CHECK, UNIQUE, EXCLUDE and FK constraints, domains; B-tree, hash, GIN, GiST and BRIN indexes; partial, expression, covering and Bloom indexes; HypoPG | Domains (`email_address`, `us_zip_code`, ...), `analytics.validate_all_constraints()`; dozens of `idx_*` indexes; views `analytics.index_usage_stats`, `analytics.unused_indexes`; `analytics.find_redundant_indexes()`, `analytics.suggest_missing_indexes()` |
| `03_dml_queries` | `seed_data.sql`, `practice_selects.sql`, `window_cts_recursion.sql` | Deterministic data generation with planted effects; joins, aggregates, FILTER, GROUPING SETS/ROLLUP/CUBE; window functions and frames; CTEs and recursive CTEs | `meta.dataset`, `meta.planted_effects`, `meta.ground_truth`, `meta.as_of()`, `synth.*` RNG functions (the two lesson files create nothing) |
| `04_views_matviews` | `views.sql`, `materialized_views.sql` | View layer design, `CREATE OR REPLACE VIEW` limits, materialized views, `REFRESH ... CONCURRENTLY` and its unique-index requirement, refresh logging | `analytics.v_active_citizens`, `analytics.v_complaint_resolution`, `analytics.v_station_dashboard` and 7 more views; `analytics.mv_daily_city_metrics`, `analytics.mv_neighborhood_demographics`, `analytics.mv_monthly_business_performance`, `analytics.mv_mobility_patterns`; `analytics.refresh_materialized_views()`, `analytics.materialized_view_status()` |
| `05_functions_triggers` | `plpgsql_basics.sql`, `triggers_auditing.sql`, `event_triggers.sql` | Volatility, SQL-standard function bodies, error handling; row and statement triggers, WHEN clauses, transition tables, JSONB audit trail; DDL event triggers | `civics.age_on()`, `civics.apply_for_permit()`, `commerce.validate_business_license()`, `geo.calculate_distance_km()`; `audit.table_changes`, `audit.audit_table_changes()`, `audit.get_record_history()`; `audit.ddl_events` and the event trigger functions |
| `06_jsonb_fulltext` | `jsonb_modeling_validation.sql`, `fulltext_search_ranking.sql` | JSONB modelling, CHECK + jsonpath validation, GIN operator classes, SQL/JSON and `JSON_TABLE` (PG17); tsvector/tsquery, weighting, `ts_rank` vs `ts_rank_cd`, `ts_headline`, trigram typo tolerance | `civics.citizen_preferences`, `commerce.merchant_profiles`, `analytics.jsonb_merge_deep()`; `documents.complaint_search_mv`, `documents.fts_lexicon`, `documents.search_complaints_advanced()`, `documents.search_complaints_fuzzy()`, `analytics.search_city_content()` |
| `07_geospatial` | `postgis_basics.sql`, `spatial_indexes_queries.sql`, `routing_nearest.sql` | SRIDs, geometry vs geography, GiST and expression indexes on `::geography`, KNN `<->`, buffers and intersections, network routing with Dijkstra/A* in SQL | `geo.validate_coordinates()`; geography expression indexes `idx_pois_geog`, `idx_stations_geog`, `idx_roads_geog`; `geo.route_nodes`, `geo.route_edges`, `geo.dijkstra()`, `geo.shortest_path()`, `geo.nearest_node()`, `geo.analyze_service_gaps()` |
| `08_partitioning_timeseries` | `declarative_partitioning.sql`, `time_bucketing_retention.sql` | Range, list and hash partitioning, pruning, default partitions, ATTACH/DETACH, pg_partman 5; weekly partitions, retention, `date_trunc`/`date_bin` buckets, roll-ups, gap filling | `mobility.sensor_readings_part`, `commerce.orders_by_type`, `civics.citizens_hashed`, `audit.table_changes_partitioned`, `mobility.sensor_readings_partman`; `mobility.sensor_readings_ts`, `mobility.sensor_6h_aggregates`, `mobility.sensor_daily_aggregates`, `mobility.partitions_scanned()`, `mobility.apply_sensor_retention_policy()` |
| `09_data_movement` | `copy_bulk_operations.sql`, `postgres_fdw_federation.sql` | COPY in all forms, PG17 `ON_ERROR ignore`, file_fdw, staged validation, MERGE upserts, bulk-load techniques; postgres_fdw servers, user mappings, push-down | Schema `staging` (`staging.sensor_timeseries`, `staging.seed_orders`, foreign tables `staging.ext_timeseries`, `staging.ext_seed_orders`, ...); server `polaris_loopback`, schema `fdw_remote`, `analytics.regional_benchmarks` |
| `10_tx_mvcc_locks` | `transactions_isolation.sql`, `mvcc_visibility_demos.sql`, `lock_scenarios.sql` | Isolation levels and anomalies, SSI; tuple headers, pageinspect, VACUUM, visibility map, HOT; lock modes, NOWAIT, lock_timeout, SKIP LOCKED, deadlocks | `analytics.iso_*` tables and `analytics.compare_isolation_levels()`; `analytics.mvcc_lab`, `analytics.mvcc_page()`, `analytics.v_dead_tuple_overview`; `analytics.lock_*` tables, `analytics.claim_jobs()`, `analytics.monitor_locks()` |
| `11_perf_tuning` | `explain_analyze_playbook.sql`, `index_advisor_patterns.sql`, `stats_and_autovacuum.sql` | EXPLAIN options and plan reading, misestimates and sargability, pg_stat_statements; unused/redundant/missing-FK indexes, HypoPG what-if; statistics targets, extended statistics, autovacuum tuning | `analytics.explain_nodes()`, `analytics.explain_lab_payments`; `analytics.detect_unused_indexes()`, `analytics.detect_redundant_indexes()`, `analytics.detect_missing_fk_indexes()`, `analytics.plan_cost()`; `analytics.stats_lab`, `analytics.row_estimate()`, `analytics.autovacuum_thresholds()` |
| `12_security_rls` | `rls_policies.sql`, `column_privacy_masks.sql` | RLS with session context, USING vs WITH CHECK, permissive vs restrictive policies, owner bypass and FORCE RLS; column GRANTs, masking views, `security_barrier`, `security_invoker`, pgcrypto | Roles `rls_tenant_user`, `rls_table_owner`, `rls_auditor`, `privacy_clerk`, `privacy_supervisor`; `rls_demo.tenants`, `rls_demo.service_requests` and policies, `rls_demo.set_tenant()`; schema `privacy` (`privacy.citizen_profiles`, `privacy.v_citizens_masked`, mask functions) |
| `13_backup_replication` | `backup_restore_playbook.sql`, `point_in_time_recovery.sql`, `logical_replication_demo.sql` | pg_dump/pg_restore formats and options, backup catalogue; WAL positions, restore points, `pg_backup_start/stop`, PITR configuration; publications, row filters, column lists, logical decoding | `backup_mgmt.backup_jobs`, `backup_mgmt.estimate_backup_size()`; `wal_mgmt.*` functions and tables; `repl_demo.citizens_pub`, `repl_demo.orders_pub`, publications `repl_demo_*_pub`, `repl_demo.check_replication_status()` |
| `14_async_patterns` | `listen_notify_pubsub.sql`, `advisory_locks_coordination.sql`, `pg_cron_scheduled_jobs.sql` | LISTEN/NOTIFY semantics and limits, transactional outbox; session vs transaction advisory locks, SKIP LOCKED queues; pg_cron scheduling with a job log | Schema `messaging` (`message_queue`, `notification_log`, `permit_requests`, `orders_feed`, notify triggers); schema `coordination` (`job_queue`, `lock_registry`, `claim_next_task()`, `try_acquire_lock()`); schema `job_scheduler` (`scheduled_jobs`, `job_execution_log`, `cron_available()`) |
| `15_testing_quality` | `data_quality_checks.sql`, `pgtap_unit_tests.sql`, `performance_regression_tests.sql` | Rule-driven data-quality checks, PSI drift, robust z-scores scored against ground truth; pgTAP schema/constraint/function/invariant tests; median/P95 timing and plan-shape regression tests | Schema `data_quality` (`dq_rules`, `dq_results`, `run_rules()`, `order_amount_robust_z()`, `scorecard`); pgTAP suite (rolled back, creates nothing); schema `performance` (`benchmark_queries`, `baselines`, `time_query()`, `check_regressions()`) |
| `16_capstones` | `citywide_analytics_dashboard.sql`, `geo_accessibility_study.sql`, `anomaly_detection_patterns.sql`, `real_time_monitoring_views.sql` | KPI views anchored on `meta.as_of()`, fixed-effects OLS against a planted parameter; 15-minute-city accessibility and equity; robust, seasonal, CUSUM anomaly detectors scored with precision/recall; operational monitoring from statistics views | Schemas `dashboard` (`kpi_snapshot_30d`, `estimate_income_gradient()`, `monthly_activity`), `accessibility` (`residents`, `destinations`, `neighborhood_access`, `equity_stats`), `anomaly_detection` (`sensor_scores`, `sensor_evaluation`, `order_scores`), `monitoring` (`health_summary`, `data_freshness()`, `table_health`) |

`sql/build.sql` runs `00_init`, `01_schema_design`, `02_constraints_indexes/constraints.sql`
and `03_dml_queries/seed_data.sql` to build the base dataset; with `-v modules=1` it then runs
every other file in the order of the table. Each module file is idempotent and depends only
on the base dataset, so you can also run them one at a time.

## Exercises

Exercises marked **[planted]** have an answer that is known in advance: it can be checked
against `meta.planted_effects` (generative parameters) or `meta.ground_truth` (labelled
anomalies).

### Module 00: init

**00.1** Which dataset are you connected to? Show the generator version, scale, seed and
reference instant, and confirm `meta.as_of()` agrees with `meta.dataset`.

```sql
SELECT generator_version, scale, seed, as_of,
       as_of = meta.as_of() AS as_of_matches
FROM meta.dataset;
```

```text
 generator_version | scale | seed |         as_of          | as_of_matches
-------------------+-------+------+------------------------+---------------
 2.1.0             |     1 |   42 | 2025-12-31 23:59:59+00 | t
```

**00.2** The conventions file requires every base table to carry a comment. List the base
tables in the five domain schemas that have none (the expected answer is zero rows).

```sql
SELECT schema_name, table_name
FROM analytics.undocumented_tables()
WHERE schema_name IN ('civics', 'commerce', 'mobility', 'geo', 'documents');
```

```text
 schema_name | table_name
-------------+------------
```

**00.3** Which installed extensions does the curriculum rely on most? List the ten
extensions with their versions, alphabetically.

```sql
SELECT extname, extversion
FROM pg_extension
WHERE extname <> 'plpgsql'
ORDER BY extname
LIMIT 10;
```

```text
    extname    | extversion
---------------+------------
 btree_gin     | 1.3
 btree_gist    | 1.7
 citext        | 1.6
 file_fdw      | 1.0
 fuzzystrmatch | 1.2
 hstore        | 1.8
 hypopg        | 1.4.3
 intarray      | 1.5
 ltree         | 1.3
 pageinspect   | 1.12
```

### Module 01: schema design

**01.1** List every foreign key in the `commerce` schema with the referencing and
referenced columns.

```sql
SELECT c.conrelid::regclass  AS child_table,
       c.conname,
       pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
WHERE c.contype = 'f'
  AND c.connamespace = 'commerce'::regnamespace
ORDER BY 1, 2;
```

```text
        child_table         |              conname               |                                     definition
----------------------------+------------------------------------+-------------------------------------------------------------------------------------
 commerce.merchants         | merchants_owner_citizen_id_fkey    | FOREIGN KEY (owner_citizen_id) REFERENCES civics.citizens(citizen_id)
 commerce.business_licenses | business_licenses_merchant_id_fkey | FOREIGN KEY (merchant_id) REFERENCES commerce.merchants(merchant_id)
 commerce.orders            | orders_customer_citizen_id_fkey    | FOREIGN KEY (customer_citizen_id) REFERENCES civics.citizens(citizen_id) DEFERRABLE
 commerce.orders            | orders_merchant_id_fkey            | FOREIGN KEY (merchant_id) REFERENCES commerce.merchants(merchant_id)
 commerce.order_items       | order_items_order_id_fkey          | FOREIGN KEY (order_id) REFERENCES commerce.orders(order_id) ON DELETE CASCADE
 commerce.payments          | payments_order_id_fkey             | FOREIGN KEY (order_id) REFERENCES commerce.orders(order_id)
```

**01.2** Enum types sort by declaration order, not alphabetically. Count orders per status
and sort by the enum order.

```sql
SELECT status, count(*) AS orders
FROM commerce.orders
GROUP BY status
ORDER BY status;
```

```text
  status   | orders
-----------+--------
 shipped   |    149
 delivered |  46836
 cancelled |   1991
 refunded  |   1024
```

**01.3** For each domain table, show the row count recorded by the generator next to the
table's total size on disk, largest first.

```sql
SELECT r.key                                         AS table_name,
       r.value::bigint                               AS generated_rows,
       pg_size_pretty(pg_total_relation_size(r.key::regclass)) AS total_size
FROM meta.dataset d,
     jsonb_each_text(d.row_counts) AS r
WHERE r.key NOT LIKE 'meta.%'
ORDER BY pg_total_relation_size(r.key::regclass) DESC
LIMIT 6;
```

```text
         table_name         | generated_rows | total_size
----------------------------+----------------+------------
 mobility.sensor_readings   |         103369 | 33 MB
 commerce.orders            |          50000 | 26 MB
 commerce.order_items       |         112458 | 20 MB
 mobility.trip_segments     |          51908 | 20 MB
 commerce.payments          |          48734 | 15 MB
 mobility.station_inventory |          43200 | 8024 kB
```

### Module 02: constraints and indexes

Run first: `sql/02_constraints_indexes/indexing_basics.sql`

**02.1** Prove that `chk_order_total` rejects an order whose total does not equal
subtotal + tax + tip, without leaving anything behind. Catch the error and report its
SQLSTATE and constraint name.

```sql
DO $$
DECLARE
    v_state text;
    v_constraint text;
BEGIN
    UPDATE commerce.orders
    SET total_amount = total_amount + 10
    WHERE order_id = 1;
EXCEPTION WHEN check_violation THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE,
                            v_constraint = CONSTRAINT_NAME;
    RAISE NOTICE 'rejected: SQLSTATE %, constraint %', v_state, v_constraint;
END $$;
```

```text
psql:<stdin>:13: NOTICE:  rejected: SQLSTATE 23514, constraint chk_order_total
```

**02.2** Compare the size of the BRIN and B-tree indexes on `mobility.sensor_readings.reading_time`.

```sql
SELECT indexrelid::regclass AS index_name,
       am.amname           AS method,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_am am   ON am.oid = c.relam
WHERE i.indrelid = 'mobility.sensor_readings'::regclass
  AND pg_get_indexdef(indexrelid) LIKE '%(reading_time%'
ORDER BY pg_relation_size(indexrelid);
```

```text
              index_name              | method |  size
--------------------------------------+--------+---------
 mobility.idx_sensors_time_brin       | brin   | 24 kB
 mobility.idx_sensors_time_brin_multi | brin   | 32 kB
 mobility.idx_sensors_time_desc       | btree  | 736 kB
 mobility.idx_sensors_time_only       | btree  | 1344 kB
```

**02.3** Find foreign-key columns in the domain schemas that are not the leading column of
any index (each one makes deletes on the parent table scan the child).

```sql
SELECT c.conrelid::regclass AS child_table,
       a.attname            AS fk_column,
       c.confrelid::regclass AS parent_table
FROM pg_constraint c
JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
WHERE c.contype = 'f'
  AND cardinality(c.conkey) = 1
  AND c.connamespace::regnamespace::text IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
  AND NOT EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1])
ORDER BY 1, 2;
```

```text
        child_table         |      fk_column       |        parent_table
----------------------------+----------------------+----------------------------
 civics.permit_applications | processed_by         | civics.citizens
 mobility.trip_segments     | end_station_id       | mobility.stations
 documents.policy_documents | approved_by          | civics.citizens
 documents.policy_documents | created_by           | civics.citizens
 documents.policy_documents | supersedes_policy_id | documents.policy_documents
```

### Module 03: DML and queries

**03.1** Monthly delivered-order revenue for 2025 with the month-over-month change.

```sql
WITH monthly AS (
    SELECT date_trunc('month', order_date AT TIME ZONE 'UTC')::date AS month,
           sum(total_amount) AS revenue
    FROM commerce.orders
    WHERE status = 'delivered'
      AND order_date >= '2025-01-01 00:00:00+00'
    GROUP BY 1
)
SELECT month,
       round(revenue, 2) AS revenue,
       round(100 * (revenue / lag(revenue) OVER (ORDER BY month) - 1), 1) AS mom_pct
FROM monthly
ORDER BY month
LIMIT 5;
```

```text
   month    |  revenue  | mom_pct
------------+-----------+---------
 2025-01-01 | 551065.52 |
 2025-02-01 | 599828.34 |     8.8
 2025-03-01 | 714777.20 |    19.2
 2025-04-01 | 752129.99 |     5.2
 2025-05-01 | 827246.27 |    10.0
```

**03.2** The top two merchants by delivered revenue within each business type.

```sql
WITH revenue AS (
    SELECT m.business_type, m.business_name, sum(o.total_amount) AS revenue
    FROM commerce.orders o
    JOIN commerce.merchants m USING (merchant_id)
    WHERE o.status = 'delivered'
    GROUP BY m.business_type, m.merchant_id, m.business_name
)
SELECT business_type, business_name, round(revenue, 2) AS revenue
FROM (SELECT *, row_number() OVER (PARTITION BY business_type ORDER BY revenue DESC) AS rn
      FROM revenue) r
WHERE rn <= 2
ORDER BY business_type, rn;
```

```text
 business_type |       business_name       |  revenue
---------------+---------------------------+------------
 restaurant    | Star Grill #420           |  222261.96
 restaurant    | Star Bistro #434          |   55440.70
 retail        | Lone Star Outfitters #177 |  158881.29
 retail        | Northgate Goods #96       |  135216.95
 service       | Pioneer Salon #339        |  414039.35
 service       | Riverside Cleaners #258   |  289773.98
 manufacturing | Star Industries #395      |   41679.03
 manufacturing | Summit Works #317         |   13259.78
 technology    | Liberty Systems #1        | 3878903.93
 technology    | Lone Star Systems #205    |  260653.45
 healthcare    | Main Street Clinic #191   |  207508.26
 healthcare    | Pioneer Dental #314       |   71111.50
 other         | Bluebonnet Co #15         |  184298.50
 other         | Summit Co #124            |   61327.03
```

**03.3 [planted]** Orders are assigned to merchants by a bounded power law. Recover the Zipf
exponent as minus the slope of ln(order count) on ln(merchant rank), and compare it with
`meta.planted_effects`.

```sql
WITH counts AS (
    SELECT merchant_id, count(*) AS n
    FROM commerce.orders
    GROUP BY merchant_id
), ranked AS (
    SELECT n, row_number() OVER (ORDER BY n DESC, merchant_id) AS rk
    FROM counts
)
SELECT round(-regr_slope(ln(n), ln(rk))::numeric, 3) AS estimated_exponent,
       round(regr_r2(ln(n), ln(rk))::numeric, 3)     AS r2,
       (SELECT true_value FROM meta.planted_effects
        WHERE effect = 'merchant_popularity_zipf_exponent') AS true_value
FROM ranked;
```

```text
 estimated_exponent |  r2   | true_value
--------------------+-------+------------
              1.105 | 0.995 |       1.10
```

**03.4** Payment counts by method and status, with a subtotal per method and a grand total
(`ROLLUP` plus `GROUPING()` to label the subtotal rows).

```sql
SELECT CASE WHEN grouping(payment_method) = 1 THEN 'ALL' ELSE payment_method::text END AS method,
       CASE WHEN grouping(status) = 1 THEN 'ALL' ELSE status::text END                 AS status,
       count(*) AS payments
FROM commerce.payments
WHERE payment_method IN ('credit_card', 'cash')
GROUP BY ROLLUP (payment_method, status)
ORDER BY grouping(payment_method), payment_method, grouping(status), status;
```

```text
   method    |  status   | payments
-------------+-----------+----------
 cash        | completed |     3730
 cash        | failed    |       66
 cash        | refunded  |       93
 cash        | ALL       |     3889
 credit_card | completed |    21129
 credit_card | failed    |      337
 credit_card | refunded  |      450
 credit_card | ALL       |    21916
 ALL         | ALL       |    25805
```

### Module 04: views and materialized views

Run first: `sql/04_views_matviews/views.sql`, `sql/04_views_matviews/materialized_views.sql`

**04.1** Using `analytics.v_complaint_resolution`, list the five category/priority
combinations with the slowest average resolution.

```sql
SELECT category, priority_level, total_complaints, resolution_rate_pct, avg_resolution_days
FROM analytics.v_complaint_resolution
WHERE avg_resolution_days IS NOT NULL
ORDER BY avg_resolution_days DESC
LIMIT 5;
```

```text
 category | priority_level | total_complaints | resolution_rate_pct | avg_resolution_days
----------+----------------+------------------+---------------------+---------------------
 roads    | urgent         |               93 |                77.4 |                13.7
 roads    | low            |              245 |                75.5 |                12.0
 roads    | normal         |              612 |                73.2 |                11.8
 roads    | high           |              262 |                77.9 |                11.3
 other    | urgent         |               14 |                57.1 |                 6.7
```

**04.2** Which materialized views can be refreshed `CONCURRENTLY`, and how many rows does
each hold?

```sql
SELECT view_name, is_populated, row_count, can_refresh_concurrently
FROM analytics.materialized_view_status()
ORDER BY view_name;
```

```text
                 view_name                 | is_populated | row_count | can_refresh_concurrently
-------------------------------------------+--------------+-----------+--------------------------
 analytics.mv_daily_city_metrics           | t            |        90 | t
 analytics.mv_mobility_patterns            | t            |      9368 | t
 analytics.mv_monthly_business_performance | t            |      4755 | t
 analytics.mv_neighborhood_demographics    | t            |        24 | t
```

**04.3** Refresh `analytics.mv_neighborhood_demographics` without blocking readers, then
show the three densest neighbourhoods.

```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY analytics.mv_neighborhood_demographics;

SELECT neighborhood_name, active_residents, resident_density_per_sq_km, neighborhood_type
FROM analytics.mv_neighborhood_demographics
ORDER BY resident_density_per_sq_km DESC
LIMIT 3;
```

```text
 neighborhood_name | active_residents | resident_density_per_sq_km | neighborhood_type
-------------------+------------------+----------------------------+-------------------
 Cottonwood        |              741 |                      223.4 | Urban Core
 Bluebonnet        |              697 |                      210.1 | Urban Core
 Civic Center      |              642 |                      193.5 | Residential
```

### Module 05: functions and triggers

Run first: `sql/05_functions_triggers/plpgsql_basics.sql`, `sql/05_functions_triggers/triggers_auditing.sql`

**05.1** Use `civics.age_on()` to build an age distribution of active citizens as of the
dataset's reference date, in 20-year bands.

```sql
SELECT (civics.age_on(date_of_birth, meta.as_of()::date) / 20) * 20 AS age_band_start,
       count(*) AS citizens
FROM civics.citizens
WHERE status = 'active'
GROUP BY 1
ORDER BY 1;
```

```text
 age_band_start | citizens
----------------+----------
              0 |      654
             20 |     3366
             40 |     2422
             60 |     2150
             80 |     1006
```

**05.2** Write an `IMMUTABLE` SQL-standard function that classifies an order total into
`small` (< 25), `medium` (< 100) or `large`, and use it to count delivered orders per class.

```sql
CREATE OR REPLACE FUNCTION commerce.order_size_class(p_total numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE PARALLEL SAFE
RETURN CASE WHEN p_total < 25 THEN 'small'
            WHEN p_total < 100 THEN 'medium'
            ELSE 'large' END;

SELECT commerce.order_size_class(total_amount) AS size_class, count(*) AS orders
FROM commerce.orders
WHERE status = 'delivered'
GROUP BY 1
ORDER BY 2 DESC;
```

```text
 size_class | orders
------------+--------
 large      |  21976
 medium     |  17265
 small      |   7595
```

**05.3** Attach the generic audit trigger to `civics.citizens` inside a transaction, change
one row, read the audit record, and roll everything back (DDL is transactional, so the
trigger disappears too).

```sql
BEGIN;
CREATE TRIGGER trg_audit_citizens_ex
    AFTER UPDATE ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes('citizen_id');

UPDATE civics.citizens SET phone = '555-0100' WHERE citizen_id = 42;

SELECT operation_type, record_pk, changed_fields -> 'phone' AS phone_change
FROM audit.table_changes
WHERE table_name = 'citizens' AND record_pk = '42';
ROLLBACK;
```

```text
 operation_type | record_pk |                 phone_change
----------------+-----------+----------------------------------------------
 UPDATE         | 42        | {"new": "555-0100", "old": "(972) 555-0042"}
```

### Module 06: JSONB and full-text search

Run first: `sql/06_jsonb_fulltext/jsonb_modeling_validation.sql`, `sql/06_jsonb_fulltext/fulltext_search_ranking.sql`

**06.1** Rank complaints about streetlights with `ts_rank` on the stored `search_vector`
(it is built with the `english` configuration, so the query must use it too).

```sql
SELECT complaint_number, subject,
       round(ts_rank(search_vector, q)::numeric, 4) AS rank
FROM documents.complaint_records,
     websearch_to_tsquery('english', 'streetlight out') AS q
WHERE search_vector @@ q
ORDER BY rank DESC, complaint_id
LIMIT 5;
```

```text
 complaint_number |                subject                |  rank
------------------+---------------------------------------+--------
 CMP-2025-000012  | Streetlight out near Pecan Grove      | 0.0760
 CMP-2025-000028  | Streetlight out near Spring Valley    | 0.0760
 CMP-2025-000045  | Streetlight out near Station District | 0.0760
 CMP-2025-000050  | Streetlight out near Market Row       | 0.0760
 CMP-2025-000083  | Streetlight out near Spring Valley    | 0.0760
```

**06.2** Which JSONB keys does each complaint category carry in `metadata`, and for how
many rows?

```sql
SELECT category,
       string_agg(DISTINCT k, ', ' ORDER BY k) AS metadata_keys,
       count(DISTINCT complaint_id)            AS complaints
FROM documents.complaint_records,
     jsonb_object_keys(metadata) AS k
GROUP BY category
ORDER BY category;
```

```text
 category  |              metadata_keys              | complaints
-----------+-----------------------------------------+------------
 animals   | category, channel                       |        150
 graffiti  | category, channel                       |        512
 noise     | category, decibel_level, time_of_day    |       1059
 other     | category, channel                       |        164
 parking   | category, channel                       |        539
 roads     | category, hazard_type, road_condition   |       1212
 trash     | category, channel                       |        675
 utilities | category, outage_duration, utility_type |        689
```

**06.3** Use PG17 `JSON_TABLE` to turn the noise-complaint metadata into typed columns and
report the five times of day with the highest median decibel level.

```sql
SELECT jt.time_of_day,
       count(*) AS complaints,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY jt.decibel_level) AS median_db
FROM documents.complaint_records c,
     JSON_TABLE(c.metadata, '$'
         COLUMNS (decibel_level numeric PATH '$.decibel_level',
                  time_of_day   text    PATH '$.time_of_day')) AS jt
WHERE c.category = 'noise'
GROUP BY jt.time_of_day
ORDER BY median_db DESC, jt.time_of_day
LIMIT 5;
```

```text
 time_of_day | complaints | median_db
-------------+------------+-----------
 20:00       |         47 |        78
 04:00       |         41 |        77
 16:00       |         48 |        77
 02:00       |         52 |      76.5
 06:00       |         45 |        76
```

**06.4** A user types `stretlight` (typo). Use the module's trigram-backed fuzzy search.

```sql
SELECT complaint_id, subject, round(rank_score::numeric, 3) AS rank_score, query_used
FROM documents.search_complaints_fuzzy('stretlight', 3);
```

```text
 complaint_id |                subject                | rank_score | query_used
--------------+---------------------------------------+------------+-------------
           12 | Streetlight out near Pecan Grove      |      0.167 | streetlight
           28 | Streetlight out near Spring Valley    |      0.167 | streetlight
           45 | Streetlight out near Station District |      0.167 | streetlight
```

### Module 07: geospatial

Run first: `sql/07_geospatial/spatial_indexes_queries.sql`, `sql/07_geospatial/routing_nearest.sql`

**07.1** Assign citizens to neighbourhoods by point-in-polygon and list the five most
populous neighbourhoods by registered citizens.

```sql
SELECT n.neighborhood_name, count(c.citizen_id) AS citizens
FROM geo.neighborhood_boundaries n
LEFT JOIN civics.citizens c ON ST_Contains(n.boundary_geom, c.home_geom)
GROUP BY n.neighborhood_name
ORDER BY citizens DESC
LIMIT 5;
```

```text
 neighborhood_name | citizens
-------------------+----------
 Cottonwood        |      771
 Bluebonnet        |      730
 Civic Center      |      666
 Station District  |      649
 Brookhaven        |      567
```

**07.2** For three bus stations, find the nearest hospital with a KNN search and report the
true distance in metres.

```sql
SELECT s.station_name, h.name AS nearest_hospital, h.metres
FROM mobility.stations s
CROSS JOIN LATERAL (
    SELECT p.name,
           round(ST_Distance(p.location_geom::geography,
                             ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326)::geography)) AS metres
    FROM geo.points_of_interest p
    WHERE p.category = 'hospital'
    ORDER BY p.location_geom <-> ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326)
    LIMIT 1
) h
WHERE s.station_type = 'bus'
ORDER BY s.station_id
LIMIT 3;
```

```text
     station_name     |     nearest_hospital     | metres
----------------------+--------------------------+--------
 Medical Center Bus 1 | Tech Valley Hospital 551 |   4485
 Market Row Bus 2     | Market Row Hospital 66   |    380
 Brookhaven Bus 3     | Tech Valley Hospital 551 |   2811
```

**07.3** What share of citizens live within 800 m of a bus or rail station?

```sql
SELECT count(*) AS citizens,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM mobility.stations s
           WHERE s.station_type IN ('bus', 'rail')
             AND ST_DWithin(c.home_geom::geography,
                            ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326)::geography,
                            800))) AS within_800m,
       round(100.0 * count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM mobility.stations s
           WHERE s.station_type IN ('bus', 'rail')
             AND ST_DWithin(c.home_geom::geography,
                            ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326)::geography,
                            800))) / count(*), 1) AS pct
FROM civics.citizens c
WHERE c.home_geom IS NOT NULL;
```

```text
 citizens | within_800m | pct
----------+-------------+------
    10000 |        7908 | 79.1
```

**07.4** Route between the first two stations on the road network: snap both to the nearest
network node and sum the shortest path by distance.

```sql
WITH ends AS (
    SELECT geo.nearest_node(ST_SetSRID(ST_MakePoint(a.longitude, a.latitude), 4326)) AS src,
           geo.nearest_node(ST_SetSRID(ST_MakePoint(b.longitude, b.latitude), 4326)) AS dst
    FROM mobility.stations a, mobility.stations b
    WHERE a.station_id = 1 AND b.station_id = 2
)
SELECT count(*) AS edges,
       round(sum(p.edge_length_m)) AS route_m,
       string_agg(DISTINCT p.road_name, ', ') AS roads_used
FROM ends, geo.shortest_path(ends.src, ends.dst, 'distance') p
WHERE p.edge_id IS NOT NULL;
```

```text
 edges | route_m | roads_used
-------+---------+------------
    16 |    5984 | 3rd Street
```

### Module 08: partitioning and time series

Run first: `sql/08_partitioning_timeseries/declarative_partitioning.sql`

**08.1** How are the rows of `mobility.sensor_readings_part` distributed across partitions?

```sql
SELECT tableoid::regclass AS partition, count(*) AS readings
FROM mobility.sensor_readings_part
GROUP BY 1
ORDER BY 1;
```

```text
               partition               | readings
---------------------------------------+----------
 mobility.sensor_readings_part_2025_10 |    33300
 mobility.sensor_readings_part_2025_11 |    34447
 mobility.sensor_readings_part_2025_12 |    35622
 mobility.sensor_readings_part_2026_02 |        1
```

**08.2** Show that a filter on the partition key prunes partitions at plan time.

```sql
EXPLAIN (COSTS OFF)
SELECT count(*)
FROM mobility.sensor_readings_part
WHERE reading_time >= '2025-12-24 00:00:00+00'
  AND reading_time <  '2026-01-01 00:00:00+00';
```

```text
                                                                             QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------------------------------------------
 Aggregate
   ->  Index Only Scan using sensor_readings_part_2025_12_sensor_type_reading_time_idx on sensor_readings_part_2025_12 sensor_readings_part
         Index Cond: ((reading_time >= '2025-12-24 00:00:00+00'::timestamp with time zone) AND (reading_time < '2026-01-01 00:00:00+00'::timestamp with time zone))
```

**08.3** Average traffic count per 6-hour bucket for one day using `date_bin`, with
`generate_series` producing every bucket even when it has no data.

```sql
WITH buckets AS (
    SELECT generate_series(timestamptz '2025-12-30 00:00:00+00',
                           timestamptz '2025-12-30 18:00:00+00',
                           interval '6 hours') AS bucket
), agg AS (
    SELECT date_bin(interval '6 hours', reading_time, timestamptz '2025-01-01 00:00:00+00') AS bucket,
           round(avg(reading_value), 1) AS avg_count,
           count(*) AS readings
    FROM mobility.sensor_readings
    WHERE sensor_type = 'traffic_counter'
      AND reading_time >= '2025-12-30 00:00:00+00'
      AND reading_time <  '2025-12-31 00:00:00+00'
    GROUP BY 1
)
SELECT b.bucket, coalesce(a.readings, 0) AS readings, a.avg_count
FROM buckets b
LEFT JOIN agg a USING (bucket)
ORDER BY b.bucket;
```

```text
         bucket         | readings | avg_count
------------------------+----------+-----------
 2025-12-30 00:00:00+00 |       96 |     110.8
 2025-12-30 06:00:00+00 |       95 |     461.6
 2025-12-30 12:00:00+00 |       96 |     302.7
 2025-12-30 18:00:00+00 |       96 |     242.8
```

**08.4 [planted]** Transit delays were generated with a mean of 6 minutes in weekday peaks
(07-09 and 16-19 UTC) and 2 minutes otherwise. Recover the peak/off-peak ratio from
`mobility.trip_segments`.

```sql
WITH flagged AS (
    SELECT delay_minutes,
           extract(isodow FROM start_time AT TIME ZONE 'UTC') <= 5
           AND (extract(hour FROM start_time AT TIME ZONE 'UTC') BETWEEN 7 AND 8
                OR extract(hour FROM start_time AT TIME ZONE 'UTC') BETWEEN 16 AND 18) AS is_peak
    FROM mobility.trip_segments
    WHERE trip_mode IN ('bus', 'rail')
)
SELECT round(avg(delay_minutes) FILTER (WHERE is_peak), 2)     AS peak_mean_min,
       round(avg(delay_minutes) FILTER (WHERE NOT is_peak), 2) AS offpeak_mean_min,
       round(avg(delay_minutes) FILTER (WHERE is_peak)
             / avg(delay_minutes) FILTER (WHERE NOT is_peak), 2) AS ratio,
       (SELECT true_value FROM meta.planted_effects
        WHERE effect = 'peak_hour_bus_delay_ratio')            AS true_value
FROM flagged;
```

```text
 peak_mean_min | offpeak_mean_min | ratio | true_value
---------------+------------------+-------+------------
          6.02 |             1.97 |  3.06 |        3.0
```

### Module 09: data movement

Run first: `sql/09_data_movement/copy_bulk_operations.sql`

**09.1** Export the five most recent delivered orders as CSV with a header to the client
(`COPY ... TO STDOUT` needs no file-system privileges).

```sql
COPY (
    SELECT order_number, merchant_id, total_amount, order_date
    FROM commerce.orders
    WHERE status = 'delivered'
    ORDER BY order_date DESC
    LIMIT 5
) TO STDOUT WITH (FORMAT csv, HEADER);
```

```text
order_number,merchant_id,total_amount,order_date
ORD-20251228-0035020,177,66.87,2025-12-28 23:34:52+00
ORD-20251228-0015604,124,14.30,2025-12-28 22:47:52+00
ORD-20251228-0008762,113,113.83,2025-12-28 22:09:06+00
ORD-20251228-0020947,96,23.17,2025-12-28 21:45:21+00
ORD-20251228-0022575,191,131.43,2025-12-28 21:44:40+00
```

**09.2** `file_fdw` exposes a CSV file as a read-only table. Query the module's foreign
table over `/data/timeseries.csv` directly, without loading it.

```sql
SELECT sensor_type, count(*) AS readings, round(avg(value), 1) AS avg_value
FROM staging.ext_timeseries
GROUP BY sensor_type
ORDER BY readings DESC;
```

```text
    sensor_type     | readings | avg_value
--------------------+----------+-----------
 water_flow         |       12 |       3.2
 air_quality        |       12 |      19.3
 power_grid         |       12 |     242.8
 traffic_counter    |       12 |     193.3
 pedestrian_counter |        4 |      93.8
 light_level        |        4 |     247.9
 humidity           |        3 |      65.0
 vibration          |        3 |       0.3
 noise_level        |        3 |      55.4
 temperature        |        3 |       4.8
```

**09.3** PG17 `ON_ERROR ignore`: load four rows where two have type errors, and keep the
two good ones instead of aborting the whole `COPY`. (`COPY ... FROM STDIN` reads the data
lines that follow it in the script; this needs no module objects.)

```sql
CREATE TEMP TABLE readings_in (sensor text, reading_ts timestamptz, value numeric);
COPY readings_in FROM STDIN WITH (FORMAT csv, ON_ERROR ignore);
TRF-001,2025-12-30 08:00:00+00,512
TRF-001,not-a-timestamp,498
TRF-001,2025-12-30 10:00:00+00,n/a
TRF-001,2025-12-30 11:00:00+00,470
\.
SELECT * FROM readings_in ORDER BY reading_ts;
```

```text
psql:<stdin>:7: NOTICE:  2 rows were skipped due to data type incompatibility
 sensor  |       reading_ts       | value
---------+------------------------+-------
 TRF-001 | 2025-12-30 08:00:00+00 |   512
 TRF-001 | 2025-12-30 11:00:00+00 |   470
```

**09.4** Upsert with `MERGE`: keep a per-merchant order summary current. PG17 lets `MERGE`
return rows (`RETURNING merge_action()`), so a CTE can count what happened. Run it twice;
the second run updates instead of inserting.

```sql
CREATE TEMP TABLE merchant_summary (
    merchant_id bigint PRIMARY KEY,
    orders      bigint NOT NULL,
    revenue     numeric NOT NULL
);

WITH m AS (
    MERGE INTO merchant_summary t
    USING (SELECT merchant_id, count(*) AS orders, sum(total_amount) AS revenue
           FROM commerce.orders WHERE status = 'delivered' GROUP BY merchant_id) s
    ON t.merchant_id = s.merchant_id
    WHEN MATCHED THEN UPDATE SET orders = s.orders, revenue = s.revenue
    WHEN NOT MATCHED THEN INSERT VALUES (s.merchant_id, s.orders, s.revenue)
    RETURNING merge_action() AS action
)
SELECT 'run 1' AS run, action, count(*) AS merchants FROM m GROUP BY action;

WITH m AS (
    MERGE INTO merchant_summary t
    USING (SELECT merchant_id, count(*) AS orders, sum(total_amount) AS revenue
           FROM commerce.orders WHERE status = 'delivered' GROUP BY merchant_id) s
    ON t.merchant_id = s.merchant_id
    WHEN MATCHED THEN UPDATE SET orders = s.orders, revenue = s.revenue
    WHEN NOT MATCHED THEN INSERT VALUES (s.merchant_id, s.orders, s.revenue)
    RETURNING merge_action() AS action
)
SELECT 'run 2' AS run, action, count(*) AS merchants FROM m GROUP BY action;
```

```text
  run  | action | merchants
-------+--------+-----------
 run 1 | INSERT |       500

  run  | action | merchants
-------+--------+-----------
 run 2 | UPDATE |       500
```

### Module 10: transactions, MVCC and locks

Run first: `sql/10_tx_mvcc_locks/transactions_isolation.sql`

**10.1** Watch MVCC at work: an `UPDATE` writes a new row version with a new `ctid` and a new
`xmin`; the old version is dead until `VACUUM`.

```sql
CREATE TEMP TABLE mvcc_ex (id int PRIMARY KEY, v text) WITH (fillfactor = 50);
INSERT INTO mvcc_ex VALUES (1, 'a');
SELECT 'after insert' AS step, ctid, xmin::text <> '0' AS has_xmin, xmax FROM mvcc_ex;
UPDATE mvcc_ex SET v = 'b' WHERE id = 1;
SELECT 'after update' AS step, ctid, xmin::text <> '0' AS has_xmin, xmax FROM mvcc_ex;
SELECT n_tup_upd, n_tup_hot_upd FROM pg_stat_xact_user_tables WHERE relname = 'mvcc_ex';
```

```text
     step     | ctid  | has_xmin | xmax
--------------+-------+----------+------
 after insert | (0,1) | t        |    0

     step     | ctid  | has_xmin | xmax
--------------+-------+----------+------
 after update | (0,2) | t        |    0

 n_tup_upd | n_tup_hot_upd
-----------+---------------
         1 |             1
```

**10.2** Which anomalies does each isolation level allow in PostgreSQL?

```sql
SELECT isolation_level, nonrepeatable_read, phantom_read, lost_update, write_skew
FROM analytics.compare_isolation_levels();
```

```text
 isolation_level  | nonrepeatable_read | phantom_read |   lost_update    |    write_skew
------------------+--------------------+--------------+------------------+------------------
 READ UNCOMMITTED | possible           | possible     | possible         | possible
 READ COMMITTED   | possible           | possible     | possible         | possible
 REPEATABLE READ  | no                 | no           | no (40001 error) | possible
 SERIALIZABLE     | no                 | no           | no (40001 error) | no (40001 error)
```

**10.3** Claim two pending permit applications as a queue worker would, with
`FOR UPDATE SKIP LOCKED`, and inspect the locks your transaction now holds.

```sql
BEGIN;
SELECT permit_id
FROM civics.permit_applications
WHERE status = 'pending'
ORDER BY application_date, permit_id
LIMIT 2
FOR UPDATE SKIP LOCKED;

SELECT locktype, relation::regclass AS relation, mode, granted
FROM pg_locks
WHERE pid = pg_backend_pid() AND locktype = 'relation'
  AND relation = 'civics.permit_applications'::regclass;
ROLLBACK;
```

```text
 permit_id
-----------
       409
       499

 locktype |          relation          |     mode     | granted
----------+----------------------------+--------------+---------
 relation | civics.permit_applications | RowShareLock | t
```

Row locks taken by `FOR UPDATE` are stored in the tuple header (`xmax`), not in `pg_locks`;
the table-level `RowShareLock` is what shows up.

### Module 11: performance tuning

Run first: `sql/11_perf_tuning/explain_analyze_playbook.sql`, `sql/11_perf_tuning/index_advisor_patterns.sql`, `sql/11_perf_tuning/stats_and_autovacuum.sql`

**11.1** The planner assumes predicates are independent. Use `analytics.explain_nodes()`
to measure the misestimate when two columns are perfectly correlated (every `air_quality`
sensor reports in `AQI`).

```sql
SELECT node, relation, est_rows, actual_rows, off_by
FROM analytics.explain_nodes($q$
    SELECT * FROM mobility.sensor_readings
    WHERE sensor_type = 'air_quality' AND unit_of_measure = 'AQI'
$q$)
ORDER BY node_id;
```

```text
                    node                     |    relation     | est_rows | actual_rows | off_by
---------------------------------------------+-----------------+----------+-------------+--------
 Bitmap Heap Scan                            | sensor_readings |     4614 |       21540 |   0.21
   Bitmap Index Scan [idx_sensors_type_time] |                 |    21838 |       21540 |   1.01
```

The fix (extended statistics with `CREATE STATISTICS ... (dependencies)`) is shown with a
before/after plan in [EXPLAIN_PLAN_LIBRARY.md](EXPLAIN_PLAN_LIBRARY.md#estimates-vs-actuals-and-extended-statistics).

**11.2** Would an index on `commerce.orders (total_amount)` help a "large orders" query?
Ask HypoPG before building anything.

```sql
SELECT 'before' AS step, total_cost, access_paths
FROM analytics.plan_cost('SELECT order_id FROM commerce.orders WHERE total_amount > 2000');

SELECT indexname FROM hypopg_create_index('CREATE INDEX ON commerce.orders (total_amount)');

SELECT 'with hypothetical index' AS step, total_cost, access_paths
FROM analytics.plan_cost('SELECT order_id FROM commerce.orders WHERE total_amount > 2000');

SELECT hypopg_reset();
```

```text
  step  | total_cost | access_paths
--------+------------+--------------
 before |    2453.00 | Seq Scan

                 indexname
-------------------------------------------
 <13566>btree_commerce_orders_total_amount

          step           | total_cost |                                    access_paths
-------------------------+------------+-------------------------------------------------------------------------------------
 with hypothetical index |     463.18 | Bitmap Heap Scan; Bitmap Index Scan using <13566>btree_commerce_orders_total_amount

 hypopg_reset
--------------

```

**11.3** Which tables would autovacuum visit next, and how close are they to the
thresholds?

```sql
SELECT table_name, reltuples, n_dead_tup, vacuum_at, n_mod_since_analyze, analyze_at, status
FROM analytics.autovacuum_thresholds()
WHERE table_name LIKE 'commerce.%'
ORDER BY table_name;
```

```text
         table_name         | reltuples | n_dead_tup | vacuum_at | n_mod_since_analyze | analyze_at | status
----------------------------+-----------+------------+-----------+---------------------+------------+--------
 commerce.business_licenses |       679 |          0 |        84 |                   0 |         64 | ok
 commerce.merchants         |       500 |          0 |        75 |                   0 |         60 | ok
 commerce.order_items       |    112458 |          0 |      5673 |                   0 |       2299 | ok
 commerce.orders            |     50000 |          0 |      2550 |                   0 |       1050 | ok
 commerce.payments          |     48734 |          0 |      2487 |                   0 |       1025 | ok
```

### Module 12: security and RLS

Run first: `sql/12_security_rls/rls_policies.sql`, `sql/12_security_rls/column_privacy_masks.sql`

**12.1** As the application role, how many service requests does each tenant see through
RLS, versus how many it owns? (`demo_tenant_visibility` must be called as
`rls_tenant_user`: superusers bypass RLS and would see every row.)

```sql
SET ROLE rls_tenant_user;
SELECT * FROM rls_demo.demo_tenant_visibility(ARRAY[1, 2, 3]) ORDER BY tenant_id;
RESET ROLE;
```

```text
 tenant_id | visible_rows | own_rows
-----------+--------------+----------
         1 |         4364 |       83
         2 |         4364 |       62
         3 |         4360 |       81
```

**12.2** Explain the visible rows for tenant 2: its own rows (policy `tenant_select`) plus
every tenant's resolved or archived rows (policy `public_resolved_select`); permissive
policies are OR-ed. Then clear the tenant: only the public rows remain.

```sql
SET ROLE rls_tenant_user;
SET app.current_tenant = '2';   -- what rls_demo.set_tenant(2) does
SELECT tenant_id = 2                         AS own_tenant,
       status IN ('resolved', 'archived')    AS public_status,
       count(*)                              AS visible
FROM rls_demo.service_requests
GROUP BY 1, 2
ORDER BY 1, 2;

RESET app.current_tenant;
SELECT count(*) AS visible_without_tenant,
       count(*) FILTER (WHERE status NOT IN ('resolved', 'archived')) AS non_public
FROM rls_demo.service_requests;
RESET ROLE;
```

```text
 own_tenant | public_status | visible
------------+---------------+---------
 f          | t             |    4302
 t          | f             |       5
 t          | t             |      57

 visible_without_tenant | non_public
------------------------+------------
                   4359 |          0
```

**12.3** Read citizen data through the masking view as a clerk and as a supervisor. The
supervisor's SSN is decrypted with `pgp_sym_decrypt`, so the session must hold the key the
module encrypted with.

```sql
SET app.encryption_key = 'demo-only-key-rotate-me';

SET ROLE privacy_clerk;
SELECT 'clerk' AS viewer, citizen_id, email, phone, ssn
FROM privacy.v_citizens_masked ORDER BY citizen_id LIMIT 2;
RESET ROLE;

SET ROLE privacy_supervisor;
SELECT 'supervisor' AS viewer, citizen_id, email, phone, ssn
FROM privacy.v_citizens_masked ORDER BY citizen_id LIMIT 2;
RESET ROLE;
```

```text
 viewer | citizen_id |           email           |     phone      |     ssn
--------+------------+---------------------------+----------------+-------------
 clerk  |          1 | m***@mail.polaris.example | (972) XXX-XXXX | ***-**-7919
 clerk  |          2 | r***@mail.polaris.example | (972) XXX-XXXX | ***-**-5838

   viewer   | citizen_id |                  email                   |     phone      |     ssn
------------+------------+------------------------------------------+----------------+-------------
 supervisor |          1 | michelle.roberts.1@mail.polaris.example  | (972) 555-0001 | 901-07-7919
 supervisor |          2 | richard.rodriguez.2@mail.polaris.example | (972) 555-0002 | 902-14-5838
```

### Module 13: backup and replication

Run first: `sql/13_backup_replication/backup_restore_playbook.sql`, `sql/13_backup_replication/logical_replication_demo.sql`

**13.1** Estimate the size of a dump of the `commerce` schema, table by table.

```sql
SELECT table_name, est_rows, total_size, estimated_dump_size
FROM backup_mgmt.estimate_backup_size(ARRAY['commerce'])
ORDER BY est_rows DESC;
```

```text
    table_name     | est_rows | total_size | estimated_dump_size
-------------------+----------+------------+---------------------
 order_items       |   112458 | 20 MB      | 4615 kB
 orders            |    50000 | 26 MB      | 4399 kB
 payments          |    48734 | 15 MB      | 2935 kB
 business_licenses |      679 | 392 kB     | 36 kB
 merchants         |      500 | 392 kB     | 60 kB
```

**13.2** How much WAL does updating 1,000 orders generate? Measure the LSN difference
around the statement, then roll it back (WAL is written even for aborted transactions).

```sql
SELECT pg_current_wal_insert_lsn() AS start_lsn \gset
BEGIN;
UPDATE commerce.orders SET order_notes = 'audit' WHERE order_id <= 1000;
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_insert_lsn(), :'start_lsn')) AS wal_generated;
ROLLBACK;
```

```text
 wal_generated
---------------
 721 kB
```

**13.3** Decode logical changes: create a temporary `test_decoding` slot, change a row in a
module-owned table, and peek at the decoded stream.

```sql
SELECT slot_name FROM pg_create_logical_replication_slot('ex_13_slot', 'test_decoding', true);
UPDATE repl_demo.orders_pub SET status = 'shipped'
WHERE order_id = (SELECT min(order_id) FROM repl_demo.orders_pub);
SELECT left(data, 60) AS change
FROM pg_logical_slot_peek_changes('ex_13_slot', NULL, NULL)
WHERE data NOT LIKE 'BEGIN%' AND data NOT LIKE 'COMMIT%';
SELECT pg_drop_replication_slot('ex_13_slot');
```

```text
 slot_name
------------
 ex_13_slot

                            change
--------------------------------------------------------------
 table repl_demo.orders_pub: UPDATE: order_id[bigint]:1 merch

 pg_drop_replication_slot
--------------------------

```

### Module 14: async patterns

Run first: `sql/14_async_patterns/advisory_locks_coordination.sql`

**14.1** Turn a job name into an advisory-lock key, take the lock twice (session locks are
re-entrant), and confirm that one unlock is not enough.

```sql
SELECT pg_try_advisory_lock(hashtextextended('nightly-rollup', 0)) AS first,
       pg_try_advisory_lock(hashtextextended('nightly-rollup', 0)) AS second;
SELECT pg_advisory_unlock(hashtextextended('nightly-rollup', 0)) AS unlock_1;
SELECT count(*) AS still_held FROM pg_locks
WHERE locktype = 'advisory' AND pid = pg_backend_pid();
SELECT pg_advisory_unlock(hashtextextended('nightly-rollup', 0)) AS unlock_2;
SELECT count(*) AS still_held FROM pg_locks
WHERE locktype = 'advisory' AND pid = pg_backend_pid();
```

```text
 first | second
-------+--------
 t     | t

 unlock_1
----------
 t

 still_held
------------
          1

 unlock_2
----------
 t

 still_held
------------
          0
```

**14.2** Notifications are delivered only on commit. Listen on a channel, send one
notification in a rolled-back transaction and one in a committed one; psql reports only the
committed payload.

```sql
LISTEN ex_channel;
BEGIN; SELECT pg_notify('ex_channel', 'rolled back'); ROLLBACK;
BEGIN; SELECT pg_notify('ex_channel', 'committed'); COMMIT;
SELECT 'done' AS step;
```

```text
 pg_notify
-----------


 pg_notify
-----------


Asynchronous notification "ex_channel" with payload "committed" received from server process with PID 8704.
 step
------
 done
```

**14.3** A transaction-level advisory lock is released automatically at the end of the
transaction; a second `try` from another transaction then succeeds.

```sql
BEGIN;
SELECT pg_try_advisory_xact_lock(14, 3) AS got_lock;
SELECT count(*) AS held_inside FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid();
COMMIT;
SELECT count(*) AS held_after_commit FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid();
```

```text
 got_lock
----------
 t

 held_inside
-------------
           1

 held_after_commit
-------------------
                 0
```

### Module 15: testing and quality

Run first: `sql/15_testing_quality/data_quality_checks.sql`

**15.1** Show the data-quality scorecard per target table and dimension.

```sql
SELECT target_table, dimension, rules, passing, pass_pct
FROM data_quality.scorecard
ORDER BY target_table, dimension
LIMIT 8;
```

```text
  target_table   |       dimension       | rules | passing | pass_pct
-----------------+-----------------------+-------+---------+----------
 civics.citizens | completeness          |     1 |       1 |    100.0
 civics.citizens | uniqueness            |     2 |       2 |    100.0
 civics.citizens | validity              |     1 |       1 |    100.0
 commerce.orders | completeness          |     2 |       2 |    100.0
 commerce.orders | distribution_drift    |     2 |       2 |    100.0
 commerce.orders | referential_integrity |     1 |       1 |    100.0
 commerce.orders | statistical_outlier   |     1 |       1 |    100.0
 commerce.orders | timeliness            |     1 |       1 |    100.0
```

**15.2 [planted]** About 0.2% of orders had every item price multiplied by 15-25. Detect
them with a z-score of each order's mean log unit price within its business type, and score
the detector against `meta.ground_truth`.

```sql
WITH per_order AS (
    SELECT oi.order_id, m.business_type, avg(ln(oi.unit_price)) AS mean_log_price
    FROM commerce.order_items oi
    JOIN commerce.orders o    USING (order_id)
    JOIN commerce.merchants m USING (merchant_id)
    GROUP BY oi.order_id, m.business_type
), scored AS (
    SELECT order_id,
           (mean_log_price - avg(mean_log_price) OVER w) / stddev(mean_log_price) OVER w AS z
    FROM per_order
    WINDOW w AS (PARTITION BY business_type)
), truth AS (
    SELECT entity_id AS order_id
    FROM meta.ground_truth
    WHERE entity = 'commerce.orders' AND label = 'order_amount_outlier'
), confusion AS (
    SELECT count(*) FILTER (WHERE s.z >= 4 AND t.order_id IS NOT NULL) AS tp,
           count(*) FILTER (WHERE s.z >= 4 AND t.order_id IS NULL)     AS fp,
           count(*) FILTER (WHERE s.z <  4 AND t.order_id IS NOT NULL) AS fn
    FROM scored s
    LEFT JOIN truth t USING (order_id)
)
SELECT tp, fp, fn,
       round(tp::numeric / (tp + fp), 3) AS precision,
       round(tp::numeric / (tp + fn), 3) AS recall
FROM confusion;
```

```text
 tp | fp | fn | precision | recall
----+----+----+-----------+--------
 89 | 10 | 14 |     0.899 |  0.864
```

**15.3** Write a three-test pgTAP plan in a rolled-back transaction: the orders table
exists, the total-check constraint rejects bad data, and `meta.as_of()` is the expected
instant.

```sql
BEGIN;
SELECT plan(3);
SELECT has_table('commerce', 'orders', 'orders table exists');
SELECT throws_ok(
    $$UPDATE commerce.orders SET total_amount = total_amount + 10 WHERE order_id = 1$$,
    '23514', NULL, 'chk_order_total rejects an inconsistent total');
SELECT is(meta.as_of(), timestamptz '2025-12-31 23:59:59+00', 'dataset clock is fixed');
SELECT * FROM finish();
ROLLBACK;
```

```text
 plan
------
 1..3

         has_table
----------------------------
 ok 1 - orders table exists

                      throws_ok
------------------------------------------------------
 ok 2 - chk_order_total rejects an inconsistent total

              is
-------------------------------
 ok 3 - dataset clock is fixed

 finish
--------
```

### Module 16: capstones

Run first: `sql/16_capstones/citywide_analytics_dashboard.sql`, `sql/16_capstones/anomaly_detection_patterns.sql`, `sql/16_capstones/geo_accessibility_study.sql`

**16.1 [planted]** Complaint resolution time was generated as lognormal with a log-multiplier
of -0.25 per standard deviation of neighbourhood income. Estimate it with and without
category fixed effects, and check whether the 95% interval covers the true value.

```sql
SELECT estimator, n, beta, ci_low, ci_high, true_value, truth_in_ci
FROM dashboard.estimate_income_gradient(interval '0');
```

```text
             estimator             |  n   |  beta   | ci_low  | ci_high | true_value | truth_in_ci
-----------------------------------+------+---------+---------+---------+------------+-------------
 pooled OLS (no category FE)       | 4730 | -0.1833 | -0.2054 | -0.1611 |      -0.25 | f
 within-category OLS (category FE) | 4730 | -0.2577 | -0.2751 | -0.2404 |      -0.25 | t
```

**16.2 [planted]** Score the sensor anomaly detectors against `meta.ground_truth`: best F1
per label.

```sql
SELECT DISTINCT ON (label) label, detector, tp, fp, fn, precision, recall, f1
FROM anomaly_detection.sensor_evaluation
WHERE f1 IS NOT NULL
ORDER BY label, f1 DESC;
```

```text
       label       |     detector      |  tp  | fp  | fn  | precision | recall |  f1
-------------------+-------------------+------+-----+-----+-----------+--------+-------
 ALL (any anomaly) | ensemble          | 2554 | 169 |  98 |     0.938 |  0.963 | 0.950
 dropout           | quality_flag      |  228 |   0 |   0 |     1.000 |  1.000 | 1.000
 level_shift       | level_persistence | 1921 |  21 | 117 |     0.989 |  0.943 | 0.965
 spike             | ensemble          |  360 | 136 |  26 |     0.726 |  0.933 | 0.816
```

**16.3 [planted]** Build your own spike detector without the capstone. A spike is a single
reading that towers over both neighbours, so score each reading by how far it exceeds the
larger of the previous and next value of the same sensor, scaled by that sensor's MAD, and
flag scores above 4. Measure precision and recall against the `spike` labels.

```sql
WITH r AS (
    SELECT reading_id, sensor_code,
           reading_value - greatest(lag(reading_value)  OVER w,
                                    lead(reading_value) OVER w) AS excess
    FROM mobility.sensor_readings
    WINDOW w AS (PARTITION BY sensor_code ORDER BY reading_time)
), scale AS (
    SELECT sensor_code,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(excess)) AS mad
    FROM r
    GROUP BY sensor_code
), flagged AS (
    SELECT r.reading_id, coalesce(r.excess > 4 * 1.4826 * s.mad, false) AS is_spike
    FROM r JOIN scale s USING (sensor_code)
), truth AS (
    SELECT entity_id AS reading_id FROM meta.ground_truth
    WHERE entity = 'mobility.sensor_readings' AND label = 'spike'
), c AS (
    SELECT count(*) FILTER (WHERE f.is_spike AND t.reading_id IS NOT NULL)     AS tp,
           count(*) FILTER (WHERE f.is_spike AND t.reading_id IS NULL)         AS fp,
           count(*) FILTER (WHERE NOT f.is_spike AND t.reading_id IS NOT NULL) AS fn
    FROM flagged f LEFT JOIN truth t USING (reading_id)
)
SELECT tp, fp, fn,
       round(tp::numeric / nullif(tp + fp, 0), 3) AS precision,
       round(tp::numeric / nullif(tp + fn, 0), 3) AS recall
FROM c;
```

```text
 tp  | fp | fn  | precision | recall
-----+----+-----+-----------+--------
 266 | 73 | 120 |     0.785 |  0.689
```

Compare with the capstone's ensemble in 16.2 (F1 0.816 on spikes): this one-line rule
reaches roughly 0.73.

**16.4** Is walkable access to essentials related to neighbourhood income? Read the equity
statistics of the accessibility study.

```sql
SELECT metric, n_neighborhoods, pearson_r, spearman_rho, slope_per_income_sd
FROM accessibility.equity_stats
ORDER BY metric;
```

```text
       metric        | n_neighborhoods | pearson_r | spearman_rho | slope_per_income_sd
---------------------+-----------------+-----------+--------------+---------------------
 access_index        |              24 |    -0.037 |       -0.032 |             -0.6271
 share_15min_all     |              24 |    -0.047 |       -0.295 |             -0.0106
 share_hospital_1200 |              24 |    -0.087 |       -0.256 |             -0.0284
 share_park_800      |              24 |    -0.045 |       -0.027 |             -0.0096
 share_school_800    |              24 |    -0.120 |       -0.038 |             -0.0319
 share_transit_800   |              24 |     0.190 |        0.209 |              0.0445
```
