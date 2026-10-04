-- Location: /tests/schema_validation.sql
-- =============================================================================
-- pgTAP suite 1/3: SCHEMA SHAPE
-- =============================================================================
-- What it teaches / guards:
--   * the 18 domain base tables (civics, commerce, mobility, geo, documents)
--     plus the meta provenance tables exist,
--   * every table has the expected primary key, every relationship has its
--     foreign key, and the indexes the curriculum relies on are present with the
--     right access method (btree / GiST / GIN),
--   * every enum carries exactly the documented labels, in order,
--   * geometry columns are typed and SRID-constrained (4326),
--   * the triggers and helper functions the modules call are installed.
--
-- Run:   docker exec polaris-db pg_prove -U polaris -d <db> /tests/schema_validation.sql
--   or:  psql -X -d <db> -f /tests/schema_validation.sql
-- Everything runs inside one transaction that is rolled back, so the suite
-- never changes the database.
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET 1
\pset format unaligned
\pset tuples_only true
\pset pager off

BEGIN;
SELECT plan(184);

-- -----------------------------------------------------------------------------
-- 1. Extensions and schemas the base build depends on
-- -----------------------------------------------------------------------------
SELECT has_extension('postgis',    'PostGIS is installed');
SELECT has_extension('btree_gist', 'btree_gist is installed (needed by the exclusion constraints)');
SELECT has_extension('pg_trgm',    'pg_trgm is installed');
SELECT has_extension('pgtap',      'pgTAP is installed');

SELECT has_schema(s, format('schema %s exists', s))
FROM unnest(ARRAY['civics','commerce','mobility','geo','documents','meta','synth','analytics','audit','auth']) AS s;

-- -----------------------------------------------------------------------------
-- 2. The 18 base tables (+ 3 provenance tables)
--    has_table is used instead of tables_are() so the suite still passes after
--    modules add their own tables (e.g. mobility.sensor_readings_part).
-- -----------------------------------------------------------------------------
SELECT has_table(s, t, format('table %s.%s exists', s, t))
FROM (VALUES
    ('civics','citizens'), ('civics','permit_applications'), ('civics','tax_payments'), ('civics','voting_records'),
    ('commerce','merchants'), ('commerce','business_licenses'), ('commerce','orders'), ('commerce','order_items'), ('commerce','payments'),
    ('mobility','stations'), ('mobility','station_inventory'), ('mobility','trip_segments'), ('mobility','sensor_readings'),
    ('geo','neighborhood_boundaries'), ('geo','points_of_interest'), ('geo','road_segments'),
    ('documents','complaint_records'), ('documents','policy_documents'),
    ('meta','dataset'), ('meta','planted_effects'), ('meta','ground_truth')
) AS v(s, t);

-- Exactly 18 ordinary tables live in the five domain schemas of the base.
-- (Module-owned extras are allowed: we only require that the 18 are there and
--  that none of them is unlogged/temporary.)
SELECT is(
    (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind = 'r' AND c.relpersistence = 'p'
       AND (n.nspname, c.relname) IN (
         ('civics','citizens'), ('civics','permit_applications'), ('civics','tax_payments'), ('civics','voting_records'),
         ('commerce','merchants'), ('commerce','business_licenses'), ('commerce','orders'), ('commerce','order_items'), ('commerce','payments'),
         ('mobility','stations'), ('mobility','station_inventory'), ('mobility','trip_segments'), ('mobility','sensor_readings'),
         ('geo','neighborhood_boundaries'), ('geo','points_of_interest'), ('geo','road_segments'),
         ('documents','complaint_records'), ('documents','policy_documents'))),
    18, 'all 18 base tables are permanent, ordinary heap tables');

