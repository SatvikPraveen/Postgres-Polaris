.
├── .DS_Store
├── .env.example
├── .gitignore
├── data
│   ├── boundaries.geojson
│   ├── documents.jsonb
│   ├── sample_queries.md
│   ├── seeds.csv
│   └── timeseries.csv
├── docker
│   ├── .env.example
│   ├── docker-compose.yml
│   ├── Dockerfile
│   ├── initdb
│   │   ├── 000_create_database.sql
│   │   ├── 010_enable_extensions.sql
│   │   ├── 020_roles_and_security.sql
│   │   └── 999_health_checks.sql
│   └── pgadmin_servers.json
├── docs
│   ├── EXPLAIN_PLAN_LIBRARY.md
│   ├── HOWTO_SETUP.md
│   ├── LEARNING_PATHS.md
│   ├── MODULE_MAP_EXERCISES.md
│   └── TROUBLESHOOTING.md
├── examples
│   ├── analytics_showcase.sql
│   ├── geospatial_showcase.sql
│   ├── performance_tuning_showcase.sql
│   ├── quick_demo.sql
│   └── security_showcase.sql
├── generate_postgres_polaris.sh
├── LICENSE
├── Makefile
├── PROJECT_STRUCTURE.md
├── README.md
├── scripts
│   ├── backup_demo.sh
│   ├── load_sample_data.sh
│   ├── reset_db.sh
│   └── run_sql.sh
├── sql
│   ├── 00_init
│   │   ├── 000_schemas.sql
│   │   ├── 010_comments_conventions.sql
│   │   └── 999_reset_demo_data.sql
│   ├── 01_schema_design
│   │   ├── civics.sql
│   │   ├── commerce.sql
│   │   ├── documents.sql
│   │   ├── geo.sql
│   │   └── mobility.sql
│   ├── 02_constraints_indexes
│   │   ├── constraints.sql
│   │   ├── indexing_basics.sql
│   │   └── specialist_indexes.sql
│   ├── 03_dml_queries
│   │   ├── practice_selects.sql
│   │   ├── seed_data.sql
│   │   └── window_cts_recursion.sql
│   ├── 04_views_matviews
│   │   ├── materialized_views.sql
│   │   └── views.sql
│   ├── 05_functions_triggers
│   │   ├── event_triggers.sql
│   │   ├── plpgsql_basics.sql
│   │   └── triggers_auditing.sql
│   ├── 06_jsonb_fulltext
│   │   ├── fulltext_search_ranking.sql
│   │   └── jsonb_modeling_validation.sql
│   ├── 07_geospatial
│   │   ├── postgis_basics.sql
│   │   ├── routing_nearest.sql
│   │   └── spatial_indexes_queries.sql
│   ├── 08_partitioning_timeseries
│   │   ├── declarative_partitioning.sql
│   │   └── time_bucketing_retention.sql
│   ├── 09_data_movement
│   │   ├── copy_bulk_operations.sql
│   │   └── postgres_fdw_federation.sql
│   ├── 10_tx_mvcc_locks
│   │   ├── lock_scenarios.sql
│   │   ├── mvcc_visibility_demos.sql
│   │   └── transactions_isolation.sql
│   ├── 11_perf_tuning
│   │   ├── explain_analyze_playbook.sql
│   │   ├── index_advisor_patterns.sql
│   │   └── stats_and_autovaccum.sql
│   ├── 12_security_rls
│   │   ├── column_privacy_masks.sql
│   │   └── rls_policies.sql
│   ├── 13_backup_replication
│   │   ├── backup_restore_playbook.sql
│   │   ├── logical_replication_demo.sql
│   │   └── point_in_time_recovery.sql
│   ├── 14_async_patterns
│   │   ├── advisory_locks_coordination.sql
│   │   ├── listen_notify_pubsub.sql
│   │   └── pg_cron_scheduled_jobs.sql
│   ├── 15_testing_quality
│   │   ├── data_quality_checks.sql
│   │   ├── performance_regression_tests.sql
│   │   └── pgtap_unit_tests.sql
│   └── 16_capstones
│       ├── anomaly_detection_patterns.sql
│       ├── citywide_analytics_dashboard.sql
│       ├── geo_accessibility_study.sql
│       └── real_time_monitoring_views.sql
└── tests
    ├── data_integrity_checks.sql
    ├── performance_benchmarks.sql
    ├── regression_tests.sql
    └── schema_validation.sql

26 directories, 88 files
