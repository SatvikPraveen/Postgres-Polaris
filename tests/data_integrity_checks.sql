-- Location: /tests/data_integrity_checks.sql
-- =============================================================================
-- pgTAP suite 2/3: CONSTRAINTS, DATA INVARIANTS AND REPRODUCIBILITY
-- =============================================================================
-- What it teaches / guards:
--   A. Every CHECK, EXCLUDE, FOREIGN KEY, UNIQUE and NOT NULL constraint on the
--      base tables really rejects bad data, with the right SQLSTATE and the
--      right constraint name (23514 check, 23P01 exclusion, 23503 FK,
--      23505 unique, 23502 not-null). A constraint that is dropped, renamed or
--      made NOT VALID-and-forgotten turns a test red.
--   B. Invariants of the generated dataset that no single constraint enforces:
--      no orphans, money adds up, nothing happens after meta.as_of(), every
--      complaint lies inside its neighbourhood, neighbourhoods tile the city
--      without overlap, population_estimate equals the citizens living there.
--   C. Reproducibility: scale 1 / seed 42 yields the documented row counts.
--
-- Technique: each "bad write" runs inside throws_ok(), which wraps it in a
-- subtransaction (savepoint) so the failure is caught and nothing persists.
-- The whole file runs in one transaction that is ROLLED BACK.
--
-- Run:   docker exec polaris-db pg_prove -U polaris -d <db> /tests/data_integrity_checks.sql
-- =============================================================================
\set ON_ERROR_STOP on
\set QUIET 1
\pset format unaligned
\pset tuples_only true
\pset pager off

BEGIN;
SELECT plan(113);

-- Helpers live in pg_temp, so they disappear with the session (and the ROLLBACK).
CREATE FUNCTION pg_temp.rejects_check(tbl text, con text, stmt text)
RETURNS text LANGUAGE sql AS $$
    SELECT throws_ok(stmt, '23514',
        format('new row for relation "%s" violates check constraint "%s"', tbl, con),
        format('CHECK %s rejects bad data', con));
$$;

CREATE FUNCTION pg_temp.rejects_fk(tbl text, con text, stmt text)
RETURNS text LANGUAGE sql AS $$
    SELECT throws_ok(stmt, '23503',
        format('insert or update on table "%s" violates foreign key constraint "%s"', tbl, con),
        format('FOREIGN KEY %s rejects a dangling reference', con));
$$;

