-- File: sql/15_testing_quality/pgtap_unit_tests.sql
-- Purpose: a real pgTAP unit-test suite for the Polaris schema, its constraints, its
--          functions and the invariants of the frozen synthetic dataset.
--
-- What this module teaches
--   * The pgTAP pattern:  BEGIN; SELECT plan(n); <tests>; SELECT * FROM finish(); ROLLBACK;
--     Everything happens inside one transaction that is rolled back, so tests may insert,
--     update and break things freely and leave the database untouched.
--   * Four layers of database tests:
--       1. schema tests      has_table, col_type_is, col_not_null, fk_ok, has_index ...
--       2. constraint tests  throws_ok(sql, SQLSTATE) proves bad data is REJECTED;
--                            lives_ok proves good data is accepted
--       3. function tests    behaviour of geo.find_nearby_pois, meta.as_of() and a trigger
--       4. data invariants   is / results_eq / set_eq on facts the dataset guarantees
--   * plan(n) is a contract: if a test is added or silently skipped, finish() prints
--     "# Looks like you planned n tests but ran m" and pg_prove marks the file as failed.
--   * finish(true) additionally RAISES if any test failed, so a failing suite also stops
--     `psql -v ON_ERROR_STOP=1` (a plan mismatch alone does not raise; pg_prove catches it).
--
-- How to run
--   psql:      psql -X -v ON_ERROR_STOP=1 -d <db> -f sql/15_testing_quality/pgtap_unit_tests.sql
--   pg_prove:  pg_prove -d <db> sql/15_testing_quality/pgtap_unit_tests.sql   (TAP harness, summarises)
-- Requires the pgtap extension (installed in the Polaris image).

CREATE EXTENSION IF NOT EXISTS pgtap;

-- TAP output is easiest to read without psql's table decoration.
\pset format unaligned
\pset tuples_only on
\pset pager off

BEGIN;

SELECT plan(85);

-- =============================================================================
-- 1. SCHEMA TESTS: the structure the curriculum relies on
-- =============================================================================

-- 1a. Schemas and core tables exist
-- schemas_are() would demand an EXACT list and break as soon as a module adds a schema;
-- has_schema() is the right tool for open-ended checks.
SELECT has_schema('civics');
SELECT has_schema('commerce');
SELECT has_schema('mobility');
SELECT has_schema('geo');
SELECT has_schema('documents');
SELECT has_schema('meta');

SELECT has_table('civics',   'citizens',                'civics.citizens exists');
SELECT has_table('civics',   'permit_applications',     'civics.permit_applications exists');
SELECT has_table('commerce', 'merchants',               'commerce.merchants exists');
SELECT has_table('commerce', 'orders',                  'commerce.orders exists');
SELECT has_table('commerce', 'order_items',             'commerce.order_items exists');
SELECT has_table('commerce', 'payments',                'commerce.payments exists');
SELECT has_table('mobility', 'sensor_readings',         'mobility.sensor_readings exists');
SELECT has_table('geo',      'points_of_interest',      'geo.points_of_interest exists');
SELECT has_table('geo',      'neighborhood_boundaries', 'geo.neighborhood_boundaries exists');
SELECT has_table('meta',     'ground_truth',            'meta.ground_truth exists');
SELECT hasnt_table('geo',    'neighborhoods',           'there is no geo.neighborhoods (use neighborhood_boundaries)');

-- 1b. Primary keys and column types (types are compared with format_type(), so
--     typmods such as numeric(12,2) and geometry(Point,4326) must match exactly)
SELECT has_pk('civics',   'citizens', 'citizens has a primary key');
SELECT has_pk('commerce', 'orders',   'orders has a primary key');
SELECT col_type_is('civics',   'citizens', 'home_geom',      'geometry(Point,4326)',     'citizens.home_geom is a 4326 point');
SELECT hasnt_column('civics',  'citizens', 'latitude',       'citizens has no latitude column (location lives in home_geom)');
SELECT col_type_is('commerce', 'orders',   'total_amount',   'numeric(12,2)',            'orders.total_amount is numeric(12,2)');
SELECT col_type_is('commerce', 'orders',   'order_date',     'timestamp with time zone', 'orders.order_date is timestamptz');
SELECT col_type_is('geo', 'neighborhood_boundaries', 'boundary_geom', 'geometry(Polygon,4326)', 'boundaries are 4326 polygons');
SELECT col_not_null('civics',   'citizens', 'email',       'citizens.email is NOT NULL');
SELECT col_not_null('commerce', 'orders',   'merchant_id', 'orders.merchant_id is NOT NULL');
SELECT col_is_unique('commerce', 'orders',  'order_number', 'order_number is unique');
SELECT enum_has_labels('documents', 'document_status',
    ARRAY['draft', 'submitted', 'under_review', 'approved', 'resolved',
          'published', 'archived', 'rejected', 'expired'],
    'documents.document_status has the documented labels in order');

