-- File: sql/02_constraints_indexes/specialist_indexes.sql
-- Purpose: Partial, expression, INCLUDE/covering, unique-partial, Bloom indexes,
--          plus hypothetical indexes with HypoPG and index-hygiene helpers.
--
-- Idempotent (IF NOT EXISTS / OR REPLACE) and standalone (base data only).
--
-- GOLDEN RULE for index definitions: every function used in an index
-- expression or partial-index WHERE clause must be IMMUTABLE. That rules out
-- now(), CURRENT_DATE, CURRENT_TIMESTAMP (they change), and also
-- EXTRACT/date_trunc directly on timestamptz (the result depends on the
-- session TimeZone setting). Fixes used below:
--   * time windows  -> put the window in the QUERY, or build a "rolling"
--                      partial index from a literal boundary (see section 2)
--   * timestamptz   -> convert first: (ts AT TIME ZONE 'UTC') is immutable

\echo '== specialist_indexes =='

-- =============================================================================
-- 1. PARTIAL INDEXES (index only the subset of rows queries target)
-- =============================================================================

-- Status-specific partial indexes: small, and the planner uses them whenever
-- the query's WHERE clause implies the index predicate.
CREATE INDEX IF NOT EXISTS idx_citizens_active_zip ON civics.citizens(zip_code)
    WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_permits_pending_by_type ON civics.permit_applications(permit_type, application_date)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_tax_overdue ON civics.tax_payments(citizen_id, due_date)
    WHERE payment_status = 'overdue';

-- "Expiring soon" is relative to today, so the window lives in the query; the
-- index covers active licenses ordered by expiration_date.
CREATE INDEX IF NOT EXISTS idx_licenses_active_expiration ON commerce.business_licenses(expiration_date, merchant_id)
    WHERE status = 'active';

-- Same idea for maintenance due dates (the query supplies "<= today + 7 days")
CREATE INDEX IF NOT EXISTS idx_stations_maintenance_due ON mobility.stations(next_maintenance_due, station_type)
    WHERE status <> 'offline';

CREATE INDEX IF NOT EXISTS idx_complaints_high_priority_open ON documents.complaint_records(submitted_at DESC, category)
    WHERE priority_level IN ('high', 'urgent') AND status NOT IN ('resolved', 'archived', 'rejected');

-- Geography-specific partial indexes
CREATE INDEX IF NOT EXISTS idx_pois_restaurants_active ON geo.points_of_interest(neighborhood_id, name)
    WHERE category = 'restaurant' AND is_active = true;

-- construction_status values in the data: 'under_construction', 'complete'
CREATE INDEX IF NOT EXISTS idx_roads_construction ON geo.road_segments(road_name, maintenance_authority)
    WHERE construction_status = 'under_construction';

-- =============================================================================
-- 2. ROLLING PARTIAL INDEXES (time windows done right)
-- =============================================================================
-- WHERE order_date >= CURRENT_DATE - 30 days  ->  ERROR: functions in index
-- predicate must be marked IMMUTABLE. The workaround is to bake a LITERAL
-- boundary into the predicate and re-create the index periodically (e.g. a
-- nightly job builds the new one CONCURRENTLY, then drops the old one).
-- Queries must use a boundary >= the literal so the planner can prove the
-- predicate. Here the boundary is computed from the dataset's reference "now"
-- (meta.as_of()) so it lines up with the synthetic data.

DO $$
DECLARE
    v_now timestamptz := meta.as_of();
BEGIN
    -- open orders from the last 30 days
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_orders_recent_incomplete ON commerce.orders (merchant_id, order_date DESC)
           WHERE status IN (''pending'', ''confirmed'', ''processing'', ''shipped'') AND order_date >= %L',
        date_trunc('day', v_now) - interval '30 days');

    -- last 7 days of trips by mode
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_trips_recent_by_mode ON mobility.trip_segments (trip_mode, start_time DESC)
           WHERE start_time >= %L',
        date_trunc('day', v_now) - interval '7 days');

    -- last 24 hours of sensor readings
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_sensors_recent_readings ON mobility.sensor_readings (sensor_code, reading_time DESC)
           WHERE reading_time >= %L',
        date_trunc('day', v_now) - interval '1 day');

    -- non-cancelled, positive-value orders from the last 6 months
    EXECUTE format(
        'CREATE INDEX IF NOT EXISTS idx_orders_active_recent ON commerce.orders (merchant_id, order_date DESC, total_amount)
           WHERE status NOT IN (''cancelled'', ''refunded'') AND total_amount > 0 AND order_date >= %L',
        date_trunc('month', v_now) - interval '6 months');