-- Number of rows whose event timestamp lies after the dataset's "now".
CREATE FUNCTION pg_temp.after_as_of(tbl regclass, col text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
    EXECUTE format('SELECT count(*) FROM %s WHERE %I > meta.as_of()', tbl, col) INTO n;
    RETURN n;
END $$;

-- =============================================================================
-- A1. CHECK constraints (SQLSTATE 23514)
--     Each statement breaks exactly one rule on one existing row.
-- =============================================================================
-- civics.citizens  (note: chk_citizens_age uses CURRENT_DATE, so it is only
-- evaluated when a row is written, never re-checked as time passes)
SELECT pg_temp.rejects_check('citizens', 'chk_citizens_age',
    $$UPDATE civics.citizens SET date_of_birth = '1850-01-01' WHERE citizen_id = 1$$);
SELECT pg_temp.rejects_check('citizens', 'chk_citizens_email',
    $$UPDATE civics.citizens SET email = 'not-an-email' WHERE citizen_id = 1$$);
SELECT pg_temp.rejects_check('citizens', 'chk_citizens_zip',
    $$UPDATE civics.citizens SET zip_code = 'ABCDE' WHERE citizen_id = 1$$);

-- civics.permit_applications
SELECT pg_temp.rejects_check('permit_applications', 'chk_permit_dates',
    $$UPDATE civics.permit_applications SET approval_date = application_date - interval '1 day'
      WHERE permit_id = (SELECT min(permit_id) FROM civics.permit_applications)$$);
SELECT pg_temp.rejects_check('permit_applications', 'chk_permit_expiration',
    $$UPDATE civics.permit_applications SET expiration_date = COALESCE(approval_date, application_date)
      WHERE permit_id = (SELECT min(permit_id) FROM civics.permit_applications)$$);
SELECT pg_temp.rejects_check('permit_applications', 'chk_permit_fees',
    $$UPDATE civics.permit_applications SET fee_paid = fee_amount + 1
      WHERE permit_id = (SELECT min(permit_id) FROM civics.permit_applications)$$);

-- civics.tax_payments
SELECT pg_temp.rejects_check('tax_payments', 'chk_mill_rate',
    $$UPDATE civics.tax_payments SET mill_rate = 0 WHERE tax_id = (SELECT min(tax_id) FROM civics.tax_payments)$$);
SELECT pg_temp.rejects_check('tax_payments', 'chk_tax_amounts',
    $$UPDATE civics.tax_payments SET assessment_amount = -1 WHERE tax_id = (SELECT min(tax_id) FROM civics.tax_payments)$$);
SELECT pg_temp.rejects_check('tax_payments', 'chk_tax_payment_logic',
    $$UPDATE civics.tax_payments SET amount_paid = amount_due + 1 WHERE tax_id = (SELECT min(tax_id) FROM civics.tax_payments)$$);
SELECT pg_temp.rejects_check('tax_payments', 'chk_tax_year',
    $$UPDATE civics.tax_payments SET tax_year = 1900 WHERE tax_id = (SELECT min(tax_id) FROM civics.tax_payments)$$);

-- commerce.merchants
SELECT pg_temp.rejects_check('merchants', 'chk_merchants_employees',
    $$UPDATE commerce.merchants SET employee_count = -1 WHERE merchant_id = 1$$);
SELECT pg_temp.rejects_check('merchants', 'chk_merchants_revenue',
    $$UPDATE commerce.merchants SET annual_revenue = -1 WHERE merchant_id = 1$$);
SELECT pg_temp.rejects_check('merchants', 'chk_merchants_tax_id',
    $$UPDATE commerce.merchants SET tax_id = '123' WHERE merchant_id = 1$$);

-- commerce.orders
SELECT pg_temp.rejects_check('orders', 'chk_delivery_dates',
    $$UPDATE commerce.orders SET actual_delivery = order_date - interval '1 day' WHERE order_id = 1$$);
SELECT pg_temp.rejects_check('orders', 'chk_order_amounts',   -- total still adds up; only the tip is negative
    $$UPDATE commerce.orders SET tip_amount = -1, total_amount = subtotal + tax_amount - 1
      WHERE order_id = (SELECT min(order_id) FROM commerce.orders WHERE subtotal > 10)$$);
SELECT pg_temp.rejects_check('orders', 'chk_order_total',
    $$UPDATE commerce.orders SET total_amount = total_amount + 100 WHERE order_id = 1$$);

-- commerce.order_items
SELECT pg_temp.rejects_check('order_items', 'chk_item_line_total',
    $$UPDATE commerce.order_items SET line_total = line_total + 1 WHERE item_id = 1$$);
SELECT pg_temp.rejects_check('order_items', 'chk_item_pricing',
    $$UPDATE commerce.order_items SET quantity = 0, line_total = 0 WHERE item_id = 1$$);

-- commerce.payments
SELECT pg_temp.rejects_check('payments', 'chk_payment_amount',
    $$UPDATE commerce.payments SET amount = 0 WHERE payment_id = 1$$);
SELECT pg_temp.rejects_check('payments', 'chk_payment_processing',
    $$UPDATE commerce.payments SET status = 'completed', processed_at = NULL WHERE payment_id = 1$$);

-- mobility
SELECT pg_temp.rejects_check('stations', 'chk_station_capacity',
    $$UPDATE mobility.stations SET total_capacity = -1 WHERE station_id = 1$$);
SELECT pg_temp.rejects_check('stations', 'chk_station_coordinates',
    $$UPDATE mobility.stations SET latitude = 91 WHERE station_id = 1$$);
SELECT pg_temp.rejects_check('station_inventory', 'chk_inventory_counts',
    $$UPDATE mobility.station_inventory SET available_count = -1 WHERE inventory_id = 1$$);
SELECT pg_temp.rejects_check('trip_segments', 'chk_trip_coordinates',
    $$UPDATE mobility.trip_segments SET start_latitude = 91 WHERE trip_segment_id = 1$$);
SELECT pg_temp.rejects_check('trip_segments', 'chk_trip_metrics',
    $$UPDATE mobility.trip_segments SET comfort_rating = 6 WHERE trip_segment_id = 1$$);
SELECT pg_temp.rejects_check('trip_segments', 'chk_trip_times',
    $$UPDATE mobility.trip_segments SET end_time = start_time - interval '1 hour' WHERE trip_segment_id = 1$$);
SELECT pg_temp.rejects_check('sensor_readings', 'chk_sensor_coordinates',
    $$UPDATE mobility.sensor_readings SET longitude = 181 WHERE reading_id = 1$$);
SELECT pg_temp.rejects_check('sensor_readings', 'chk_sensor_quality',
    $$UPDATE mobility.sensor_readings SET data_quality_score = 1.5 WHERE reading_id = 1$$);

-- geo
SELECT pg_temp.rejects_check('road_segments', 'chk_road_attributes',
    $$UPDATE geo.road_segments SET speed_limit = 0 WHERE segment_id = 1$$);
SELECT pg_temp.rejects_check('points_of_interest', 'chk_poi_rating',
    $$UPDATE geo.points_of_interest SET average_rating = 5.5 WHERE poi_id = 1$$);
SELECT pg_temp.rejects_check('points_of_interest', 'chk_poi_reviews',
    $$UPDATE geo.points_of_interest SET review_count = -1 WHERE poi_id = 1$$);

-- documents
SELECT pg_temp.rejects_check('complaint_records', 'chk_complaint_coordinates',
    $$UPDATE documents.complaint_records SET incident_latitude = 91 WHERE complaint_id = 1$$);
SELECT pg_temp.rejects_check('complaint_records', 'chk_complaint_dates',
    $$UPDATE documents.complaint_records SET acknowledged_at = submitted_at - interval '1 day' WHERE complaint_id = 1$$);

-- =============================================================================
-- A2. EXCLUSION constraints (SQLSTATE 23P01)
--     A copy of an existing approved permit / active licence overlaps itself in
--     time on the same parcel / merchant. Explicit negative ids avoid touching
--     the sequences.
-- =============================================================================
SELECT throws_ok(
    $$INSERT INTO civics.permit_applications
        (permit_id, citizen_id, permit_type, permit_number, description, parcel_id, status,
         application_date, approval_date, expiration_date, fee_amount, fee_paid)
      SELECT -1, citizen_id, permit_type, 'TEST-OVERLAP-1', description, parcel_id, status,
             application_date, approval_date, expiration_date, fee_amount, fee_paid
      FROM civics.permit_applications
      WHERE permit_id = (SELECT min(permit_id) FROM civics.permit_applications
                         WHERE status = 'approved' AND parcel_id IS NOT NULL)$$,
    '23P01', 'conflicting key value violates exclusion constraint "excl_permit_overlap"',
    'EXCLUDE excl_permit_overlap rejects an overlapping approved permit on the same parcel');

-- The constraint is partial (WHERE status IN (approved, pending)): a denied copy is fine.
SELECT lives_ok(
    $$INSERT INTO civics.permit_applications
        (permit_id, citizen_id, permit_type, permit_number, description, parcel_id, status,
         application_date, approval_date, expiration_date, fee_amount, fee_paid)
      SELECT -2, citizen_id, permit_type, 'TEST-OVERLAP-2', description, parcel_id, 'denied',
             application_date, approval_date, expiration_date, fee_amount, fee_paid
      FROM civics.permit_applications
      WHERE permit_id = (SELECT min(permit_id) FROM civics.permit_applications
                         WHERE status = 'approved' AND parcel_id IS NOT NULL)$$,
    'excl_permit_overlap ignores denied permits (partial exclusion constraint)');
DELETE FROM civics.permit_applications WHERE permit_id = -2;   -- keep the row counts below exact

SELECT throws_ok(
    $$INSERT INTO commerce.business_licenses
        (license_id, merchant_id, license_type, license_number, status, application_date,
         issue_date, expiration_date, license_fee, fee_paid)
      SELECT -1, merchant_id, license_type, 'TEST-LIC-1', status, application_date,
             issue_date, expiration_date, license_fee, fee_paid
      FROM commerce.business_licenses
      WHERE license_id = (SELECT min(license_id) FROM commerce.business_licenses WHERE status = 'active')$$,
    '23P01', 'conflicting key value violates exclusion constraint "excl_license_overlap"',
    'EXCLUDE excl_license_overlap rejects two overlapping active licences of one type');

-- =============================================================================
-- A3. FOREIGN KEYS (SQLSTATE 23503)
-- =============================================================================
SELECT pg_temp.rejects_fk('orders', 'orders_merchant_id_fkey',
    $$UPDATE commerce.orders SET merchant_id = -1 WHERE order_id = 1$$);
SELECT pg_temp.rejects_fk('orders', 'orders_customer_citizen_id_fkey',
    $$UPDATE commerce.orders SET customer_citizen_id = -1 WHERE order_id = 1$$);
SELECT pg_temp.rejects_fk('order_items', 'order_items_order_id_fkey',
    $$UPDATE commerce.order_items SET order_id = -1 WHERE item_id = 1$$);
SELECT pg_temp.rejects_fk('payments', 'payments_order_id_fkey',
    $$UPDATE commerce.payments SET order_id = -1 WHERE payment_id = 1$$);
SELECT pg_temp.rejects_fk('permit_applications', 'permit_applications_citizen_id_fkey',
    $$UPDATE civics.permit_applications SET citizen_id = -1
      WHERE permit_id = (SELECT min(permit_id) FROM civics.permit_applications)$$);
SELECT pg_temp.rejects_fk('station_inventory', 'station_inventory_station_id_fkey',
    $$UPDATE mobility.station_inventory SET station_id = -1 WHERE inventory_id = 1$$);
SELECT pg_temp.rejects_fk('trip_segments', 'trip_segments_start_station_id_fkey',
    $$UPDATE mobility.trip_segments SET start_station_id = -1 WHERE trip_segment_id = 1$$);
SELECT pg_temp.rejects_fk('complaint_records', 'complaint_records_neighborhood_id_fkey',
    $$UPDATE documents.complaint_records SET neighborhood_id = -1 WHERE complaint_id = 1$$);
SELECT pg_temp.rejects_fk('points_of_interest', 'points_of_interest_neighborhood_id_fkey',
    $$UPDATE geo.points_of_interest SET neighborhood_id = -1 WHERE poi_id = 1$$);
-- ...and from the parent side: a referenced row cannot be deleted (NO ACTION).
SELECT throws_ok(
    $$DELETE FROM commerce.orders WHERE order_id = (SELECT min(order_id) FROM commerce.payments)$$,
    '23503', NULL, 'an order that has payments cannot be deleted');
SELECT throws_ok(
    $$DELETE FROM geo.neighborhood_boundaries WHERE neighborhood_id = 1$$,
    '23503', NULL, 'a neighbourhood referenced by complaints/POIs/roads cannot be deleted');

-- =============================================================================
-- A4. UNIQUE (23505) and NOT NULL (23502)
-- =============================================================================
SELECT throws_ok(
    $$UPDATE civics.citizens SET email = (SELECT email FROM civics.citizens WHERE citizen_id = 2) WHERE citizen_id = 1$$,
    '23505', 'duplicate key value violates unique constraint "citizens_email_key"',
    'citizens.email is unique');
SELECT throws_ok(
    $$INSERT INTO documents.policy_documents (policy_id, policy_number, title, version, document_content, department)
      SELECT -1, policy_number, 'dup', version, '{}'::jsonb, department FROM documents.policy_documents
      WHERE policy_id = (SELECT min(policy_id) FROM documents.policy_documents)$$,
    '23505', 'duplicate key value violates unique constraint "uq_policy_number_version"',
    'policy (policy_number, version) is unique');
SELECT throws_ok(
    $$UPDATE civics.citizens SET email = NULL WHERE citizen_id = 1$$,
    '23502', 'null value in column "email" of relation "citizens" violates not-null constraint',
    'citizens.email is NOT NULL');
SELECT throws_ok(
    $$UPDATE geo.points_of_interest SET location_geom = NULL WHERE poi_id = 1$$,
    '23502', 'null value in column "location_geom" of relation "points_of_interest" violates not-null constraint',
    'points_of_interest.location_geom is NOT NULL');
-- The typmod on geometry columns is a constraint too: wrong SRID / wrong shape is rejected.
SELECT throws_like(
    $$UPDATE geo.points_of_interest SET location_geom = ST_SetSRID(ST_MakePoint(500000, 4000000), 3857) WHERE poi_id = 1$$,
    '%SRID%', 'geometry(Point,4326) rejects a 3857 point');
SELECT throws_like(
    $$UPDATE geo.points_of_interest SET location_geom = ST_GeomFromText('LINESTRING(0 0, 1 1)', 4326) WHERE poi_id = 1$$,
    '%LineString%', 'geometry(Point,4326) rejects a LineString');

-- =============================================================================
-- B1. Referential invariants: no orphans (a backstop if an FK is ever dropped)
-- =============================================================================
SELECT is((SELECT count(*) FROM commerce.orders o
           WHERE NOT EXISTS (SELECT 1 FROM commerce.merchants m WHERE m.merchant_id = o.merchant_id)),
          0::bigint, 'no order without a merchant');
SELECT is((SELECT count(*) FROM commerce.orders o
           WHERE o.customer_citizen_id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM civics.citizens c WHERE c.citizen_id = o.customer_citizen_id)),
          0::bigint, 'no order with an unknown customer');