-- 1c. Foreign keys: fk_ok(fk_schema, fk_table, fk_column, pk_schema, pk_table, pk_column)
SELECT fk_ok('commerce', 'orders',      'merchant_id',         'commerce', 'merchants', 'merchant_id');
SELECT fk_ok('commerce', 'orders',      'customer_citizen_id', 'civics',   'citizens',  'citizen_id');
SELECT fk_ok('commerce', 'order_items', 'order_id',            'commerce', 'orders',    'order_id');
SELECT fk_ok('commerce', 'payments',    'order_id',            'commerce', 'orders',    'order_id');
SELECT fk_ok('civics', 'permit_applications', 'citizen_id',    'civics',   'citizens',  'citizen_id');

-- 1d. Indexes the lessons depend on, including the access method
SELECT has_index('commerce', 'orders', 'idx_orders_date', ARRAY['order_date'], 'orders has a btree on order_date');
SELECT has_index('commerce', 'orders', 'idx_orders_merchant', 'orders has an index on merchant_id');
SELECT has_index('geo', 'points_of_interest', 'idx_pois_geom', 'POIs have a spatial index');
SELECT index_is_type('geo', 'points_of_interest', 'idx_pois_geom', 'gist', 'the POI spatial index is GiST');
SELECT has_index('mobility', 'sensor_readings', 'idx_sensors_code_time',
                 ARRAY['sensor_code', 'reading_time'], 'sensor readings indexed by (sensor_code, reading_time)');

-- =============================================================================
-- 2. CONSTRAINT TESTS: invalid data must be rejected with the right SQLSTATE
-- =============================================================================
-- throws_ok runs the statement in a savepoint, so a failure does not abort the suite.
-- SQLSTATEs: 23502 not_null, 23503 foreign_key, 23505 unique, 23514 check, 23P01 exclusion.

-- A known-good fixture, created inside the rolled-back transaction.
SELECT lives_ok($$
    INSERT INTO civics.citizens (citizen_id, first_name, last_name, date_of_birth, email, street_address, zip_code)
    VALUES (-1, 'Tap', 'Tester', '1990-01-01', 'tap.tester@example.org', '1 Test Way', '75101')
$$, 'a valid citizen can be inserted');

SELECT throws_ok($$
    INSERT INTO civics.citizens (first_name, last_name, date_of_birth, email, street_address, zip_code)
    VALUES ('Bad', 'Email', '1990-01-01', 'not-an-email', '1 Test Way', '75101')
$$, '23514', NULL, 'chk_citizens_email rejects a malformed email');

SELECT throws_ok($$
    INSERT INTO civics.citizens (first_name, last_name, date_of_birth, email, street_address, zip_code)
    VALUES ('Future', 'Born', (CURRENT_DATE + 1), 'future@example.org', '1 Test Way', '75101')
$$, '23514', NULL, 'chk_citizens_age rejects a birth date in the future');

SELECT throws_ok($$
    INSERT INTO civics.citizens (first_name, last_name, date_of_birth, email, street_address, zip_code)
    VALUES ('Dup', 'Email', '1990-01-01', 'tap.tester@example.org', '2 Test Way', '75101')
$$, '23505', NULL, 'duplicate email violates the unique constraint');

SELECT throws_ok($$
    INSERT INTO civics.citizens (first_name, last_name, date_of_birth, street_address, zip_code)
    VALUES ('No', 'Email', '1990-01-01', '1 Test Way', '75101')
$$, '23502', NULL, 'email is required');

SELECT throws_ok($$
    INSERT INTO commerce.orders (merchant_id, customer_citizen_id, order_number)
    VALUES (987654321, -1, 'TAP-ORPHAN')
$$, '23503', NULL, 'an order for an unknown merchant violates the FK');

SELECT throws_ok($$
    INSERT INTO commerce.orders (merchant_id, order_number, subtotal, tax_amount, tip_amount, total_amount)
    VALUES (1, 'TAP-BADTOTAL', 10.00, 0.83, 0.00, 99.99)
$$, '23514', NULL, 'chk_order_total: total must equal subtotal + tax + tip');