-- -----------------------------------------------------------------------------
-- 3. Primary keys (single bigint surrogate key per base table)
-- -----------------------------------------------------------------------------
SELECT col_is_pk(s, t, c, format('%s.%s primary key is (%s)', s, t, c))
FROM (VALUES
    ('civics','citizens','citizen_id'), ('civics','permit_applications','permit_id'),
    ('civics','tax_payments','tax_id'), ('civics','voting_records','vote_id'),
    ('commerce','merchants','merchant_id'), ('commerce','business_licenses','license_id'),
    ('commerce','orders','order_id'), ('commerce','order_items','item_id'), ('commerce','payments','payment_id'),
    ('mobility','stations','station_id'), ('mobility','station_inventory','inventory_id'),
    ('mobility','trip_segments','trip_segment_id'), ('mobility','sensor_readings','reading_id'),
    ('geo','neighborhood_boundaries','neighborhood_id'), ('geo','points_of_interest','poi_id'),
    ('geo','road_segments','segment_id'),
    ('documents','complaint_records','complaint_id'), ('documents','policy_documents','policy_id')
) AS v(s, t, c);

SELECT col_type_is(s, t, c, 'bigint', format('%s.%s.%s is bigint', s, t, c))
FROM (VALUES
    ('civics','citizens','citizen_id'), ('commerce','orders','order_id'),
    ('commerce','order_items','item_id'), ('mobility','sensor_readings','reading_id')
) AS v(s, t, c);

-- -----------------------------------------------------------------------------
-- 4. Foreign keys: every documented relationship is declared
-- -----------------------------------------------------------------------------
SELECT fk_ok(fs, ft, fc, ps, pt, pc)
FROM (VALUES
    ('civics','permit_applications','citizen_id',      'civics','citizens','citizen_id'),
    ('civics','permit_applications','processed_by',    'civics','citizens','citizen_id'),
    ('civics','tax_payments','citizen_id',             'civics','citizens','citizen_id'),
    ('civics','voting_records','citizen_id',           'civics','citizens','citizen_id'),
    ('commerce','merchants','owner_citizen_id',        'civics','citizens','citizen_id'),
    ('commerce','business_licenses','merchant_id',     'commerce','merchants','merchant_id'),
    ('commerce','orders','merchant_id',                'commerce','merchants','merchant_id'),
    ('commerce','orders','customer_citizen_id',        'civics','citizens','citizen_id'),
    ('commerce','order_items','order_id',              'commerce','orders','order_id'),
    ('commerce','payments','order_id',                 'commerce','orders','order_id'),
    ('mobility','station_inventory','station_id',      'mobility','stations','station_id'),
    ('mobility','trip_segments','start_station_id',    'mobility','stations','station_id'),
    ('mobility','trip_segments','end_station_id',      'mobility','stations','station_id'),
    ('mobility','trip_segments','user_id',             'civics','citizens','citizen_id'),
    ('geo','points_of_interest','neighborhood_id',     'geo','neighborhood_boundaries','neighborhood_id'),
    ('geo','road_segments','neighborhood_id',          'geo','neighborhood_boundaries','neighborhood_id'),
    ('documents','complaint_records','neighborhood_id','geo','neighborhood_boundaries','neighborhood_id'),
    ('documents','complaint_records','reporter_citizen_id','civics','citizens','citizen_id'),
    ('documents','policy_documents','created_by',      'civics','citizens','citizen_id'),
    ('documents','policy_documents','approved_by',     'civics','citizens','citizen_id'),
    ('documents','policy_documents','supersedes_policy_id','documents','policy_documents','policy_id')
) AS v(fs, ft, fc, ps, pt, pc);

-- order_items are owned by their order: deleting an order cascades.
SELECT is(
    (SELECT confdeltype::text FROM pg_constraint WHERE conname = 'order_items_order_id_fkey'
       AND conrelid = 'commerce.order_items'::regclass),
    'c', 'order_items.order_id is ON DELETE CASCADE');

-- -----------------------------------------------------------------------------
-- 5. Unique business keys
-- -----------------------------------------------------------------------------
SELECT col_is_unique(s, t, c, format('%s.%s.%s is unique', s, t, c))
FROM (VALUES
    ('civics','citizens','email'), ('civics','permit_applications','permit_number'),
    ('commerce','merchants','tax_id'), ('commerce','orders','order_number'),
    ('commerce','business_licenses','license_number'), ('mobility','stations','station_code'),
    ('geo','neighborhood_boundaries','neighborhood_name'), ('documents','complaint_records','complaint_number')
) AS v(s, t, c);
SELECT col_is_unique('documents', 'policy_documents', ARRAY['policy_number','version'],
                     'documents.policy_documents (policy_number, version) is unique');