SELECT is((SELECT count(*) FROM commerce.order_items i
           WHERE NOT EXISTS (SELECT 1 FROM commerce.orders o WHERE o.order_id = i.order_id)),
          0::bigint, 'no order item without an order');
SELECT is((SELECT count(*) FROM commerce.orders o
           WHERE NOT EXISTS (SELECT 1 FROM commerce.order_items i WHERE i.order_id = o.order_id)),
          0::bigint, 'every order has at least one item');
SELECT is((SELECT count(*) FROM commerce.payments p
           WHERE NOT EXISTS (SELECT 1 FROM commerce.orders o WHERE o.order_id = p.order_id)),
          0::bigint, 'no payment without an order');
SELECT is((SELECT count(*) FROM commerce.business_licenses l
           WHERE NOT EXISTS (SELECT 1 FROM commerce.merchants m WHERE m.merchant_id = l.merchant_id)),
          0::bigint, 'no licence without a merchant');
SELECT is((SELECT count(*) FROM (
              SELECT citizen_id FROM civics.permit_applications
              UNION ALL SELECT citizen_id FROM civics.tax_payments
              UNION ALL SELECT citizen_id FROM civics.voting_records) x
           WHERE NOT EXISTS (SELECT 1 FROM civics.citizens c WHERE c.citizen_id = x.citizen_id)),
          0::bigint, 'no permit / tax payment / vote without a citizen');