SELECT throws_ok($$
    INSERT INTO commerce.orders (merchant_id, order_number, subtotal, total_amount)
    VALUES (1, 'TAP-NEG', -5, -5)
$$, '23514', NULL, 'chk_order_amounts rejects negative amounts');

SELECT throws_ok(
    format($$INSERT INTO commerce.orders (merchant_id, order_number) VALUES (1, %L)$$,
           (SELECT order_number FROM commerce.orders ORDER BY order_id LIMIT 1)),
    '23505', NULL, 'order_number must be unique');

SELECT throws_ok($$
    INSERT INTO commerce.order_items (order_id, item_name, unit_price, quantity, line_total)
    VALUES (1, 'Zero qty', 5.00, 0, 0.00)
$$, '23514', NULL, 'chk_item_pricing rejects quantity 0');

SELECT throws_ok($$
    INSERT INTO civics.permit_applications (citizen_id, permit_type, permit_number, description, fee_amount, fee_paid)
    VALUES (-1, 'building', 'TAP-FEE', 'overpaid', 100, 150)
$$, '23514', NULL, 'chk_permit_fees: fee_paid cannot exceed fee_amount');

-- Exclusion constraint: two approved permits of the same type on the same parcel with
-- overlapping validity periods are rejected (23P01), adjacent periods are fine.
SELECT lives_ok($$
    INSERT INTO civics.permit_applications
        (citizen_id, permit_type, permit_number, description, parcel_id, status,
         application_date, approval_date, expiration_date)
    VALUES (-1, 'event', 'TAP-EX-1', 'first', 'TAP-PARCEL', 'approved',
            '2025-03-01', '2025-03-02', '2025-06-01')
$$, 'first approved permit on a parcel is accepted');

SELECT throws_ok($$
    INSERT INTO civics.permit_applications
        (citizen_id, permit_type, permit_number, description, parcel_id, status,
         application_date, approval_date, expiration_date)
    VALUES (-1, 'event', 'TAP-EX-2', 'overlapping', 'TAP-PARCEL', 'approved',
            '2025-04-01', '2025-04-02', '2025-08-01')
$$, '23P01', NULL, 'excl_permit_overlap rejects an overlapping approved permit');

SELECT lives_ok($$
    INSERT INTO civics.permit_applications
        (citizen_id, permit_type, permit_number, description, parcel_id, status,
         application_date, approval_date, expiration_date)
    VALUES (-1, 'event', 'TAP-EX-3', 'adjacent', 'TAP-PARCEL', 'approved',
            '2025-05-30', '2025-06-01', '2025-09-01')
$$, 'a permit starting exactly when the previous one expires is accepted ([) ranges)');

-- DEFERRABLE foreign key: orders.customer_citizen_id is checked at COMMIT when deferred,
-- which lets a loader insert children before parents. Here the parent never arrives, so
-- switching back to IMMEDIATE fires the pending check. Both statements run in one
-- throws_ok so the deferred event and the error live in the same savepoint.
SELECT throws_ok($$
    SET CONSTRAINTS commerce.orders_customer_citizen_id_fkey DEFERRED;
    INSERT INTO commerce.orders (merchant_id, customer_citizen_id, order_number)
    VALUES (1, 987654321, 'TAP-DEFERRED');
    SET CONSTRAINTS commerce.orders_customer_citizen_id_fkey IMMEDIATE;
$$, '23503', NULL, 'a deferred FK violation surfaces when the constraint becomes IMMEDIATE');

-- =============================================================================
-- 3. FUNCTION TESTS
-- =============================================================================

-- 3a. meta.as_of(): the dataset clock
SELECT has_function('meta', 'as_of', ARRAY[]::name[], 'meta.as_of() exists');
SELECT volatility_is('meta', 'as_of', ARRAY[]::name[], 'stable', 'meta.as_of() is STABLE (not IMMUTABLE: it reads a table)');
SELECT is(meta.as_of(), '2025-12-31 23:59:59+00'::timestamptz, 'meta.as_of() is the end of 2025 UTC');
SELECT cmp_ok(meta.as_of(), '<', now(), 'the dataset clock is in the past relative to the wall clock');

-- 3b. geo.find_nearby_pois(lat, lng, radius_m, category)
SELECT has_function('geo', 'find_nearby_pois',
                    ARRAY['numeric', 'numeric', 'integer', 'geo.poi_category'],
                    'geo.find_nearby_pois(numeric, numeric, integer, poi_category) exists');