-- -----------------------------------------------------------------------------
-- 6. Key indexes and their access methods
--    GiST for geometry, GIN for tsvector/jsonb/arrays, btree for the rest.
-- -----------------------------------------------------------------------------
SELECT has_index(s, t, i, format('index %s on %s.%s exists', i, s, t))
FROM (VALUES
    ('civics','citizens','idx_citizens_email'), ('civics','citizens','idx_citizens_name'),
    ('commerce','orders','idx_orders_merchant'), ('commerce','orders','idx_orders_customer'),
    ('commerce','orders','idx_orders_date'), ('commerce','order_items','idx_order_items_order'),
    ('commerce','payments','idx_payments_order'),
    ('mobility','station_inventory','idx_inventory_station_time'), ('mobility','trip_segments','idx_trips_time'),
    ('mobility','sensor_readings','idx_sensors_code_time'), ('mobility','sensor_readings','idx_sensors_time_only'),
    ('geo','neighborhood_boundaries','idx_neighborhoods_geom'), ('geo','points_of_interest','idx_pois_geom'),
    ('geo','road_segments','idx_roads_geom'),
    ('documents','complaint_records','idx_complaints_search'), ('documents','complaint_records','idx_complaints_metadata'),
    ('documents','complaint_records','idx_complaints_location'),
    ('documents','policy_documents','idx_policies_search'), ('documents','policy_documents','idx_policies_content'),
    ('documents','policy_documents','idx_policies_tags')
) AS v(s, t, i);

SELECT index_is_type(s, t, i, am, format('%s is a %s index', i, am))
FROM (VALUES
    ('geo','neighborhood_boundaries','idx_neighborhoods_geom','gist'),
    ('geo','points_of_interest','idx_pois_geom','gist'),
    ('geo','road_segments','idx_roads_geom','gist'),
    ('documents','complaint_records','idx_complaints_search','gin'),
    ('documents','complaint_records','idx_complaints_metadata','gin'),
    ('documents','policy_documents','idx_policies_search','gin'),
    ('documents','policy_documents','idx_policies_content','gin'),
    ('documents','policy_documents','idx_policies_tags','gin'),
    ('commerce','orders','idx_orders_date','btree'),
    ('mobility','sensor_readings','idx_sensors_code_time','btree')
) AS v(s, t, i, am);

SELECT is(
    (SELECT pg_get_expr(indpred, indrelid) FROM pg_index WHERE indexrelid = 'documents.idx_complaints_location'::regclass),
    '(incident_latitude IS NOT NULL)', 'idx_complaints_location is a partial index on located complaints');