SELECT is((SELECT count(*) FROM mobility.station_inventory si
           WHERE NOT EXISTS (SELECT 1 FROM mobility.stations s WHERE s.station_id = si.station_id)),
          0::bigint, 'no inventory snapshot without a station');
SELECT is((SELECT count(*) FROM mobility.trip_segments t
           WHERE (t.start_station_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mobility.stations s WHERE s.station_id = t.start_station_id))
              OR (t.end_station_id   IS NOT NULL AND NOT EXISTS (SELECT 1 FROM mobility.stations s WHERE s.station_id = t.end_station_id))
              OR (t.user_id          IS NOT NULL AND NOT EXISTS (SELECT 1 FROM civics.citizens c WHERE c.citizen_id = t.user_id))),
          0::bigint, 'no trip segment with an unknown station or user');
SELECT is((SELECT count(*) FROM (
              SELECT neighborhood_id FROM documents.complaint_records
              UNION ALL SELECT neighborhood_id FROM geo.points_of_interest
              UNION ALL SELECT neighborhood_id FROM geo.road_segments) x
           WHERE x.neighborhood_id IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM geo.neighborhood_boundaries n WHERE n.neighborhood_id = x.neighborhood_id)),
          0::bigint, 'no complaint / POI / road in an unknown neighbourhood');