SELECT volatility_is('geo', 'find_nearby_pois',
                     ARRAY['numeric', 'numeric', 'integer', 'geo.poi_category'], 'stable',
                     'find_nearby_pois is STABLE (inlinable, usable in index conditions)');

-- Searching at a POI's own location returns that POI first, at distance 0.
SELECT results_eq(
    $$SELECT f.poi_id, f.distance_meters
      FROM geo.points_of_interest p,
           geo.find_nearby_pois(ST_Y(p.location_geom)::numeric, ST_X(p.location_geom)::numeric, 50) f
      WHERE p.poi_id = (SELECT min(poi_id) FROM geo.points_of_interest WHERE is_active)
      LIMIT 1$$,
    $$SELECT min(poi_id), 0 FROM geo.points_of_interest WHERE is_active$$,
    'searching at a POI returns that POI first with distance 0');

-- Every result is within the radius, and results are ordered by distance.
SELECT is_empty($$
    SELECT 1 FROM geo.find_nearby_pois(32.99, -96.80, 1500) WHERE distance_meters > 1500
$$, 'no result lies outside the requested radius');

-- Ordering: the function sorts by `geography <-> geography`, which uses a SPHERE, while
-- distance_meters comes from ST_Distance on the SPHEROID. Neighbours a few metres apart
-- can therefore swap places. The honest test is "ordered within a small tolerance".
SELECT is_empty($$
    SELECT 1
    FROM (SELECT distance_meters AS d,
                 max(distance_meters) OVER (ORDER BY ord ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS worst_prev
          FROM geo.find_nearby_pois(32.99, -96.80, 1500)
               WITH ORDINALITY AS t(poi_id, name, category, distance_meters, street_address, ord)) s
    WHERE worst_prev - d > 10
$$, 'results come back nearest first (within 10 m sphere-vs-spheroid tolerance)');

-- The function agrees with a brute-force geodesic query (same ids, any order).
SELECT set_eq(
    $$SELECT poi_id FROM geo.find_nearby_pois(32.99, -96.80, 1500)$$,
    $$SELECT poi_id FROM geo.points_of_interest
      WHERE is_active
        AND ST_Distance(location_geom::geography, ST_SetSRID(ST_MakePoint(-96.80, 32.99), 4326)::geography) <= 1500$$,
    'find_nearby_pois matches a brute-force ST_Distance scan');

SELECT is_empty($$
    SELECT 1 FROM geo.find_nearby_pois(32.99, -96.80, 5000, 'park') WHERE category <> 'park'
$$, 'the category filter returns only that category');

SELECT is_empty($$
    SELECT 1 FROM geo.find_nearby_pois(32.99, -96.80, 5000) f
    JOIN geo.points_of_interest p USING (poi_id) WHERE NOT p.is_active
$$, 'inactive POIs are never returned');

-- 3c. The order-totals triggers on commerce.order_items. They are STATEMENT-level triggers
--     with transition tables (REFERENCING NEW/OLD TABLE), so a bulk insert recomputes each
--     affected order once, and subtotal / tax / total are set in ONE UPDATE so the
--     chk_order_total CHECK never sees an inconsistent intermediate row.
SELECT has_trigger('commerce', 'order_items', 'trg_order_items_totals_ins', 'order_items has the insert totals trigger');
SELECT has_trigger('commerce', 'order_items', 'trg_order_items_totals_del', 'order_items has the delete totals trigger');
SELECT trigger_is('commerce', 'order_items', 'trg_order_items_totals_ins', 'commerce', 'update_order_totals',
                  'the insert trigger calls commerce.update_order_totals()');

SELECT lives_ok($$
    INSERT INTO commerce.orders (order_id, merchant_id, customer_citizen_id, order_number)
    VALUES (-1, 1, -1, 'TAP-TRIGGER')
$$, 'an empty order (all amounts 0) can be inserted');

SELECT lives_ok($$
    INSERT INTO commerce.order_items (order_id, item_name, unit_price, quantity, line_total)
    VALUES (-1, 'Widget', 10.00, 2, 20.00), (-1, 'Gadget', 5.50, 1, 5.50)
$$, 'two line items can be added in one statement');

SELECT results_eq(
    $$SELECT subtotal, tax_amount, total_amount FROM commerce.orders WHERE order_id = -1$$,
    $$VALUES (25.50::numeric(12,2), 2.10::numeric(12,2), 27.60::numeric(12,2))$$,
    'after INSERT: subtotal 25.50, tax 2.10 (8.25%, rounded to cents), total 27.60');

SELECT lives_ok($$DELETE FROM commerce.order_items WHERE order_id = -1 AND item_name = 'Gadget'$$,
                'a line item can be removed');

SELECT results_eq(
    $$SELECT subtotal, tax_amount, total_amount FROM commerce.orders WHERE order_id = -1$$,
    $$VALUES (20.00::numeric(12,2), 1.65::numeric(12,2), 21.65::numeric(12,2))$$,
    'after DELETE: totals are recomputed to 20.00 / 1.65 / 21.65');

-- =============================================================================
-- 4. DATASET INVARIANTS (scale 1, seed 42)
-- =============================================================================
-- These pin down facts the lessons assume. If the generator changes, they fail loudly
-- instead of letting lessons silently return different numbers.

SELECT is((SELECT count(*) FROM civics.citizens WHERE citizen_id > 0), 10000::bigint, '10,000 citizens');
SELECT is((SELECT count(*) FROM commerce.merchants), 500::bigint, '500 merchants');
SELECT is((SELECT count(*) FROM commerce.orders WHERE order_id > 0), 50000::bigint, '50,000 orders');
SELECT is((SELECT count(*) FROM geo.neighborhood_boundaries), 24::bigint, '24 neighbourhoods');

-- The row counts recorded at generation time still match the tables (no drift).
-- Tables that THIS transaction wrote fixtures into are excluded.
SELECT set_eq(
    $$SELECT table_name, row_count FROM meta.fingerprint()
      WHERE table_name IN (SELECT jsonb_object_keys(row_counts) FROM meta.dataset WHERE dataset_id = 1)
        AND table_name <> ALL (ARRAY['civics.citizens', 'commerce.orders', 'commerce.order_items',
                                     'civics.permit_applications'])$$,
    $$SELECT key, value::bigint FROM meta.dataset, jsonb_each_text(row_counts)
      WHERE dataset_id = 1
        AND key <> ALL (ARRAY['civics.citizens', 'commerce.orders', 'commerce.order_items',
                              'civics.permit_applications'])$$,
    'meta.dataset.row_counts agrees with meta.fingerprint() for untouched tables');

SELECT is((SELECT max(order_date) <= meta.as_of() FROM commerce.orders WHERE order_id > 0), true,
          'no order is dated after meta.as_of()');
SELECT is((SELECT max(reading_time) <= meta.as_of() FROM mobility.sensor_readings), true,
          'no sensor reading is after meta.as_of()');

SELECT is_empty($$
    SELECT 1 FROM commerce.orders
    WHERE abs(total_amount - (subtotal + tax_amount + tip_amount)) >= 0.01
$$, 'every order total equals subtotal + tax + tip');

SELECT is_empty($$
    SELECT 1 FROM civics.citizens c
    WHERE c.citizen_id > 0
      AND NOT EXISTS (SELECT 1 FROM geo.neighborhood_boundaries nb
                      WHERE ST_Covers(nb.boundary_geom, c.home_geom)
                        AND nb.neighborhood_id = substr(c.zip_code, 4, 2)::int)
$$, 'every citizen lives inside the neighbourhood encoded by zip 751NN');

SELECT results_eq(
    $$SELECT label, count(*) FROM meta.ground_truth GROUP BY label ORDER BY label$$,
    $$VALUES ('dropout', 228::bigint), ('level_shift', 2038), ('order_amount_outlier', 103), ('spike', 386)$$,
    'ground-truth label counts');

SELECT is_empty($$
    SELECT 1 FROM meta.ground_truth g
    WHERE g.entity = 'commerce.orders'
      AND NOT EXISTS (SELECT 1 FROM commerce.orders o WHERE o.order_id = g.entity_id)
$$, 'every labelled order outlier refers to an existing order');

-- The planted outliers are visibly large: their median amount is >10x the overall median.
SELECT cmp_ok(
    (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY o.total_amount)
     FROM commerce.orders o JOIN meta.ground_truth g
       ON g.entity = 'commerce.orders' AND g.label = 'order_amount_outlier' AND g.entity_id = o.order_id)::numeric,
    '>',
    10 * (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY total_amount) FROM commerce.orders)::numeric,
    'labelled outliers have a median amount more than 10x the overall median');

SELECT * FROM finish(true);   -- true: raise an exception if any test failed

ROLLBACK;

\pset format aligned
\pset tuples_only off