END
$$;

\echo '-- The literal boundary baked into a rolling partial index'
SELECT indexrelid::regclass AS index_name, pg_get_expr(indpred, indrelid) AS predicate
FROM pg_index
WHERE indexrelid IN ('mobility.idx_sensors_recent_readings'::regclass, 'mobility.idx_trips_recent_by_mode'::regclass)
ORDER BY 1;

-- =============================================================================
-- 3. EXPRESSION / FUNCTIONAL INDEXES
-- =============================================================================

-- Case-insensitive lookups (query must repeat the exact expression)
CREATE INDEX IF NOT EXISTS idx_citizens_fullname_lower ON civics.citizens(lower(first_name || ' ' || last_name));
CREATE INDEX IF NOT EXISTS idx_merchants_business_name_lower ON commerce.merchants(lower(business_name));
CREATE INDEX IF NOT EXISTS idx_pois_name_lower ON geo.points_of_interest(lower(name));
CREATE INDEX IF NOT EXISTS idx_roads_name_lower ON geo.road_segments(lower(road_name));

-- Date parts: EXTRACT(... FROM timestamptz) depends on TimeZone -> not immutable.
-- Normalise to UTC first; queries must use the same expression.
CREATE INDEX IF NOT EXISTS idx_orders_year_month ON commerce.orders(
    (EXTRACT(YEAR FROM (order_date AT TIME ZONE 'UTC'))),
    (EXTRACT(MONTH FROM (order_date AT TIME ZONE 'UTC'))));
CREATE INDEX IF NOT EXISTS idx_complaints_day_of_week ON documents.complaint_records(
    (EXTRACT(DOW FROM (submitted_at AT TIME ZONE 'UTC'))));
CREATE INDEX IF NOT EXISTS idx_trips_hour_of_day ON mobility.trip_segments(
    (EXTRACT(HOUR FROM (start_time AT TIME ZONE 'UTC'))));

-- Calculated fields
CREATE INDEX IF NOT EXISTS idx_tax_balance_owed ON civics.tax_payments((amount_due - amount_paid))
    WHERE payment_status <> 'paid';

-- Processing time only for decided permits (no CURRENT_TIMESTAMP inside the index)
CREATE INDEX IF NOT EXISTS idx_permits_processing_time ON civics.permit_applications(
    (EXTRACT(EPOCH FROM (approval_date - application_date)) / 86400)
) WHERE approval_date IS NOT NULL;

-- A non-trivial expression must be wrapped in its own parentheses
CREATE INDEX IF NOT EXISTS idx_trips_speed_kmh ON mobility.trip_segments(
    (CASE WHEN duration_minutes > 0 THEN distance_km * 60.0 / duration_minutes END)
) WHERE duration_minutes IS NOT NULL AND distance_km IS NOT NULL;

-- JSON/JSONB expressions (keys that actually occur in the data)
CREATE INDEX IF NOT EXISTS idx_complaints_metadata_hazard ON documents.complaint_records((metadata->>'hazard_type'))
    WHERE metadata ? 'hazard_type';

-- business_hours looks like {"sat": "09:00-14:00", "mon-fri": "08:00-18:00"}
CREATE INDEX IF NOT EXISTS idx_pois_hours_saturday ON geo.points_of_interest((business_hours->>'sat'))
    WHERE business_hours ? 'sat';

-- Distance from the city centre in METRES. Casting to geography gives a
-- geodesic distance; ST_Distance on raw 4326 geometry would return degrees.
CREATE INDEX IF NOT EXISTS idx_pois_metres_from_city_center ON geo.points_of_interest(
    (ST_Distance(location_geom::geography, 'SRID=4326;POINT(-96.80 32.98)'::geography))
);

-- Trigram GIN for LIKE/ILIKE '%term%' and similarity()
CREATE INDEX IF NOT EXISTS idx_complaints_subject_trgm ON documents.complaint_records
    USING gin(subject gin_trgm_ops);

CREATE INDEX IF NOT EXISTS idx_policies_title_trgm ON documents.policy_documents
    USING gin(title gin_trgm_ops);

-- =============================================================================
-- 4. COVERING INDEXES (INCLUDE clause - PostgreSQL 11+)
-- INCLUDE columns are stored only in leaf pages: they enable index-only scans
-- but cannot be searched or used for ordering.
-- =============================================================================