SELECT is((SELECT count(*) FROM meta.ground_truth g
           WHERE (g.entity = 'mobility.sensor_readings'
                  AND NOT EXISTS (SELECT 1 FROM mobility.sensor_readings r WHERE r.reading_id = g.entity_id))
              OR (g.entity = 'commerce.orders'
                  AND NOT EXISTS (SELECT 1 FROM commerce.orders o WHERE o.order_id = g.entity_id))),
          0::bigint, 'every meta.ground_truth label points at an existing row');

-- =============================================================================
-- B2. Money adds up
-- =============================================================================
SELECT is((SELECT count(*) FROM commerce.order_items WHERE line_total <> unit_price * quantity),
          0::bigint, 'order_items: line_total = unit_price * quantity (exactly)');
SELECT is((SELECT count(*) FROM commerce.orders WHERE total_amount <> subtotal + tax_amount + tip_amount),
          0::bigint, 'orders: total_amount = subtotal + tax_amount + tip_amount (exactly)');
SELECT is((SELECT count(*) FROM commerce.orders o
           JOIN (SELECT order_id, sum(line_total) AS s FROM commerce.order_items GROUP BY order_id) i USING (order_id)
           WHERE o.subtotal <> i.s),
          0::bigint, 'orders: subtotal = sum(order_items.line_total)');
