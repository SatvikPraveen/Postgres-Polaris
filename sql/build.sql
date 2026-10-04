-- File: sql/build.sql
-- Purpose: Single entry point that builds the Polaris City base dataset.
--
--   psql -v ON_ERROR_STOP=1 -v scale=1 -v seed=42 -f sql/build.sql
--   psql ... -v modules=1 -f sql/build.sql      -- also run modules 02-16
--
-- Stages
--   1. extensions and schemas            (00_init)
--   2. domain tables                     (01_schema_design)
--   3. integrity constraints             (02_constraints_indexes/constraints.sql)
--   4. synthetic data, scale x seed      (03_dml_queries/seed_data.sql)
--   5. optional: every curriculum module in numeric order
--
-- Each module is standalone and idempotent, so stage 5 can also be run one
-- file at a time (scripts/run_sql.sh) or verified in isolation
-- (scripts/check_modules.sh).

\set ON_ERROR_STOP on
\set QUIET on
\timing off

\echo '[polaris] 1/4 extensions and schemas'
\ir 00_init/005_extensions.sql
\ir 00_init/000_schemas.sql

\echo '[polaris] 2/4 domain tables'
\ir 01_schema_design/civics.sql
\ir 01_schema_design/commerce.sql
\ir 01_schema_design/mobility.sql
\ir 01_schema_design/geo.sql
\ir 01_schema_design/documents.sql
\ir 00_init/010_comments_conventions.sql

\echo '[polaris] 3/4 integrity constraints'
\ir 02_constraints_indexes/constraints.sql

\echo '[polaris] 4/4 synthetic data'
\ir 03_dml_queries/seed_data.sql

\if :{?modules}
\echo '[polaris] modules 02-16'
\ir 02_constraints_indexes/indexing_basics.sql
\ir 02_constraints_indexes/specialist_indexes.sql
\ir 03_dml_queries/practice_selects.sql
\ir 03_dml_queries/window_cts_recursion.sql
\ir 04_views_matviews/views.sql
\ir 04_views_matviews/materialized_views.sql
\ir 05_functions_triggers/plpgsql_basics.sql
\ir 05_functions_triggers/triggers_auditing.sql
\ir 05_functions_triggers/event_triggers.sql
\ir 06_jsonb_fulltext/jsonb_modeling_validation.sql
\ir 06_jsonb_fulltext/fulltext_search_ranking.sql
\ir 07_geospatial/postgis_basics.sql
\ir 07_geospatial/spatial_indexes_queries.sql
\ir 07_geospatial/routing_nearest.sql
\ir 08_partitioning_timeseries/declarative_partitioning.sql
\ir 08_partitioning_timeseries/time_bucketing_retention.sql
\ir 09_data_movement/copy_bulk_operations.sql
\ir 09_data_movement/postgres_fdw_federation.sql
\ir 10_tx_mvcc_locks/transactions_isolation.sql
\ir 10_tx_mvcc_locks/mvcc_visibility_demos.sql
\ir 10_tx_mvcc_locks/lock_scenarios.sql
\ir 11_perf_tuning/explain_analyze_playbook.sql
\ir 11_perf_tuning/index_advisor_patterns.sql
\ir 11_perf_tuning/stats_and_autovacuum.sql
\ir 12_security_rls/rls_policies.sql
\ir 12_security_rls/column_privacy_masks.sql
\ir 13_backup_replication/backup_restore_playbook.sql
\ir 13_backup_replication/point_in_time_recovery.sql
\ir 13_backup_replication/logical_replication_demo.sql
\ir 14_async_patterns/listen_notify_pubsub.sql
\ir 14_async_patterns/advisory_locks_coordination.sql
\ir 14_async_patterns/pg_cron_scheduled_jobs.sql
\ir 15_testing_quality/data_quality_checks.sql
\ir 15_testing_quality/pgtap_unit_tests.sql
\ir 15_testing_quality/performance_regression_tests.sql
\ir 16_capstones/citywide_analytics_dashboard.sql
\ir 16_capstones/geo_accessibility_study.sql
\ir 16_capstones/anomaly_detection_patterns.sql
\ir 16_capstones/real_time_monitoring_views.sql
\endif

\unset QUIET
\echo '[polaris] build complete'
SELECT generator_version, scale, seed, as_of, generation_ms FROM meta.dataset;