CREATE INDEX IF NOT EXISTS idx_citizens_email_include ON civics.citizens(email)
    INCLUDE (first_name, last_name, phone, street_address, status);

CREATE INDEX IF NOT EXISTS idx_citizens_zip_include ON civics.citizens(zip_code, status)
    INCLUDE (citizen_id, first_name, last_name, email);

CREATE INDEX IF NOT EXISTS idx_orders_merchant_date_include ON commerce.orders(merchant_id, order_date DESC)
    INCLUDE (order_number, status, total_amount, customer_citizen_id);

CREATE INDEX IF NOT EXISTS idx_orders_customer_include ON commerce.orders(customer_citizen_id)
    INCLUDE (order_id, order_date, merchant_id, total_amount, status);

CREATE INDEX IF NOT EXISTS idx_permits_citizen_include ON civics.permit_applications(citizen_id, status)
    INCLUDE (permit_number, permit_type, property_address, fee_amount, application_date);

CREATE INDEX IF NOT EXISTS idx_stations_type_include ON mobility.stations(station_type, status)
    INCLUDE (station_code, station_name, total_capacity, latitude, longitude);

CREATE INDEX IF NOT EXISTS idx_pois_category_include ON geo.points_of_interest(category, neighborhood_id)
    INCLUDE (name, street_address, phone, average_rating)
    WHERE is_active = true;

CREATE INDEX IF NOT EXISTS idx_complaints_status_include ON documents.complaint_records(status, priority_level)
    INCLUDE (complaint_number, subject, reporter_name, reporter_email, submitted_at);

-- =============================================================================
-- 5. MULTI-COLUMN SPECIALISED INDEXES
-- =============================================================================

-- Hash indexes are SINGLE-column only. Demonstrate the error safely:
DO $$
BEGIN
    EXECUTE 'CREATE INDEX idx_tax_citizen_year_type_hash ON civics.tax_payments
             USING hash (citizen_id, tax_year, tax_type)';
EXCEPTION WHEN feature_not_supported THEN
    RAISE NOTICE 'As expected: %', SQLERRM;
END
$$;

-- Alternatives: a hash index on the most selective column, or a multi-column B-tree
CREATE INDEX IF NOT EXISTS idx_trip_segments_trip_id_hash ON mobility.trip_segments USING hash(trip_id);
CREATE INDEX IF NOT EXISTS idx_tax_citizen_year_type ON civics.tax_payments(citizen_id, tax_year, tax_type);

-- GIN over a combined JSONB expression (both columns searchable with one @>)
CREATE INDEX IF NOT EXISTS idx_complaints_all_json_gin ON documents.complaint_records
    USING gin((metadata || COALESCE(attachments, '{}'::jsonb)));

-- Multi-column GiST: geometry + enum (enum support in GiST comes from btree_gist)
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE INDEX IF NOT EXISTS idx_pois_category_rating_geo ON geo.points_of_interest
    USING gist(location_geom, category)
    WHERE is_active = true AND average_rating >= 4.0;

-- =============================================================================
-- 6. UNIQUE PARTIAL INDEXES (conditional uniqueness)
-- =============================================================================

-- Only one approved permit per parcel per type -- a partial UNIQUE index.
-- Compare it with excl_permit_overlap (constraints.sql): the unique index
-- forbids a second approved permit forever, while the exclusion constraint
-- forbids only *overlapping* validity periods, so a renewal starting the day
-- the old permit expires is allowed. The exclusion constraint encodes the real
-- rule; the partial index is shown for its EXPLAIN/size characteristics and
-- then dropped so it does not change the base data model for later modules.
CREATE UNIQUE INDEX IF NOT EXISTS idx_permits_active_property_type ON civics.permit_applications(parcel_id, permit_type)
    WHERE status = 'approved' AND parcel_id IS NOT NULL;
SELECT pg_size_pretty(pg_relation_size('civics.idx_permits_active_property_type')) AS partial_unique_index_size;
DROP INDEX IF EXISTS civics.idx_permits_active_property_type;

-- Only one active general business license per merchant (license_type values
-- in the data are snake_case: general_business, food_service, health_facility)
CREATE UNIQUE INDEX IF NOT EXISTS idx_licenses_primary_merchant ON commerce.business_licenses(merchant_id)
    WHERE license_type = 'general_business' AND status = 'active';

-- Note: station_code is already UNIQUE on its own, so (station_code, station_type)
-- is logically redundant - shown as an example find_redundant_indexes() flags.
CREATE UNIQUE INDEX IF NOT EXISTS idx_stations_code_type ON mobility.stations(station_code, station_type);