SELECT is((SELECT count(*) FROM commerce.payments p JOIN commerce.orders o USING (order_id)
           WHERE p.status = 'completed' AND p.amount <> o.total_amount),
          0::bigint, 'completed payments charge exactly the order total');
SELECT is((SELECT count(*) FROM civics.tax_payments WHERE amount_paid > amount_due),
          0::bigint, 'no tax overpayment');

-- =============================================================================
-- B3. Time: nothing that has *happened* lies after meta.as_of()
--     (Future-dated-by-design columns such as expiration/due/review dates are
--      deliberately excluded.)
-- =============================================================================
SELECT is(pg_temp.after_as_of(t::regclass, c), 0::bigint, format('%s.%s <= meta.as_of()', t, c))
FROM (VALUES
    ('civics.citizens', 'registered_date'),
    ('civics.citizens', 'date_of_birth'),
    ('civics.permit_applications', 'application_date'),
    ('civics.voting_records', 'voted_at'),
    ('commerce.merchants', 'registration_date'),
    ('commerce.business_licenses', 'issue_date'),
    ('commerce.orders', 'order_date'),
    ('commerce.payments', 'payment_date'),
    ('commerce.payments', 'processed_at'),
    ('mobility.trip_segments', 'start_time'),
    ('mobility.sensor_readings', 'reading_time'),
    ('mobility.station_inventory', 'recorded_at'),
    ('documents.complaint_records', 'submitted_at'),
    ('documents.complaint_records', 'incident_date'),
    ('documents.complaint_records', 'resolved_at'),
    ('documents.policy_documents', 'effective_date')
) AS v(t, c);

-- =============================================================================
-- B4. Geography: points sit inside their polygons; polygons tile the city
-- =============================================================================
SELECT is((SELECT count(*) FROM documents.complaint_records
           WHERE incident_latitude IS NULL OR incident_longitude IS NULL OR neighborhood_id IS NULL),
          0::bigint, 'every complaint is geolocated and assigned to a neighbourhood');
SELECT is((SELECT count(*) FROM documents.complaint_records c
           JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
           WHERE NOT ST_Covers(n.boundary_geom,
                               ST_SetSRID(ST_MakePoint(c.incident_longitude, c.incident_latitude), 4326))),
          0::bigint, 'every complaint point lies inside its neighbourhood polygon');
SELECT is((SELECT count(*) FROM geo.points_of_interest p
           JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
           WHERE NOT ST_Covers(n.boundary_geom, p.location_geom)),
          0::bigint, 'every POI lies inside its neighbourhood polygon');
SELECT is((SELECT count(*) FROM civics.citizens c
           JOIN geo.neighborhood_boundaries n ON n.neighborhood_id = substr(c.zip_code, 4, 2)::int
           WHERE c.home_geom IS NULL OR NOT ST_Covers(n.boundary_geom, c.home_geom)),
          0::bigint, 'every citizen home lies in the neighbourhood its zip code (751NN) encodes');
SELECT is((SELECT count(*) FROM geo.neighborhood_boundaries WHERE NOT ST_IsValid(boundary_geom)),
          0::bigint, 'all neighbourhood polygons are valid');
SELECT is((SELECT count(*) FROM geo.neighborhood_boundaries a
           JOIN geo.neighborhood_boundaries b
             ON a.neighborhood_id < b.neighborhood_id AND a.boundary_geom && b.boundary_geom
           WHERE ST_Area(ST_Intersection(a.boundary_geom, b.boundary_geom)) > 0),
          0::bigint, 'no two neighbourhood polygons overlap (shared edges only)');