-- -----------------------------------------------------------------------------
-- 7. Enum types: exact labels in declared order
-- -----------------------------------------------------------------------------
SELECT enum_has_labels(s, e, labels, format('enum %s.%s has the documented labels', s, e))
FROM (VALUES
    ('civics','civic_status',      ARRAY['active','inactive','suspended','deceased']),
    ('civics','payment_status',    ARRAY['pending','paid','overdue','refunded']),
    ('civics','permit_status',     ARRAY['pending','approved','denied','expired','revoked']),
    ('civics','permit_type',       ARRAY['building','business','event','parking','street']),
    ('civics','tax_type',          ARRAY['property','income','business','vehicle','utility']),
    ('civics','vote_type',         ARRAY['municipal','school_board','referendum','special']),
    ('commerce','business_type',   ARRAY['restaurant','retail','service','manufacturing','technology','healthcare','other']),
    ('commerce','license_status',  ARRAY['active','pending','expired','suspended','revoked']),
    ('commerce','order_status',    ARRAY['pending','confirmed','processing','shipped','delivered','cancelled','refunded']),
    ('commerce','payment_method',  ARRAY['cash','credit_card','debit_card','bank_transfer','digital_wallet','check']),
    ('commerce','payment_status',  ARRAY['pending','completed','failed','refunded','disputed']),
    ('documents','access_level',   ARRAY['public','internal','restricted','confidential']),
    ('documents','document_status',ARRAY['draft','submitted','under_review','approved','resolved','published','archived','rejected','expired']),
    ('documents','document_type',  ARRAY['complaint','policy','notice','report','form','meeting_minutes','correspondence','application','permit_docs','other']),
    ('documents','priority_level', ARRAY['low','normal','high','urgent']),
    ('geo','poi_category',         ARRAY['government','school','hospital','park','retail','restaurant','bank','gas_station','library','community_center','worship','emergency','transportation','utility','other']),
    ('geo','road_surface',         ARRAY['asphalt','concrete','gravel','dirt','cobblestone']),
    ('geo','road_type',            ARRAY['interstate','highway','arterial','collector','local','residential','alley','walkway','bike_lane']),
    ('mobility','sensor_type',     ARRAY['traffic_counter','air_quality','noise','occupancy','speed','weather']),
    ('mobility','station_status',  ARRAY['active','maintenance','offline','full','empty']),
    ('mobility','station_type',    ARRAY['bus','rail','bike_share','scooter','park_ride','ev_charging']),
    ('mobility','trip_mode',       ARRAY['walking','cycling','bus','rail','car','rideshare','scooter','other'])
) AS v(s, e, labels);

-- Columns really use the enums (not free text).
SELECT col_type_is(s, t, c, ty, format('%s.%s.%s is %s', s, t, c, ty))
FROM (VALUES
    ('civics','citizens','status','civics.civic_status'),
    ('commerce','orders','status','commerce.order_status'),
    ('documents','complaint_records','status','documents.document_status'),
    ('mobility','sensor_readings','sensor_type','mobility.sensor_type')
) AS v(s, t, c, ty);

-- -----------------------------------------------------------------------------
-- 8. Spatial columns: typmod-constrained geometry in WGS84
-- -----------------------------------------------------------------------------
SELECT col_type_is(s, t, c, ty, format('%s.%s.%s is %s', s, t, c, ty))
FROM (VALUES
    ('civics','citizens','home_geom','geometry(Point,4326)'),
    ('geo','neighborhood_boundaries','boundary_geom','geometry(Polygon,4326)'),
    ('geo','neighborhood_boundaries','centroid_geom','geometry(Point,4326)'),
    ('geo','points_of_interest','location_geom','geometry(Point,4326)'),
    ('geo','road_segments','segment_geom','geometry(LineString,4326)')
) AS v(s, t, c, ty);

SELECT col_not_null(s, t, c, format('%s.%s.%s is NOT NULL', s, t, c))
FROM (VALUES
    ('geo','neighborhood_boundaries','boundary_geom'),
    ('geo','points_of_interest','location_geom'),
    ('geo','road_segments','segment_geom'),
    ('civics','citizens','email'),
    ('commerce','orders','merchant_id')
) AS v(s, t, c);

-- Mobility keeps raw lat/long numerics (no geometry column) with fixed precision.
SELECT col_type_is('mobility', 'sensor_readings', 'latitude',  'numeric(10,8)', 'sensor_readings.latitude is numeric(10,8)');
SELECT col_type_is('mobility', 'sensor_readings', 'longitude', 'numeric(11,8)', 'sensor_readings.longitude is numeric(11,8)');
SELECT hasnt_column('civics', 'citizens', 'latitude', 'citizens has no latitude column (use home_geom)');

-- Full-text columns
SELECT col_type_is('documents', 'complaint_records', 'search_vector', 'tsvector', 'complaint_records.search_vector is tsvector');
SELECT col_type_is('documents', 'policy_documents',  'search_vector', 'tsvector', 'policy_documents.search_vector is tsvector');
SELECT col_type_is('documents', 'policy_documents',  'document_content', 'jsonb', 'policy_documents.document_content is jsonb');