-- =============================================================================
-- 7. BLOOM INDEXES (any-subset equality over many columns)
-- One small signature index answers equality on ANY combination of its
-- columns (a B-tree needs the leading column). Lossy -> always rechecked.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS bloom;

-- The bloom extension ships operator classes only for int4 and text
-- (bigint/enum columns would need casts in both index and query).
CREATE INDEX IF NOT EXISTS idx_citizens_bloom ON civics.citizens
    USING bloom(first_name, last_name, zip_code, city)
    WITH (length = 80, col1 = 2, col2 = 2, col3 = 2, col4 = 2);

-- =============================================================================
-- 8. EXPLAIN EVIDENCE
-- =============================================================================

ANALYZE civics.citizens, civics.tax_payments, commerce.orders, commerce.business_licenses,
        documents.complaint_records, geo.points_of_interest, mobility.trip_segments,
        mobility.sensor_readings;

\echo '-- Partial index: predicate implied by the query'
EXPLAIN (COSTS OFF)
SELECT citizen_id, due_date FROM civics.tax_payments
WHERE payment_status = 'overdue' AND citizen_id = 1234;

\echo '-- Rolling partial index: query window (last 12h) lies inside the indexed window (last 1 day)'
EXPLAIN (COSTS OFF)
SELECT sensor_code, reading_time, reading_value FROM mobility.sensor_readings
WHERE sensor_code = 'AQI-001'
  AND reading_time >= TIMESTAMPTZ '2025-12-31 12:00:00+00'
ORDER BY reading_time DESC;

\echo '-- Expression index on a UTC-normalised date part'
EXPLAIN (COSTS OFF)
SELECT count(*) FROM commerce.orders
WHERE EXTRACT(YEAR FROM (order_date AT TIME ZONE 'UTC')) = 2025
  AND EXTRACT(MONTH FROM (order_date AT TIME ZONE 'UTC')) = 12;

\echo '-- JSONB expression index'
EXPLAIN (COSTS OFF)
SELECT complaint_id FROM documents.complaint_records
WHERE metadata ? 'hazard_type' AND metadata->>'hazard_type' = 'pothole';

\echo '-- Expression index in metres: POIs within 500 m of the centre'
EXPLAIN (COSTS OFF)
SELECT poi_id, name FROM geo.points_of_interest
WHERE ST_Distance(location_geom::geography, 'SRID=4326;POINT(-96.80 32.98)'::geography) < 500;

\echo '-- Trigram GIN for an infix ILIKE'
EXPLAIN (COSTS OFF)
SELECT complaint_id, subject FROM documents.complaint_records WHERE subject ILIKE '%pothole%';

\echo '-- Bloom index: equality on first_name alone (no B-tree leads with first_name)'
EXPLAIN (COSTS OFF)
SELECT citizen_id, first_name, last_name FROM civics.citizens WHERE first_name = 'Mateo';

-- =============================================================================
-- 9. HYPOTHETICAL INDEXES WITH HypoPG
-- "Would an index help?" without paying to build it. Hypothetical indexes live
-- only in this backend's memory, are invisible to other sessions and are used
-- only by plain EXPLAIN (not EXPLAIN ANALYZE, which really executes the query).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS hypopg;
SELECT hypopg_reset();   -- start clean (idempotent re-runs)

\echo '-- Before: no index on fare_paid -> Seq Scan + Sort'
EXPLAIN (COSTS OFF)
SELECT trip_id, fare_paid FROM mobility.trip_segments
WHERE fare_paid > 20
ORDER BY fare_paid DESC
LIMIT 10;

\echo '-- Create a hypothetical index (instant, zero disk)'
SELECT indexname, pg_size_pretty(hypopg_relation_size(indexrelid)) AS estimated_size
FROM hypopg_create_index('CREATE INDEX ON mobility.trip_segments (fare_paid DESC)');

\echo '-- After: EXPLAIN now picks the hypothetical <oid>btree_trip_segments_fare_paid index'
EXPLAIN
SELECT trip_id, fare_paid FROM mobility.trip_segments
WHERE fare_paid > 20
ORDER BY fare_paid DESC
LIMIT 10;

-- If the plan improves enough, create it for real (CONCURRENTLY in production):
--   CREATE INDEX CONCURRENTLY idx_trips_fare_paid ON mobility.trip_segments (fare_paid DESC);