SELECT is((SELECT ST_GeometryType(u) || '/' || ST_NumInteriorRings(u)
           FROM (SELECT ST_Union(boundary_geom) AS u FROM geo.neighborhood_boundaries) s),
          'ST_Polygon/0', 'the neighbourhoods union to one polygon without holes (they tile the city)');
SELECT ok((SELECT abs(ST_Area(ST_Union(boundary_geom)) - sum(ST_Area(boundary_geom))) < 1e-9
           FROM geo.neighborhood_boundaries),
          'area of the union equals the sum of the parts (no gaps double-counted, no overlap)');
SELECT is((SELECT count(*) FROM geo.neighborhood_boundaries n
           WHERE n.population_estimate IS DISTINCT FROM
                 (SELECT count(*) FROM civics.citizens c WHERE ST_Covers(n.boundary_geom, c.home_geom))),
          0::bigint, 'population_estimate equals the number of citizens living inside each polygon');
SELECT is((SELECT sum(population_estimate)::bigint FROM geo.neighborhood_boundaries),
          (SELECT count(*) FROM civics.citizens), 'neighbourhood populations sum to the citizen count');
-- Derived columns maintained by trigger are consistent with the geometry (geodesic units).
SELECT is((SELECT count(*) FROM geo.neighborhood_boundaries
           WHERE abs(area_sq_km - ST_Area(boundary_geom::geography) / 1e6) > 0.001
              OR NOT ST_Equals(centroid_geom, ST_Centroid(boundary_geom))),
          0::bigint, 'area_sq_km / centroid_geom match the boundary (geography area)');
SELECT is((SELECT count(*) FROM geo.road_segments
           WHERE abs(length_km - ST_Length(segment_geom::geography) / 1000) > 0.001),
          0::bigint, 'road length_km matches the geodesic length of segment_geom');

-- =============================================================================
-- C. Reproducibility: scale 1, seed 42 => documented row counts
-- =============================================================================
SELECT is((SELECT count(*) FROM meta.dataset), 1::bigint, 'meta.dataset has exactly one row');
SELECT is((SELECT scale FROM meta.dataset), 1::numeric, 'dataset was generated at scale 1');
SELECT is((SELECT seed FROM meta.dataset), 42::bigint, 'dataset was generated with seed 42');
SELECT is(meta.as_of(), '2025-12-31 23:59:59+00'::timestamptz, 'meta.as_of() is 2025-12-31 23:59:59 UTC');
SELECT is((SELECT count(*) FROM meta.planted_effects), 10::bigint, '10 planted effects are documented');

CREATE TEMP TABLE fp ON COMMIT DROP AS SELECT * FROM meta.fingerprint();

SELECT is((SELECT row_count FROM fp WHERE table_name = t), n, format('%s has %s rows', t, n))
FROM (VALUES
    ('civics.citizens',             10000::bigint),
    ('commerce.merchants',            500::bigint),
    ('commerce.orders',             50000::bigint),
    ('documents.complaint_records',  5000::bigint),
    ('civics.permit_applications',   3000::bigint),
    ('geo.points_of_interest',        600::bigint),
    ('geo.road_segments',            1067::bigint),
    ('mobility.stations',             150::bigint),
    ('geo.neighborhood_boundaries',    24::bigint)
) AS v(t, n);

-- The counts recorded at generation time still match what is in the tables.
SELECT is((SELECT count(*) FROM fp
           JOIN jsonb_each_text((SELECT row_counts FROM meta.dataset)) rc ON rc.key = fp.table_name
           WHERE rc.value::bigint <> fp.row_count),
          0::bigint, 'meta.dataset.row_counts agrees with meta.fingerprint()');

-- =============================================================================
-- A5. ON DELETE CASCADE (runs last because it removes rows inside this
--     rolled-back transaction)
-- =============================================================================
DELETE FROM commerce.orders
WHERE order_id = (SELECT min(order_id) FROM commerce.orders o
                  WHERE NOT EXISTS (SELECT 1 FROM commerce.payments p WHERE p.order_id = o.order_id));
SELECT is((SELECT count(*) FROM commerce.order_items i
           WHERE NOT EXISTS (SELECT 1 FROM commerce.orders o WHERE o.order_id = i.order_id)),
          0::bigint, 'deleting an order cascades to its order_items');

SELECT * FROM finish();
ROLLBACK;
