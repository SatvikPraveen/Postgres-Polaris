-- File: sql/00_init/999_reset_demo_data.sql
-- Purpose: Return the database to the pristine synthetic dataset.
--
-- The generator truncates every base table and regenerates it from
-- (scale, seed), so a reset is simply a re-run. Objects created by modules
-- (views, functions, module-owned tables) are left untouched.
--
--   psql -v scale=1 -v seed=42 -f sql/00_init/999_reset_demo_data.sql

\ir ../03_dml_queries/seed_data.sql