-- hypopg_hide_index() does the reverse: "what if I dropped this real index?"
\echo '-- Hide a real index to test whether it is still needed'
SELECT hypopg_hide_index('civics.idx_tax_overdue'::regclass);
EXPLAIN (COSTS OFF)
SELECT citizen_id, due_date FROM civics.tax_payments
WHERE payment_status = 'overdue' AND citizen_id = 1234;
SELECT hypopg_unhide_all_indexes();
SELECT hypopg_reset();

-- =============================================================================
-- 10. INDEX HYGIENE FUNCTIONS
-- =============================================================================

-- Heuristic suggestions: tables with heavy sequential scanning and commonly
-- filtered columns that no index starts with. (Real advisors combine
-- pg_stat_statements + HypoPG, as in sql/11_perf_tuning.)
CREATE OR REPLACE FUNCTION analytics.suggest_missing_indexes()
RETURNS TABLE(
    suggested_index TEXT,
    estimated_benefit TEXT,
    table_name TEXT,
    columns_suggested TEXT
) AS $$
    SELECT
        format('CREATE INDEX ON %I.%I (%I)', c.table_schema, c.table_name, c.column_name),
        CASE WHEN COALESCE(st.seq_scan, 0) > COALESCE(st.idx_scan, 0) THEN 'Medium' ELSE 'Low' END,
        (c.table_schema || '.' || c.table_name)::TEXT,
        c.column_name::TEXT
    FROM information_schema.columns c
    JOIN information_schema.tables t
      ON t.table_schema = c.table_schema AND t.table_name = c.table_name AND t.table_type = 'BASE TABLE'
    LEFT JOIN pg_stat_user_tables st
      ON st.schemaname = c.table_schema AND st.relname = c.table_name
    WHERE c.table_schema IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
      AND c.column_name IN ('created_at', 'updated_at', 'status')
      AND NOT EXISTS (   -- no index whose FIRST key column is this column
          SELECT 1
          FROM pg_index i
          JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
          WHERE i.indrelid = format('%I.%I', c.table_schema, c.table_name)::regclass
            AND a.attname = c.column_name)
    ORDER BY 3, 4;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION analytics.suggest_missing_indexes() IS
'Heuristic: commonly-filtered columns that no index leads with';

-- Redundant indexes: same table, same access method, same predicate, no
-- expressions, and whose key columns are a leading prefix of another index's
-- key columns. A unique/PK index is never reported as the redundant one.
DROP FUNCTION IF EXISTS analytics.find_redundant_indexes();
CREATE FUNCTION analytics.find_redundant_indexes()
RETURNS TABLE(
    potentially_redundant TEXT,
    overlaps_with TEXT,
    schema_table TEXT
) AS $$
    WITH idx AS (
        SELECT i.indexrelid, i.indrelid, i.indisunique, i.indpred, i.indexprs,
               c.relam, string_to_array(i.indkey::text, ' ') AS keys,
               i.indnkeyatts, i.indnatts
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indexrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    )
    SELECT a.indexrelid::regclass::TEXT,
           b.indexrelid::regclass::TEXT,
           a.indrelid::regclass::TEXT
    FROM idx a
    JOIN idx b ON a.indrelid = b.indrelid
              AND a.indexrelid <> b.indexrelid
              AND a.relam = b.relam
    WHERE NOT a.indisunique
      AND a.indexprs IS NULL AND b.indexprs IS NULL
      AND pg_get_expr(a.indpred, a.indrelid) IS NOT DISTINCT FROM pg_get_expr(b.indpred, b.indrelid)
      AND a.indnkeyatts <= b.indnkeyatts
      AND a.keys[1:a.indnkeyatts] = b.keys[1:a.indnkeyatts]
      -- same keys: report the one with fewer INCLUDE columns; exact
      -- duplicates are reported in one direction only
      AND (a.indnkeyatts < b.indnkeyatts OR b.indisunique OR a.indnatts < b.indnatts
           OR (a.indnatts = b.indnatts AND a.indexrelid > b.indexrelid))
    ORDER BY 3, 1, 2;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION analytics.find_redundant_indexes() IS
'Identify non-unique indexes whose key columns are a leading prefix of another index (same method/predicate)';

\echo '-- Redundant index candidates on commerce.orders (B-tree sort order is not compared)'
SELECT * FROM analytics.find_redundant_indexes()
WHERE schema_table = 'commerce.orders'
LIMIT 10;

\echo '-- Missing-index suggestions (first 5)'
SELECT * FROM analytics.suggest_missing_indexes() LIMIT 5;