-- -----------------------------------------------------------------------------
-- 9. Check and exclusion constraints are declared (and validated)
--    (data_integrity_checks.sql proves that each one actually rejects bad rows)
-- -----------------------------------------------------------------------------
SELECT is(
    (SELECT count(*)::int FROM pg_constraint
     WHERE contype = 'c' AND convalidated
       AND connamespace::regnamespace::text IN ('civics','commerce','mobility','geo','documents')
       AND conname LIKE 'chk\_%'),
    33, '33 validated chk_* CHECK constraints on the base tables');

SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'excl_permit_overlap' AND contype = 'x'
                  AND conrelid = 'civics.permit_applications'::regclass),
          'permit_applications has the excl_permit_overlap exclusion constraint');
SELECT ok(EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'excl_license_overlap' AND contype = 'x'
                  AND conrelid = 'commerce.business_licenses'::regclass),
          'business_licenses has the excl_license_overlap exclusion constraint');

-- -----------------------------------------------------------------------------
-- 10. Triggers that maintain derived columns
-- -----------------------------------------------------------------------------
SELECT trigger_is(s, t, trg, fs, fn, format('%s.%s trigger %s calls %s.%s()', s, t, trg, fs, fn))
FROM (VALUES
    ('commerce','order_items','trg_order_items_totals_ins','commerce','update_order_totals'),
    ('commerce','order_items','trg_order_items_totals_upd','commerce','update_order_totals'),
    ('commerce','order_items','trg_order_items_totals_del','commerce','update_order_totals'),
    ('documents','complaint_records','trg_complaint_search_vector','documents','update_complaint_search_vector'),
    ('documents','policy_documents','trg_policy_search_vector','documents','update_policy_search_vector'),
    ('geo','neighborhood_boundaries','trg_neighborhood_metrics','geo','calculate_neighborhood_metrics'),
    ('geo','road_segments','trg_road_metrics','geo','calculate_road_metrics')
) AS v(s, t, trg, fs, fn);

-- Order totals are maintained by STATEMENT-level triggers (transition tables),
-- so a multi-row INSERT recomputes each touched order once, not once per row.
SELECT is(
    (SELECT string_agg(t.tgname, ',' ORDER BY t.tgname) FROM pg_trigger t
     WHERE t.tgrelid = 'commerce.order_items'::regclass AND NOT t.tgisinternal
       AND (t.tgtype & 1) = 0),            -- bit 0 clear => FOR EACH STATEMENT
    'trg_order_items_totals_del,trg_order_items_totals_ins,trg_order_items_totals_upd',
    'order_items totals triggers are statement-level (one per INSERT/UPDATE/DELETE)');
SELECT hasnt_trigger('commerce', 'order_items', 'trg_order_items_totals',
                     'the old row-level trg_order_items_totals is gone');

-- -----------------------------------------------------------------------------
-- 11. Helper functions the modules call
-- -----------------------------------------------------------------------------
SELECT has_function('meta', 'as_of', 'function meta.as_of() exists');
SELECT has_function('meta', 'fingerprint', 'function meta.fingerprint() exists');
SELECT function_returns('meta', 'as_of', 'timestamp with time zone', 'meta.as_of() returns timestamptz');
SELECT volatility_is('meta', 'as_of', 'stable', 'meta.as_of() is STABLE (safe in index-able predicates)');
SELECT has_function('synth', 'u', ARRAY['bigint','integer'], 'function synth.u(bigint, integer) exists');
SELECT has_function('synth', 'z', ARRAY['bigint','integer'], 'function synth.z(bigint, integer) exists');
SELECT has_function('geo', 'find_nearby_pois', ARRAY['numeric','numeric','integer','geo.poi_category'],
                    'function geo.find_nearby_pois(lat, lng, radius_m, category) exists');
SELECT has_function('geo', 'point_to_neighborhood', ARRAY['numeric','numeric'],
                    'function geo.point_to_neighborhood(lat, lng) exists');
SELECT has_function('commerce', 'recompute_order_totals', ARRAY['bigint[]'],
                    'function commerce.recompute_order_totals(bigint[]) exists');
SELECT has_function('documents', 'search_complaints', ARRAY['text','integer'],
                    'function documents.search_complaints(text, integer) exists');

SELECT * FROM finish();
ROLLBACK;
