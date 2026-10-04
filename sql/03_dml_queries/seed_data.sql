-- File: sql/03_dml_queries/seed_data.sql
-- Purpose: Deterministic, scalable synthetic city generator ("Polaris City").
--
-- Usage (psql variables, both optional):
--   psql -v scale=1 -v seed=42 -f seed_data.sql
--
-- Design
--   * Counter-based RNG. Every random draw is synth.u(entity_key, stream):
--     a 53-bit uniform derived from hashint8extended(key, seed:stream).
--     Output is identical regardless of plan shape, parallelism or row
--     order, which plain random()/setseed() cannot guarantee.
--   * Fixed reference instant. All timestamps are generated relative to
--     meta.as_of() (2025-12-31 23:59:59 UTC), never now(), so every query
--     in the curriculum returns the same answer on every machine.
--   * Planted effects with known parameters (meta.planted_effects) and
--     labelled anomalies (meta.ground_truth) make analytical modules
--     verifiable: an estimator either recovers the planted value or not.
--   * Linear scale factor. Row counts for people/transactions scale with
--     :scale; geography (neighbourhoods, roads, stations) does not.
--
-- Row counts at scale = 1, seed = 42 (~420k rows, ~12 s on a laptop)
--   citizens 10,000   merchants 500      orders 50,000   order items 112k
--   payments 48.7k    trip segments 51.9k sensor readings 103k
--   tax payments 25.8k votes 11.3k      permits 3,000   complaints 5,000
--   POIs 600          road segments 1,067 stations 150   neighbourhoods 24

\set ON_ERROR_STOP on
\if :{?scale}
\else
    \set scale 1
\endif
\if :{?seed}
\else
    \set seed 42
\endif

SET client_min_messages = warning;
SET max_parallel_workers_per_gather = 0;   -- not needed for determinism, keeps load cheap
SET synchronous_commit = off;

-- ===========================================================================
-- 0. Generator utilities and provenance
-- ===========================================================================

DROP SCHEMA IF EXISTS synth CASCADE;
CREATE SCHEMA synth;
COMMENT ON SCHEMA synth IS 'Deterministic random-variate helpers used by the synthetic data generator';

CREATE SCHEMA IF NOT EXISTS meta;
COMMENT ON SCHEMA meta IS 'Dataset provenance, planted effects and ground-truth labels';

SELECT set_config('polaris.seed',  :'seed',  false) AS _seed \gset
SELECT set_config('polaris.scale', :'scale', false) AS _scale \gset

-- Uniform [0,1) from (key, stream). 53 bits of a 64-bit hash.
CREATE FUNCTION synth.u(k bigint, stream int)
RETURNS float8 LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT ((hashint8extended(k, current_setting('polaris.seed')::bigint * 1000003 + stream) >> 11)
            & 9007199254740991)::float8 / 9007199254740992.0
$$;

-- Standard normal via Box-Muller on two independent streams.
CREATE FUNCTION synth.z(k bigint, stream int)
RETURNS float8 LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT sqrt(-2.0 * ln(1.0 - synth.u(k, stream)))
         * cos(2.0 * pi() * synth.u(k, stream + 50000))
$$;

-- Exponential with given mean.
CREATE FUNCTION synth.exp(k bigint, stream int, mean float8)
RETURNS float8 LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT -mean * ln(1.0 - synth.u(k, stream))
$$;

-- Bounded power-law (Zipf-like) rank in 1..n with exponent s (s <> 1),
-- by inverting the continuous CDF.
CREATE FUNCTION synth.zipf(k bigint, stream int, n int, s float8)
RETURNS int LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT least(n, greatest(1, floor(
        power((power(n + 1.0, 1.0 - s) - 1.0) * synth.u(k, stream) + 1.0, 1.0 / (1.0 - s))
    )::int))
$$;

-- Weighted categorical choice: returns items[i] where cumulative weight
-- first exceeds u * total.
CREATE FUNCTION synth.pick(items text[], weights float8[], u float8)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT items[i]
    FROM (
        SELECT i, sum(weights[i]) OVER (ORDER BY i) AS c,
               sum(weights[i]) OVER () AS t
        FROM generate_subscripts(weights, 1) AS i
    ) s
    WHERE c > u * t
    ORDER BY i
    LIMIT 1
$$;

CREATE FUNCTION synth.sigmoid(x float8)
RETURNS float8 LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$ SELECT 1.0 / (1.0 + exp(-x)) $$;

-- Provenance -----------------------------------------------------------------
DROP TABLE IF EXISTS meta.dataset, meta.planted_effects, meta.ground_truth CASCADE;

CREATE TABLE meta.dataset (
    dataset_id        int PRIMARY KEY DEFAULT 1 CHECK (dataset_id = 1),
    generator_version text        NOT NULL,
    scale             numeric     NOT NULL,
    seed              bigint      NOT NULL,
    as_of             timestamptz NOT NULL,
    server_version    text        NOT NULL,
    generated_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    generation_ms     numeric,
    row_counts        jsonb
);
COMMENT ON TABLE meta.dataset IS
'One row describing how the current dataset was produced. Cite scale, seed and generator_version when reporting results.';

INSERT INTO meta.dataset (generator_version, scale, seed, as_of, server_version)
VALUES ('2.1.0', :'scale', :'seed', '2025-12-31 23:59:59+00', current_setting('server_version'));

CREATE OR REPLACE FUNCTION meta.as_of()
RETURNS timestamptz LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT as_of FROM meta.dataset WHERE dataset_id = 1
$$;
COMMENT ON FUNCTION meta.as_of() IS
'Reference "now" of the synthetic dataset. Use instead of now()/CURRENT_DATE for reproducible results.';

CREATE TABLE meta.planted_effects (
    effect      text PRIMARY KEY,
    domain      text    NOT NULL,
    parameter   text    NOT NULL,
    true_value  numeric NOT NULL,
    description text    NOT NULL
);
COMMENT ON TABLE meta.planted_effects IS
'Known generative parameters. Analyses can be validated by recovering these values.';

INSERT INTO meta.planted_effects VALUES
 ('complaint_resolution_income_gradient', 'documents', 'log-multiplier per SD of neighbourhood income', -0.25,
  'Resolution time = lognormal(base_by_category) * exp(-0.25 * income_z): lower-income neighbourhoods wait longer.'),
 ('turnout_age_slope', 'civics', 'logit change per year of age', 0.035,
  'P(vote) = sigmoid(-0.6 + 0.035*(age-45) + 0.40*income_z + election_effect).'),
 ('turnout_income_slope', 'civics', 'logit change per SD of neighbourhood income', 0.40,
  'See turnout_age_slope.'),
 ('peak_hour_bus_delay_ratio', 'mobility', 'mean delay at peak / mean delay off-peak (bus, rail)', 3.0,
  'Transit delay ~ Exponential(mean = 2 min off-peak, 6 min in 07-09 and 16-19 weekday peaks).'),
 ('peak_hour_road_speed_factor', 'mobility', 'speed multiplier at weekday peak (car, bus, rideshare)', 0.70,
  'Road modes travel 30% slower during weekday peaks.'),
 ('merchant_popularity_zipf_exponent', 'commerce', 'Zipf exponent of orders per merchant', 1.10,
  'Order-to-merchant assignment follows a bounded power law; merchant rank is a fixed permutation of merchant_id.'),
 ('order_growth_exponent', 'commerce', 'week index = 52 * u^0.85', 0.85,
  'Order volume grows over the year: density of week w is proportional to w^(1/0.85 - 1).'),
 ('sensor_point_anomaly_rate', 'mobility', 'share of readings that are point anomalies (spike + dropout)', 0.006,
  'Spikes (p=0.004) and dropouts to 0 with quality 0.25 (p=0.002); labelled in meta.ground_truth.'),
 ('sensor_level_shift_windows', 'mobility', 'level-shift windows per sensor (6-24 h, value x1.4)', 3,
  'Contextual anomalies: about 2% of readings fall inside a window; every reading inside is labelled level_shift.'),
 ('order_amount_outlier_rate', 'commerce', 'share of orders with an injected 15-25x amount', 0.002,
  'Labelled in meta.ground_truth with entity = commerce.orders.');

-- Content fingerprint of every generated table, for reproducibility checks.
-- Audit columns stamped at load time (created_at, updated_at, last_updated)
-- and surrogate keys' sequence state are excluded; everything else must match
-- bit-for-bit between two runs with the same scale and seed.
CREATE OR REPLACE FUNCTION meta.fingerprint()
RETURNS TABLE (table_name text, row_count bigint, content_md5 text)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    t   record;
    cols text;
BEGIN
    FOR t IN
        SELECT c.oid, n.nspname, c.relname
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname IN ('civics','commerce','mobility','geo','documents','meta')
          AND NOT c.relispartition
          AND c.relname <> 'dataset'
        ORDER BY 1
    LOOP
        SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
          INTO cols
        FROM pg_attribute a
        WHERE a.attrelid = t.oid AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname NOT IN ('created_at', 'updated_at', 'last_updated', 'search_vector');

        RETURN QUERY EXECUTE format(
            'SELECT %L::text, count(*), md5(coalesce(string_agg(r::text, %L ORDER BY r::text), %L))
             FROM (SELECT ROW(%s) AS r FROM %I.%I) s',
            t.nspname || '.' || t.relname, chr(10), '', cols, t.nspname, t.relname);
    END LOOP;
END
$$;
COMMENT ON FUNCTION meta.fingerprint() IS
'Per-table row count and MD5 of row contents (excluding load-time audit columns). Equal fingerprints = identical dataset.';

CREATE TABLE meta.ground_truth (
    entity     text   NOT NULL,
    entity_id  bigint NOT NULL,
    label      text   NOT NULL,
    detail     jsonb,
    PRIMARY KEY (entity, entity_id, label)
);
COMMENT ON TABLE meta.ground_truth IS
'Labelled anomalies injected by the generator, for precision/recall evaluation of detection methods.';

-- ===========================================================================
-- 1. Geography: 6 x 4 grid of neighbourhoods around 32.98 N, 96.80 W
-- ===========================================================================

TRUNCATE geo.neighborhood_boundaries, geo.points_of_interest, geo.road_segments,
         civics.citizens, civics.permit_applications, civics.tax_payments, civics.voting_records,
         commerce.merchants, commerce.business_licenses, commerce.orders, commerce.order_items, commerce.payments,
         mobility.stations, mobility.station_inventory, mobility.trip_segments, mobility.sensor_readings,
         documents.complaint_records, documents.policy_documents
         RESTART IDENTITY CASCADE;

CREATE TEMP TABLE nb_seed AS
WITH names AS (
    SELECT * FROM unnest(ARRAY[
        'Founders Square','Civic Center','Market Row','Arts District','Station District','Medical Center',
        'Riverside','Oak Hill','University Heights','Tech Valley','Cedar Grove','Industrial Flats',
        'Northgate','Prairie Ridge','Bluebonnet','Cottonwood','Pecan Grove','Live Oak',
        'Magnolia','Willow Creek','Spring Valley','Brookhaven','Westfield','Sunset Ridge'])
         WITH ORDINALITY AS t(name, idx)
)
SELECT
    n.idx::int                                  AS nb,
    n.name,
    ((n.idx - 1) % 6)::int                      AS col,
    ((n.idx - 1) / 6)::int                      AS row,
    -96.86 + ((n.idx - 1) % 6) * 0.02           AS x0,
    32.948 + ((n.idx - 1) / 6) * 0.016          AS y0
FROM names n;

-- Latent socioeconomic surface: richer to the north-west, plus noise.
ALTER TABLE nb_seed ADD COLUMN income_z float8, ADD COLUMN density float8, ADD COLUMN commercial float8;
UPDATE nb_seed SET
    income_z   = 0.45 * (row - 1.5) - 0.30 * (col - 2.5) + 0.6 * synth.z(nb, 1),
    density    = exp(0.8 - 0.25 * abs(col - 2.5) - 0.20 * abs(row - 1.5) + 0.3 * synth.z(nb, 2)),
    commercial = exp(1.2 - 0.45 * abs(col - 2.5) - 0.45 * abs(row - 1.0) + 0.3 * synth.z(nb, 3));
-- standardise income_z so the planted effects are per-SD
UPDATE nb_seed s SET income_z = (s.income_z - m.mu) / m.sd
FROM (SELECT avg(income_z) mu, stddev_pop(income_z) sd FROM nb_seed) m;

INSERT INTO geo.neighborhood_boundaries (
    neighborhood_id, neighborhood_name, official_name, neighborhood_code, boundary_geom,
    population_estimate, household_count, median_income, city_council_district, school_district,
    police_beat, fire_district, zoning_primary, development_status, data_source, last_updated)
OVERRIDING SYSTEM VALUE
SELECT
    nb, name, name || ' Neighborhood', 'NB' || lpad(nb::text, 2, '0'),
    ST_MakeEnvelope(x0, y0, x0 + 0.02, y0 + 0.016, 4326),
    0, 0,
    round((58000 * exp(0.35 * income_z))::numeric, -2),
    1 + (col / 2) + 3 * (row / 2),
    'PISD-' || (1 + col / 3),
    'B' || lpad(nb::text, 2, '0'),
    'FD-' || (1 + (nb - 1) / 4),
    CASE WHEN commercial > 2.4 THEN 'commercial' WHEN commercial > 1.4 THEN 'mixed_use'
         WHEN name = 'Industrial Flats' THEN 'industrial' ELSE 'residential' END,
    CASE WHEN synth.u(nb, 4) < 0.2 THEN 'developing' ELSE 'established' END,
    'polaris-synthetic-v2', (meta.as_of())::date
FROM nb_seed;
SELECT setval(pg_get_serial_sequence('geo.neighborhood_boundaries', 'neighborhood_id'), 24) AS _sv \gset

-- CDF tables used to sample neighbourhoods proportional to a weight.
CREATE TEMP TABLE nb_cdf_pop AS
SELECT nb, coalesce(lag(c) OVER (ORDER BY nb), 0) AS lo, c AS hi
FROM (SELECT nb, sum(density) OVER (ORDER BY nb) / sum(density) OVER () AS c FROM nb_seed) s;
UPDATE nb_cdf_pop SET hi = 1.0000001 WHERE nb = 24;

CREATE TEMP TABLE nb_cdf_com AS
SELECT nb, coalesce(lag(c) OVER (ORDER BY nb), 0) AS lo, c AS hi
FROM (SELECT nb, sum(commercial) OVER (ORDER BY nb) / sum(commercial) OVER () AS c FROM nb_seed) s;
UPDATE nb_cdf_com SET hi = 1.0000001 WHERE nb = 24;

-- Road network: regular grid, ~375 m x ~400 m blocks -------------------------
INSERT INTO geo.road_segments (
    road_name, road_type, address_range_start, address_range_end, zip_code_left, zip_code_right,
    road_surface, lane_count, speed_limit, one_way, segment_geom, has_sidewalk, has_bike_lane,
    has_street_lighting, maintenance_authority, construction_status, last_maintenance,
    condition_rating, data_source)
SELECT
    road_name, road_type::geo.road_type, 100 * seg, 100 * seg + 98, NULL, NULL,
    CASE WHEN road_type IN ('arterial','collector') THEN 'concrete' ELSE 'asphalt' END::geo.road_surface,
    CASE road_type WHEN 'arterial' THEN 4 WHEN 'collector' THEN 2 ELSE 2 END,
    CASE road_type WHEN 'arterial' THEN 45 WHEN 'collector' THEN 35 ELSE 25 END,
    false,
    geom,
    road_type <> 'arterial' OR synth.u(k, 11) < 0.7,
    road_type = 'collector' OR synth.u(k, 12) < 0.15,
    road_type <> 'residential' OR synth.u(k, 13) < 0.6,
    'Polaris City Public Works',
    CASE WHEN synth.u(k, 14) < 0.03 THEN 'under_construction' ELSE 'complete' END,
    (meta.as_of())::date - (synth.u(k, 15) * 1500)::int,
    1 + floor(synth.u(k, 16) * 5)::int,
    'polaris-synthetic-v2'
FROM (
    -- north-south avenues
    SELECT 100000 + i * 100 + j AS k, j AS seg,
           CASE WHEN i % 5 = 0 THEN 'arterial' WHEN i % 5 = 2 THEN 'collector' ELSE 'residential' END AS road_type,
           (ARRAY['Elm','Maple','Pine','Birch','Cedar','Walnut','Hickory','Aspen','Juniper','Sycamore'])[1 + i % 10]
             || ' ' || CASE WHEN i % 5 = 0 THEN 'Parkway' ELSE 'Avenue' END || ' ' || (i / 10 + 1) AS road_name,
           ST_SetSRID(ST_MakeLine(ST_MakePoint(-96.86 + i * 0.004, 32.948 + j * 0.0036),
                                  ST_MakePoint(-96.86 + i * 0.004, 32.948 + (j + 1) * 0.0036)), 4326) AS geom
    FROM generate_series(0, 30) i, generate_series(0, 16) j
    UNION ALL
    -- east-west streets
    SELECT 200000 + j * 100 + i, i,
           CASE WHEN j % 4 = 0 THEN 'arterial' WHEN j % 4 = 2 THEN 'collector' ELSE 'residential' END,
           (j + 1) || CASE (j + 1) % 10 WHEN 1 THEN 'st' WHEN 2 THEN 'nd' WHEN 3 THEN 'rd' ELSE 'th' END
             || CASE WHEN j % 4 = 0 THEN ' Boulevard' ELSE ' Street' END,
           ST_SetSRID(ST_MakeLine(ST_MakePoint(-96.86 + i * 0.004, 32.948 + j * 0.0036),
                                  ST_MakePoint(-96.86 + (i + 1) * 0.004, 32.948 + j * 0.0036)), 4326)
    FROM generate_series(0, 17) j, generate_series(0, 29) i
) r
ORDER BY r.k;

UPDATE geo.road_segments r SET neighborhood_id = n.neighborhood_id,
       zip_code_left = '75' || lpad((100 + n.neighborhood_id)::text, 3, '0'),
       zip_code_right = '75' || lpad((100 + n.neighborhood_id)::text, 3, '0')
FROM geo.neighborhood_boundaries n
WHERE ST_Intersects(n.boundary_geom, ST_LineInterpolatePoint(r.segment_geom, 0.5));

-- ===========================================================================
-- 2. People
-- ===========================================================================

CREATE TEMP TABLE name_pool AS
SELECT ARRAY['James','Mary','Robert','Patricia','John','Jennifer','Michael','Linda','David','Elizabeth',
             'William','Barbara','Richard','Susan','Joseph','Jessica','Thomas','Sarah','Carlos','Karen',
             'Daniel','Lisa','Matthew','Nancy','Anthony','Betty','Mark','Sandra','Luis','Ashley',
             'Steven','Kimberly','Andrew','Emily','Jose','Donna','Kevin','Michelle','Brian','Carol',
             'Wei','Amanda','Juan','Melissa','Priya','Deborah','Omar','Stephanie','Ahmed','Rebecca',
             'Hiroshi','Laura','Ivan','Sharon','Kwame','Cynthia','Mateo','Fatima','Arjun','Mei'] AS first_names,
       ARRAY['Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez',
             'Hernandez','Lopez','Gonzalez','Wilson','Anderson','Thomas','Taylor','Moore','Jackson','Martin',
             'Lee','Perez','Thompson','White','Harris','Sanchez','Clark','Ramirez','Lewis','Robinson',
             'Walker','Young','Allen','King','Wright','Scott','Torres','Nguyen','Hill','Flores',
             'Green','Adams','Nelson','Baker','Hall','Rivera','Campbell','Mitchell','Carter','Roberts',
             'Patel','Kim','Chen','Singh','Okafor','Tanaka','Ivanova','Haddad','Kowalski','Mensah'] AS last_names,
       ARRAY['Main','Oak','Park','Lake','Hill','River','Church','Mill','Spring','Ridge',
             'Meadow','Forest','Sunset','Highland','Valley','Willow','Prairie','Mesa','Bluebonnet','Pecan'] AS streets,
       ARRAY['St','Ave','Blvd','Dr','Ln','Ct','Way','Pl'] AS suffixes;

-- Citizens ---------------------------------------------------------------------
INSERT INTO civics.citizens (
    first_name, last_name, date_of_birth, ssn_hash, email, phone, street_address, zip_code,
    home_geom, status, registered_date, created_at, updated_at)
SELECT
    fn, ln,
    (meta.as_of())::date - ((18 + 72 * power(synth.u(i, 102), 1.35)) * 365.25)::int,
    encode(sha256(convert_to('citizen:' || i || ':' || current_setting('polaris.seed'), 'UTF8')), 'hex'),
    lower(fn || '.' || ln || '.' || i || '@mail.polaris.example'),
    '(972) 555-' || lpad((i % 10000)::text, 4, '0'),
    (100 + floor(synth.u(i, 103) * 9800))::int || ' '
        || np.streets[1 + floor(synth.u(i, 104) * 20)::int] || ' '
        || np.suffixes[1 + floor(synth.u(i, 105) * 8)::int],
    '75' || lpad((100 + c.nb)::text, 3, '0'),
    ST_SetSRID(ST_MakePoint(s.x0 + 0.02 * synth.u(i, 106), s.y0 + 0.016 * synth.u(i, 107)), 4326),
    synth.pick(ARRAY['active','inactive','suspended','deceased'], ARRAY[96, 2.5, 1, 0.5], synth.u(i, 108))::civics.civic_status,
    meta.as_of() - make_interval(secs => synth.u(i, 109) * 10 * 365.25 * 86400),
    meta.as_of() - make_interval(secs => synth.u(i, 109) * 10 * 365.25 * 86400),
    meta.as_of() - make_interval(secs => synth.u(i, 109) * 2 * 365.25 * 86400)
FROM generate_series(1, (10000 * :scale)::int) i
CROSS JOIN name_pool np
CROSS JOIN LATERAL (SELECT np.first_names[1 + floor(synth.u(i, 100) * 60)::int] AS fn,
                           np.last_names [1 + floor(synth.u(i, 101) * 60)::int] AS ln) n
JOIN nb_cdf_pop c ON synth.u(i, 110) >= c.lo AND synth.u(i, 110) < c.hi
JOIN nb_seed s ON s.nb = c.nb
ORDER BY i;

UPDATE geo.neighborhood_boundaries n SET
    population_estimate = p.cnt,
    household_count     = round(p.cnt / 2.45)
FROM (SELECT ('1' || right(zip_code, 2))::int - 100 AS nb, count(*) AS cnt
      FROM civics.citizens GROUP BY 1) p
WHERE n.neighborhood_id = p.nb;

-- Fast lookups used by the remaining sections.
CREATE TEMP TABLE cit AS
SELECT c.citizen_id, ('1' || right(c.zip_code, 2))::int - 100 AS nb,
       extract(year FROM age(meta.as_of(), c.date_of_birth))::int AS age_years,
       s.income_z
FROM civics.citizens c JOIN nb_seed s ON s.nb = ('1' || right(c.zip_code, 2))::int - 100;
CREATE UNIQUE INDEX ON cit (citizen_id);
ANALYZE cit;

-- ===========================================================================
-- 3. Civics: permits, taxes, votes
-- ===========================================================================

INSERT INTO civics.permit_applications (
    citizen_id, permit_type, permit_number, description, property_address, parcel_id, status,
    application_date, approval_date, expiration_date, fee_amount, fee_paid, created_at, updated_at)
SELECT
    cid, ptype::civics.permit_type,
    'PRM-' || to_char(app, 'YYYY') || '-' || lpad(i::text, 6, '0'),
    initcap(ptype) || ' permit: ' || (ARRAY['new construction','renovation','temporary structure','change of use',
                                             'street closure','signage','outdoor seating','fence installation'])[1 + floor(synth.u(i, 205) * 8)::int],
    (100 + floor(synth.u(i, 206) * 9800))::int || ' Permit Way',
    'PCL-' || lpad(nb::text, 2, '0') || '-' || lpad(i::text, 6, '0'),
    st::civics.permit_status,
    app,
    CASE WHEN st IN ('approved','expired','revoked') THEN app + make_interval(days => 1 + synth.exp(i, 207, 9)::int) END,
    CASE WHEN st IN ('approved','expired','revoked')
         THEN app + make_interval(days => 1 + synth.exp(i, 207, 9)::int)
                  + CASE ptype WHEN 'event' THEN interval '14 days' WHEN 'parking' THEN interval '365 days'
                               ELSE interval '180 days' END END,
    fee, CASE WHEN st IN ('approved','expired','revoked') THEN fee ELSE 0 END,
    app, app
FROM (
    SELECT i, c.citizen_id AS cid, c.nb,
           synth.pick(ARRAY['building','business','event','parking','street'], ARRAY[35,20,20,15,10], synth.u(i, 201)) AS ptype,
           meta.as_of() - make_interval(secs => synth.u(i, 202) * 3 * 365.25 * 86400) AS app,
           synth.pick(ARRAY['approved','pending','denied','expired','revoked'], ARRAY[62,12,10,14,2], synth.u(i, 203)) AS st,
           round((50 + synth.exp(i, 204, 250))::numeric, 2) AS fee
    FROM generate_series(1, (3000 * :scale)::int) i
    JOIN cit c ON c.citizen_id = 1 + floor(synth.u(i, 200) * (10000 * :scale))::bigint
) p
ORDER BY p.i;
-- Status must be consistent with as_of: nothing is decided in the future.
UPDATE civics.permit_applications
SET status = 'pending', approval_date = NULL, expiration_date = NULL, fee_paid = 0
WHERE approval_date > meta.as_of();
UPDATE civics.permit_applications SET status = 'expired'
WHERE status = 'approved' AND expiration_date < meta.as_of();

-- Property (55% of residents) and vehicle (40%) tax, 2023-2025.
INSERT INTO civics.tax_payments (
    citizen_id, tax_type, tax_year, assessment_amount, amount_due, amount_paid, payment_status,
    due_date, payment_date, property_address, assessed_value, mill_rate, created_at, updated_at)
SELECT
    citizen_id, ttype::civics.tax_type, yr, assessed, due,
    paid, pstatus::civics.payment_status, due_date,
    CASE WHEN paid > 0 THEN least((due_date - (synth.u(k, 306) * 40)::int)::timestamptz + interval '10 hours',
                                  meta.as_of() - make_interval(hours => 1 + (synth.u(k, 307) * 1000)::int)) END,
    CASE WHEN ttype = 'property' THEN 'Parcel of citizen ' || citizen_id END,
    CASE WHEN ttype = 'property' THEN assessed END,
    mill, due_date - 90, due_date - 90
FROM (
    SELECT t.*, round(assessed * mill / 1000, 2) AS due,
           CASE WHEN pay_u < 0.88 THEN round(assessed * mill / 1000, 2)
                WHEN pay_u < 0.93 THEN round(assessed * mill / 1000 * 0.5, 2)
                ELSE 0 END AS paid,
           CASE WHEN pay_u < 0.88 THEN 'paid'
                WHEN due_date > meta.as_of() THEN 'pending'
                ELSE 'overdue' END AS pstatus
    FROM (
        SELECT c.citizen_id, tt.ttype, y.yr,
               (c.citizen_id * 10 + tt.n) * 10000 + y.yr AS k,
               make_date(y.yr + 1, 1, 31) AS due_date,
               CASE tt.ttype
                 WHEN 'property' THEN round((240000 * exp(0.35 * c.income_z + 0.30 * synth.z(c.citizen_id, 300)))::numeric, -2)
                 ELSE round((9000 + 21000 * synth.u(c.citizen_id, 301))::numeric, -2) END AS assessed,
               CASE tt.ttype WHEN 'property' THEN 21.5000 ELSE 9.7500 END::numeric AS mill,
               synth.u((c.citizen_id * 10 + tt.n) * 10000 + y.yr, 305) AS pay_u
        FROM cit c
        CROSS JOIN (VALUES ('property', 1), ('vehicle', 2)) tt(ttype, n)
        CROSS JOIN generate_series(2023, 2025) y(yr)
        WHERE c.age_years >= 21
          AND ((tt.ttype = 'property' AND synth.u(c.citizen_id, 302) < 0.55)
            OR (tt.ttype = 'vehicle'  AND synth.u(c.citizen_id, 303) < 0.40))
    ) t
) t2
ORDER BY t2.citizen_id, t2.ttype, t2.yr;

-- Voting: logistic turnout with planted age and income slopes.
INSERT INTO civics.voting_records (
    citizen_id, election_name, election_date, vote_type, precinct, ballot_style, voted_at, voting_method)
SELECT
    c.citizen_id, e.name, e.d, e.vt::civics.vote_type,
    'PCT-' || lpad(c.nb::text, 3, '0'), 'BS-' || e.id || '-' || (1 + c.nb % 3),
    e.d + make_interval(hours => 7 + floor(synth.u(c.citizen_id * 10 + e.id, 402) * 12)::int,
                        mins => floor(synth.u(c.citizen_id * 10 + e.id, 403) * 60)::int),
    synth.pick(ARRAY['in_person','early','mail'],
               ARRAY[55, 30, 15 + greatest(0, c.age_years - 60)], synth.u(c.citizen_id * 10 + e.id, 404))
FROM cit c
CROSS JOIN (VALUES (1, 'Municipal General 2023', date '2023-05-06', 'municipal', -0.2),
                   (2, 'Bond Referendum 2023',   date '2023-11-07', 'referendum', -0.9),
                   (3, 'School Board 2024',      date '2024-05-04', 'school_board', -1.1),
                   (4, 'Municipal General 2025', date '2025-05-03', 'municipal', 0.0)) e(id, name, d, vt, eff)
WHERE c.age_years >= 18 + (extract(year FROM meta.as_of())::int - extract(year FROM e.d)::int)
  AND synth.u(c.citizen_id * 10 + e.id, 401)
      < synth.sigmoid(-0.6 + 0.035 * (c.age_years - 45) + 0.40 * c.income_z + e.eff)
ORDER BY c.citizen_id, e.id;

-- ===========================================================================
-- 4. Commerce
-- ===========================================================================

INSERT INTO commerce.merchants (
    business_name, legal_name, tax_id, owner_citizen_id, contact_email, contact_phone, business_address,
    zip_code, business_type, industry_code, website, description, annual_revenue, employee_count,
    is_active, registration_date, created_at, updated_at)
SELECT
    bname, bname || ' LLC', '75-' || lpad(i::text, 7, '0'),
    1 + floor(synth.u(i, 501) * (10000 * :scale))::bigint,
    'contact@merchant-' || i || '.polaris.example',
    '(214) 555-' || lpad((i % 10000)::text, 4, '0'),
    (100 + floor(synth.u(i, 502) * 9800))::int || ' Commerce St',
    '75' || lpad((100 + c.nb)::text, 3, '0'),
    btype::commerce.business_type,
    CASE btype WHEN 'restaurant' THEN '722511' WHEN 'retail' THEN '445110' WHEN 'service' THEN '812111'
               WHEN 'technology' THEN '541511' WHEN 'healthcare' THEN '621111' WHEN 'manufacturing' THEN '332710'
               ELSE '999999' END,
    'https://merchant-' || i || '.polaris.example',
    initcap(btype) || ' business serving ' || s.name,
    round(exp(12.6 + 1.1 * synth.z(i, 503))::numeric, 2),
    greatest(1, round(exp(12.6 + 1.1 * synth.z(i, 503)) / 95000))::int,
    synth.u(i, 504) < 0.92,
    reg, reg, reg
FROM generate_series(1, (500 * :scale)::int) i
CROSS JOIN LATERAL (SELECT synth.pick(ARRAY['restaurant','retail','service','technology','healthcare','manufacturing','other'],
                                      ARRAY[30,25,20,8,7,4,6], synth.u(i, 500)) AS btype,
                           meta.as_of() - make_interval(secs => (0.5 + synth.u(i, 505) * 12) * 365.25 * 86400) AS reg) b
CROSS JOIN LATERAL (SELECT (ARRAY['Lone Star','Polaris','Bluebonnet','Northgate','Riverside','Cedar','Golden','Prairie',
                                  'Union','Main Street','Pioneer','Summit','Harbor','Liberty','Maple','Star'])[1 + floor(synth.u(i, 506) * 16)::int]
                           || ' ' ||
                           CASE b.btype WHEN 'restaurant' THEN (ARRAY['Kitchen','Grill','Cafe','Taqueria','Bistro','BBQ'])[1 + floor(synth.u(i, 507) * 6)::int]
                                        WHEN 'retail' THEN (ARRAY['Market','Outfitters','Goods','Supply','Mercantile'])[1 + floor(synth.u(i, 507) * 5)::int]
                                        WHEN 'service' THEN (ARRAY['Cleaners','Salon','Repair','Services'])[1 + floor(synth.u(i, 507) * 4)::int]
                                        WHEN 'technology' THEN (ARRAY['Labs','Software','Systems','Analytics'])[1 + floor(synth.u(i, 507) * 4)::int]
                                        WHEN 'healthcare' THEN (ARRAY['Clinic','Pharmacy','Dental','Health'])[1 + floor(synth.u(i, 507) * 4)::int]
                                        WHEN 'manufacturing' THEN (ARRAY['Works','Fabrication','Industries'])[1 + floor(synth.u(i, 507) * 3)::int]
                                        ELSE 'Co' END || ' #' || i AS bname) nm
JOIN nb_cdf_com c ON synth.u(i, 508) >= c.lo AND synth.u(i, 508) < c.hi
JOIN nb_seed s ON s.nb = c.nb
ORDER BY i;

INSERT INTO commerce.business_licenses (
    merchant_id, license_type, license_number, status, application_date, issue_date, expiration_date,
    renewal_date, license_fee, fee_paid, inspection_required, last_inspection_date, next_inspection_due)
SELECT
    m.merchant_id, lt.ltype, 'BL-' || lt.code || '-' || lpad(m.merchant_id::text, 6, '0'),
    CASE WHEN iss + 365 > (meta.as_of())::date THEN 'active' ELSE 'expired' END::commerce.license_status,
    iss - 14, iss, iss + 365, CASE WHEN iss + 365 > (meta.as_of())::date THEN iss + 335 END,
    lt.fee, lt.fee, lt.inspect,
    CASE WHEN lt.inspect THEN least(iss + (synth.u(m.merchant_id * 10 + lt.n, 602) * 200)::int, (meta.as_of())::date) END,
    CASE WHEN lt.inspect THEN iss + 365 END
FROM commerce.merchants m
CROSS JOIN LATERAL (VALUES ('general_business', 'GB', 1, 150.00, false),
                           ('food_service',     'FS', 2, 325.00, true),
                           ('health_facility',  'HF', 3, 500.00, true)) lt(ltype, code, n, fee, inspect)
CROSS JOIN LATERAL (SELECT (meta.as_of())::date
                           - CASE WHEN synth.u(m.merchant_id * 10 + lt.n, 600) < 0.9
                                  THEN (synth.u(m.merchant_id * 10 + lt.n, 601) * 330)::int
                                  ELSE 400 + (synth.u(m.merchant_id * 10 + lt.n, 601) * 300)::int END AS iss) d
WHERE lt.n = 1
   OR (lt.n = 2 AND m.business_type = 'restaurant')
   OR (lt.n = 3 AND m.business_type = 'healthcare')
ORDER BY m.merchant_id, lt.n;

-- Orders: Zipf merchant popularity, weekly + diurnal seasonality, growth.
CREATE TEMP TABLE dow_cdf AS
SELECT d, coalesce(lag(c) OVER (ORDER BY d), 0) lo, c hi FROM (
  SELECT d, sum(w) OVER (ORDER BY d) / sum(w) OVER () c
  FROM unnest(ARRAY[0.12,0.12,0.13,0.14,0.17,0.18,0.14]) WITH ORDINALITY t(w, d)) s;  -- Mon..Sun
UPDATE dow_cdf SET hi = 1.0000001 WHERE d = 7;

CREATE TEMP TABLE hour_cdf_orders AS
SELECT h - 1 AS h, coalesce(lag(c) OVER (ORDER BY h), 0) lo, c hi FROM (
  SELECT h, sum(w) OVER (ORDER BY h) / sum(w) OVER () c
  FROM unnest(ARRAY[0.3,0.2,0.1,0.1,0.1,0.3,0.8,1.6,2.2,2.6,3.2,5.5,7.5,5.0,3.4,3.2,3.8,5.6,7.6,7.0,5.0,3.2,1.6,0.8])
       WITH ORDINALITY t(w, h)) s;
UPDATE hour_cdf_orders SET hi = 1.0000001 WHERE h = 23;

ALTER TABLE commerce.order_items DISABLE TRIGGER USER;

CREATE TEMP TABLE ord AS
SELECT
    i AS order_id,
    -- popularity rank -> merchant via a fixed permutation (7919 is prime)
    1 + ((synth.zipf(i, 700, nm, 1.10) - 1)::bigint * 7919) % nm AS merchant_id,
    1 + floor(synth.u(i, 701) * nc)::bigint AS customer_citizen_id,
    date_trunc('week', meta.as_of() - interval '364 days')
        + make_interval(weeks => floor(52 * power(synth.u(i, 702), 0.85))::int,
                        days  => (dc.d - 1)::int,
                        hours => hc.h::int,
                        mins  => floor(synth.u(i, 705) * 60)::int,
                        secs  => floor(synth.u(i, 706) * 60)) AS order_date,
    synth.u(i, 707) < 0.002 AS is_outlier
FROM generate_series(1, (50000 * :scale)::int) i
CROSS JOIN (SELECT (500 * :scale)::int AS nm, (10000 * :scale)::int AS nc) n
JOIN dow_cdf dc ON synth.u(i, 703) >= dc.lo AND synth.u(i, 703) < dc.hi
JOIN hour_cdf_orders hc ON synth.u(i, 704) >= hc.lo AND synth.u(i, 704) < hc.hi;
DELETE FROM ord WHERE order_date > meta.as_of();

INSERT INTO commerce.orders (order_id, merchant_id, customer_citizen_id, order_number, order_date, status,
                             delivery_address, created_at, updated_at)
OVERRIDING SYSTEM VALUE
SELECT o.order_id, o.merchant_id, o.customer_citizen_id,
       'ORD-' || to_char(o.order_date, 'YYYYMMDD') || '-' || lpad(o.order_id::text, 7, '0'),
       o.order_date,
       CASE WHEN o.order_date > meta.as_of() - interval '1 day'
            THEN synth.pick(ARRAY['pending','confirmed','processing'], ARRAY[3,3,4], synth.u(o.order_id, 710))
            WHEN o.order_date > meta.as_of() - interval '4 days'
            THEN synth.pick(ARRAY['shipped','delivered'], ARRAY[4,6], synth.u(o.order_id, 710))
            ELSE synth.pick(ARRAY['delivered','cancelled','refunded'], ARRAY[94,4,2], synth.u(o.order_id, 710)) END::commerce.order_status,
       CASE WHEN synth.u(o.order_id, 711) < 0.4 THEN (100 + floor(synth.u(o.order_id, 712) * 9800))::int || ' Delivery Ln' END,
       o.order_date, o.order_date
FROM ord o
ORDER BY o.order_id;
SELECT setval(pg_get_serial_sequence('commerce.orders', 'order_id'), (SELECT max(order_id) FROM commerce.orders)) AS _sv \gset

INSERT INTO commerce.order_items (order_id, item_name, item_description, sku, unit_price, quantity, line_total, item_options, created_at)
SELECT o.order_id, it.item_name, it.item_name || ' from merchant ' || o.merchant_id,
       'SKU-' || o.merchant_id || '-' || it.n,
       it.price, it.qty, it.price * it.qty,
       CASE WHEN m.business_type = 'restaurant' THEN jsonb_build_object('spice', (ARRAY['mild','medium','hot'])[1 + it.n % 3]) END,
       o.order_date
FROM ord o
JOIN commerce.merchants m ON m.merchant_id = o.merchant_id
CROSS JOIN LATERAL generate_series(1, 1 + floor(power(synth.u(o.order_id, 720), 2) * 5)::int) AS li(n)
CROSS JOIN LATERAL (
    SELECT li.n,
           (ARRAY['Standard item','Premium item','Combo','Accessory','Service fee','Seasonal special'])[1 + floor(synth.u(o.order_id * 10 + li.n, 721) * 6)::int] AS item_name,
           round((CASE m.business_type WHEN 'restaurant' THEN exp(2.4 + 0.45 * synth.z(o.order_id * 10 + li.n, 722))
                                       WHEN 'retail' THEN exp(3.0 + 0.70 * synth.z(o.order_id * 10 + li.n, 722))
                                       WHEN 'technology' THEN exp(4.6 + 0.80 * synth.z(o.order_id * 10 + li.n, 722))
                                       WHEN 'healthcare' THEN exp(4.0 + 0.60 * synth.z(o.order_id * 10 + li.n, 722))
                                       ELSE exp(3.4 + 0.70 * synth.z(o.order_id * 10 + li.n, 722)) END
                  * CASE WHEN o.is_outlier THEN 15 + 10 * synth.u(o.order_id, 723) ELSE 1 END)::numeric, 2) + 0.01 AS price,
           1 + floor(power(synth.u(o.order_id * 10 + li.n, 724), 3) * 4)::int AS qty
) it
ORDER BY o.order_id, it.n;

ALTER TABLE commerce.order_items ENABLE TRIGGER USER;

UPDATE commerce.orders o SET
    subtotal     = s.sub,
    tax_amount   = round(s.sub * 0.0825, 2),
    tip_amount   = CASE WHEN m.business_type = 'restaurant' THEN round(s.sub * (0.10 + 0.12 * synth.u(o.order_id, 730))::numeric, 2) ELSE 0 END,
    total_amount = s.sub + round(s.sub * 0.0825, 2)
                 + CASE WHEN m.business_type = 'restaurant' THEN round(s.sub * (0.10 + 0.12 * synth.u(o.order_id, 730))::numeric, 2) ELSE 0 END,
    estimated_delivery = o.order_date + CASE WHEN m.business_type = 'restaurant' THEN interval '45 minutes' ELSE interval '3 days' END,
    actual_delivery = CASE WHEN o.status = 'delivered' THEN
        o.order_date + CASE WHEN m.business_type = 'restaurant'
                            THEN make_interval(mins => (20 + synth.exp(o.order_id, 731, 25))::int)
                            ELSE make_interval(hours => (24 + synth.exp(o.order_id, 731, 48))::int) END END
FROM (SELECT order_id, sum(line_total) sub FROM commerce.order_items GROUP BY order_id) s,
     commerce.merchants m
WHERE s.order_id = o.order_id AND m.merchant_id = o.merchant_id;

-- A delivery that would land after as_of has not happened yet.
UPDATE commerce.orders SET status = 'shipped', actual_delivery = NULL
WHERE actual_delivery > meta.as_of();

INSERT INTO meta.ground_truth (entity, entity_id, label, detail)
SELECT 'commerce.orders', order_id, 'order_amount_outlier', jsonb_build_object('multiplier_range', '15-25')
FROM ord WHERE is_outlier AND order_id IN (SELECT order_id FROM commerce.orders);

INSERT INTO commerce.payments (order_id, payment_method, amount, status, transaction_id, processor, payment_date,
                               processed_at, reference_number, receipt_number, processor_response, failure_reason, created_at)
SELECT o.order_id, pm::commerce.payment_method, o.total_amount, ps::commerce.payment_status,
       'TXN-' || lpad(o.order_id::text, 9, '0') || '-' || p.attempt,
       CASE WHEN pm IN ('credit_card','debit_card','digital_wallet') THEN 'StripeLike' WHEN pm = 'bank_transfer' THEN 'ACH' ELSE 'in_store' END,
       o.order_date + make_interval(secs => p.attempt * 30),
       CASE WHEN ps IN ('completed','refunded') THEN o.order_date + make_interval(secs => p.attempt * 30 + 2) END,
       'REF-' || o.order_id || '-' || p.attempt,
       CASE WHEN ps = 'completed' THEN 'RCPT-' || o.order_id END,
       jsonb_build_object('code', CASE WHEN ps = 'failed' THEN 'card_declined' ELSE 'approved' END, 'latency_ms', 80 + floor(synth.exp(o.order_id * 10 + p.attempt, 742, 120))),
       CASE WHEN ps = 'failed' THEN 'Card declined by issuer' END,
       o.order_date
FROM commerce.orders o
CROSS JOIN LATERAL (
    SELECT a AS attempt,
           synth.pick(ARRAY['credit_card','debit_card','digital_wallet','cash','bank_transfer','check'],
                      ARRAY[45,25,18,8,3,1], synth.u(o.order_id, 740)) AS pm,
           CASE WHEN a = 1 AND synth.u(o.order_id, 741) < 0.015 THEN 'failed'
                WHEN o.status = 'refunded' THEN 'refunded'
                WHEN o.status IN ('pending') THEN 'pending'
                ELSE 'completed' END AS ps
    FROM generate_series(1, 2) a
) p
WHERE o.status <> 'cancelled' AND o.total_amount > 0
  AND (p.attempt = 1 OR synth.u(o.order_id, 741) < 0.015)
ORDER BY o.order_id, p.attempt;

-- ===========================================================================
-- 5. Mobility
-- ===========================================================================

INSERT INTO mobility.stations (station_code, station_name, station_type, latitude, longitude, address, neighborhood,
                               total_capacity, accessible, covered, lighting, status, operator, installation_date,
                               last_maintenance, next_maintenance_due, amenities)
SELECT
    upper(left(t.stype, 3)) || '-' || lpad(g.n::text, 3, '0'),
    s.name || ' ' || initcap(replace(t.stype, '_', ' ')) || ' ' || g.n,
    t.stype::mobility.station_type,
    round(lat::numeric, 6), round(lng::numeric, 6),
    (100 + g.n * 7) || ' Transit Way', s.name,
    t.cap, synth.u(k, 802) < 0.85, synth.u(k, 803) < 0.5, synth.u(k, 804) < 0.9,
    synth.pick(ARRAY['active','maintenance','offline'], ARRAY[94,4,2], synth.u(k, 805))::mobility.station_status,
    t.op, (meta.as_of())::date - (365 + synth.u(k, 806) * 3000)::int,
    (meta.as_of())::date - (synth.u(k, 807) * 120)::int,
    (meta.as_of())::date + (synth.u(k, 808) * 120)::int,
    jsonb_build_object('bench', synth.u(k, 809) < 0.7, 'shelter', synth.u(k, 803) < 0.5, 'realtime_display', synth.u(k, 810) < 0.4)
FROM (VALUES (1,'bus',60,40,'Polaris Transit'), (2,'rail',12,400,'Polaris Transit'), (3,'bike_share',40,20,'PolarisBike'),
             (4,'scooter',20,30,'ScootCo'), (5,'park_ride',8,250,'Polaris Transit'), (6,'ev_charging',10,8,'ChargeTX')) t(tn, stype, cnt, cap, op)
CROSS JOIN LATERAL generate_series(1, t.cnt) g(n)
CROSS JOIN LATERAL (SELECT t.tn * 1000 + g.n AS k) kk
JOIN nb_cdf_com c ON synth.u(k, 800) >= c.lo AND synth.u(k, 800) < c.hi
JOIN nb_seed s ON s.nb = c.nb
CROSS JOIN LATERAL (
    SELECT CASE WHEN t.stype = 'rail' THEN 32.948 + 0.032 + 0.0005 * synth.z(k, 811)   -- east-west rail corridor
                ELSE s.y0 + 0.016 * synth.u(k, 811) END AS lat,
           CASE WHEN t.stype = 'rail' THEN -96.855 + 0.11 * (g.n - 1) / 11.0
                ELSE s.x0 + 0.02 * synth.u(k, 812) END AS lng
) xy
ORDER BY t.tn, g.n;

CREATE TEMP TABLE st_range AS
SELECT station_type::text AS stype, min(station_id) AS lo, count(*) AS n FROM mobility.stations GROUP BY 1;

-- Hourly inventory snapshots for shared-micromobility docks, last 30 days.
INSERT INTO mobility.station_inventory (station_id, available_count, in_use_count, maintenance_count, recorded_at, inventory_details)
SELECT st.station_id, avail, greatest(0, st.total_capacity - avail - maint), maint, ts,
       jsonb_build_object('battery_avg', CASE WHEN st.station_type = 'scooter' THEN round((0.55 + 0.4 * synth.u(k, 822))::numeric, 2) END)
FROM mobility.stations st
CROSS JOIN generate_series(meta.as_of() - interval '30 days' + interval '1 second', meta.as_of(), interval '1 hour') ts
CROSS JOIN LATERAL (SELECT st.station_id * 100000 + extract(epoch FROM ts)::bigint / 3600 AS k) kk
CROSS JOIN LATERAL (
    SELECT (synth.u(k, 820) < 0.05)::int + (synth.u(k, 821) < 0.02)::int AS maint,
           least(st.total_capacity, greatest(0, round(
               st.total_capacity * (0.55 - 0.35 * sin(2 * pi() * (extract(hour FROM ts) - 6) / 24.0))
               + 2.0 * synth.z(k, 823)))::int) AS avail
) v
WHERE st.station_type IN ('bike_share', 'scooter')
ORDER BY st.station_id, ts;

-- Trips: commute-shaped demand, mode-specific distance/speed, peak congestion,
-- exponential transit delays (planted 3x peak ratio). 15% of transit trips
-- have a walking access leg (segment_order 1).
CREATE TEMP TABLE hour_cdf_trips AS
SELECT wk, h - 1 AS h, coalesce(lag(c) OVER (PARTITION BY wk ORDER BY h), 0) lo, c hi FROM (
  SELECT wk, h, sum(w) OVER (PARTITION BY wk ORDER BY h) / sum(w) OVER (PARTITION BY wk) c
  FROM (SELECT false AS wk, w, h FROM unnest(ARRAY[0.2,0.1,0.1,0.1,0.3,1.0,3.5,7.5,8.0,4.5,3.5,3.8,4.2,3.8,3.6,4.5,6.5,8.2,7.0,4.5,3.0,2.2,1.4,0.6]) WITH ORDINALITY t(w, h)
        UNION ALL
        SELECT true, w, h FROM unnest(ARRAY[0.6,0.4,0.2,0.1,0.1,0.3,0.6,1.2,2.2,3.5,4.6,5.4,5.8,5.6,5.4,5.2,5.0,5.0,4.6,4.0,3.2,2.4,1.6,1.0]) WITH ORDINALITY t(w, h)) x) s;
UPDATE hour_cdf_trips SET hi = 1.0000001 WHERE h = 23;

CREATE TEMP TABLE trip_base AS
SELECT i AS trip_no,
       mode,
       1 + floor(synth.u(i, 901) * (10000 * :scale))::bigint AS user_id,
       ts,
       extract(isodow FROM ts) <= 5 AND (extract(hour FROM ts) BETWEEN 7 AND 8 OR extract(hour FROM ts) BETWEEN 16 AND 18) AS is_peak,
       extract(isodow FROM ts) >= 6 AS is_weekend
FROM generate_series(1, (50000 * :scale)::int) i
CROSS JOIN LATERAL (SELECT synth.pick(ARRAY['car','bus','walking','cycling','rail','rideshare','scooter','other'],
                                      ARRAY[30,18,15,10,8,9,7,3], synth.u(i, 900)) AS mode,
                           (date_trunc('day', meta.as_of()) - make_interval(days => floor(synth.u(i, 902) * 180)::int))::date AS day) a
CROSS JOIN LATERAL (SELECT extract(isodow FROM a.day) >= 6 AS wk) w
JOIN hour_cdf_trips hc ON hc.wk = w.wk AND synth.u(i, 903) >= hc.lo AND synth.u(i, 903) < hc.hi
CROSS JOIN LATERAL (SELECT a.day + make_interval(hours => hc.h::int, mins => floor(synth.u(i, 904) * 60)::int,
                                                 secs => floor(synth.u(i, 905) * 60)) AS ts) t;

INSERT INTO mobility.trip_segments (
    trip_id, segment_order, user_id, trip_mode, start_time, end_time, duration_minutes,
    start_latitude, start_longitude, end_latitude, end_longitude, start_station_id, end_station_id,
    distance_km, average_speed_kmh, fare_paid, payment_method, comfort_rating, delay_minutes,
    route_taken, trip_purpose, created_at)
SELECT
    'T' || lpad(b.trip_no::text, 8, '0'), seg.ord, b.user_id, seg.mode::mobility.trip_mode,
    seg.t0, seg.t0 + make_interval(secs => round(seg.minutes * 60 + seg.delay * 60)),
    round(seg.minutes + seg.delay)::int,
    coalesce(ss.latitude, round((32.948 + 0.064 * synth.u(seg.k, 920))::numeric, 6)),
    coalesce(ss.longitude, round((-96.86 + 0.12 * synth.u(seg.k, 921))::numeric, 6)),
    coalesce(es.latitude, round((32.948 + 0.064 * synth.u(seg.k, 922))::numeric, 6)),
    coalesce(es.longitude, round((-96.86 + 0.12 * synth.u(seg.k, 923))::numeric, 6)),
    ss.station_id, es.station_id,
    round(seg.dist::numeric, 3), round(seg.speed::numeric, 2),
    CASE seg.mode WHEN 'bus' THEN 2.50 WHEN 'rail' THEN round((2.50 + 0.10 * seg.dist)::numeric, 2)
                  WHEN 'scooter' THEN round((1.00 + 0.39 * seg.minutes)::numeric, 2)
                  WHEN 'rideshare' THEN round((3.00 + 1.60 * seg.dist)::numeric, 2)
                  WHEN 'cycling' THEN CASE WHEN ss.station_id IS NOT NULL THEN 1.75 ELSE 0 END
                  ELSE 0 END,
    CASE WHEN seg.mode IN ('bus','rail') THEN synth.pick(ARRAY['transit_card','mobile_app','cash'], ARRAY[60,32,8], synth.u(seg.k, 930))
         WHEN seg.mode IN ('scooter','rideshare','cycling') THEN 'mobile_app' END,
    greatest(1, least(5, round(4.3 - 0.12 * seg.delay + 0.7 * synth.z(seg.k, 931))))::int,
    round(seg.delay)::int,
    jsonb_build_object('waypoints', 2 + floor(seg.dist)::int, 'congested', b.is_peak AND seg.mode IN ('car','bus','rideshare')),
    CASE WHEN b.is_peak THEN 'commute'
         ELSE synth.pick(ARRAY['errand','leisure','commute','school','medical'], ARRAY[35,30,15,12,8], synth.u(b.trip_no, 932)) END,
    seg.t0
FROM trip_base b
CROSS JOIN LATERAL (
    -- optional walking access leg
    SELECT 1 AS ord, b.trip_no * 10 + 1 AS k, 'walking' AS mode, b.ts AS t0,
           0.3 + synth.exp(b.trip_no * 10 + 1, 910, 0.4) AS dist, 4.8 AS speed,
           (0.3 + synth.exp(b.trip_no * 10 + 1, 910, 0.4)) / 4.8 * 60 AS minutes, 0.0 AS delay
    WHERE b.mode IN ('bus','rail') AND synth.u(b.trip_no, 911) < 0.15
    UNION ALL
    SELECT CASE WHEN b.mode IN ('bus','rail') AND synth.u(b.trip_no, 911) < 0.15 THEN 2 ELSE 1 END,
           b.trip_no * 10 + 2, b.mode,
           b.ts + CASE WHEN b.mode IN ('bus','rail') AND synth.u(b.trip_no, 911) < 0.15
                       THEN make_interval(secs => round((0.3 + synth.exp(b.trip_no * 10 + 1, 910, 0.4)) / 4.8 * 3600 + 120)) ELSE interval '0' END,
           d.dist, d.speed, d.dist / d.speed * 60,
           CASE WHEN b.mode IN ('bus','rail') THEN synth.exp(b.trip_no, 913, CASE WHEN b.is_peak THEN 6.0 ELSE 2.0 END) ELSE 0.0 END
    FROM (SELECT
            exp(ln(CASE b.mode WHEN 'walking' THEN 1.2 WHEN 'cycling' THEN 3.5 WHEN 'bus' THEN 6.0 WHEN 'rail' THEN 12.0
                               WHEN 'car' THEN 9.0 WHEN 'rideshare' THEN 7.0 WHEN 'scooter' THEN 2.0 ELSE 4.0 END)
                + 0.5 * synth.z(b.trip_no, 912)) AS dist,
            greatest(3.0, (CASE b.mode WHEN 'walking' THEN 4.8 WHEN 'cycling' THEN 15 WHEN 'bus' THEN 22 WHEN 'rail' THEN 38
                                       WHEN 'car' THEN 40 WHEN 'rideshare' THEN 36 WHEN 'scooter' THEN 14 ELSE 20 END)
                * CASE WHEN b.is_peak AND b.mode IN ('car','bus','rideshare') THEN 0.70 ELSE 1.0 END
                * exp(0.12 * synth.z(b.trip_no, 914))) AS speed) d
) seg
LEFT JOIN st_range r ON r.stype = CASE seg.mode WHEN 'bus' THEN 'bus' WHEN 'rail' THEN 'rail'
                                               WHEN 'cycling' THEN 'bike_share' WHEN 'scooter' THEN 'scooter' END
                    AND (seg.mode IN ('bus','rail','scooter') OR synth.u(seg.k, 924) < 0.5)
LEFT JOIN mobility.stations ss ON ss.station_id = r.lo + floor(synth.u(seg.k, 925) * r.n)::bigint
LEFT JOIN mobility.stations es ON es.station_id = r.lo + floor(synth.u(seg.k, 926) * r.n)::bigint
ORDER BY b.trip_no, seg.ord;

-- Trips still in progress at as_of are not yet recorded.
DELETE FROM mobility.trip_segments WHERE end_time > meta.as_of();

-- Sensors: hourly series with daily/weekly/annual structure and labelled anomalies.
CREATE TEMP TABLE sensors AS
SELECT row_number() OVER (ORDER BY t.tn, g.n) AS sid, t.stype, t.unit, t.prefix || '-' || lpad(g.n::text, 3, '0') AS code,
       s.y0 + 0.016 * synth.u(t.tn * 1000 + g.n, 1000) AS lat, s.x0 + 0.02 * synth.u(t.tn * 1000 + g.n, 1001) AS lng,
       s.name AS nb_name, 0.7 + 0.6 * synth.u(t.tn * 1000 + g.n, 1002) AS level
FROM (VALUES (1, 'traffic_counter', 'vehicles/hour', 'TRF', 16), (2, 'air_quality', 'AQI', 'AQI', 10),
             (3, 'noise', 'dB', 'NOI', 10), (4, 'speed', 'mph', 'SPD', 6), (5, 'weather', 'temperature_f', 'WTH', 6)) t(tn, stype, unit, prefix, cnt)
CROSS JOIN LATERAL generate_series(1, (t.cnt * greatest(1, :scale))::int) g(n)
JOIN nb_cdf_pop c ON synth.u(t.tn * 1000 + g.n, 1003) >= c.lo AND synth.u(t.tn * 1000 + g.n, 1003) < c.hi
JOIN nb_seed s ON s.nb = c.nb;

-- Level-shift windows: ~1 per sensor per 30 days, 6-24 h, +40%.
CREATE TEMP TABLE shift_windows AS
SELECT s.sid, meta.as_of() - make_interval(hours => floor(synth.u(s.sid * 100 + w, 1010) * 2160)::int) AS w_start,
       make_interval(hours => 6 + floor(synth.u(s.sid * 100 + w, 1011) * 18)::int) AS w_len
FROM sensors s CROSS JOIN generate_series(1, 3) w;

CREATE TEMP TABLE readings AS
SELECT s.sid, s.code, s.stype, s.unit, s.lat, s.lng, s.nb_name, ts,
       s.sid * 1000000 + (extract(epoch FROM ts)::bigint / 3600) % 1000000 AS k,
       -- weekday commute profile in [0,1]
       CASE WHEN extract(isodow FROM ts) <= 5
            THEN exp(-power((extract(hour FROM ts) - 8) / 1.5, 2)) + exp(-power((extract(hour FROM ts) - 17.5) / 1.8, 2))
            ELSE 0.6 * exp(-power((extract(hour FROM ts) - 14) / 4.0, 2)) END AS peak,
       extract(hour FROM ts) AS hr,
       extract(doy FROM ts) AS doy,
       s.level
FROM sensors s
CROSS JOIN generate_series(meta.as_of() - interval '90 days' + interval '1 second', meta.as_of(), interval '1 hour') ts;

ALTER TABLE readings ADD COLUMN v float8, ADD COLUMN anomaly text, ADD COLUMN q float8;
UPDATE readings SET v = CASE stype
        WHEN 'traffic_counter' THEN level * (120 + 680 * peak + 60 * sin(2 * pi() * (hr - 3) / 24)) * exp(0.08 * synth.z(k, 1020))
        WHEN 'air_quality'     THEN 38 + 10 * sin(2 * pi() * (hr - 15) / 24) + 8 * peak + 6 * sin(2 * pi() * doy / 7.0) + 3 * synth.z(k, 1020)
        WHEN 'noise'           THEN 48 + 14 * peak + 6 * sin(2 * pi() * (hr - 4) / 24) + 2 * synth.z(k, 1020)
        WHEN 'speed'           THEN 38 - 14 * peak + 2.5 * synth.z(k, 1020)
        WHEN 'weather'         THEN 66 + 16 * sin(2 * pi() * (doy - 110) / 365.25) + 9 * sin(2 * pi() * (hr - 9) / 24) + 2 * synth.z(k, 1020)
    END,
    q = 0.86 + 0.14 * synth.u(k, 1021);

UPDATE readings r SET v = v * 1.4, anomaly = 'level_shift'
FROM shift_windows w WHERE w.sid = r.sid AND r.ts >= w.w_start AND r.ts < w.w_start + w.w_len;
UPDATE readings SET v = v + 6 * CASE stype WHEN 'traffic_counter' THEN 0.25 * v + 40 WHEN 'weather' THEN 2 ELSE 4 END,
                    anomaly = 'spike'
WHERE anomaly IS NULL AND synth.u(k, 1022) < 0.004;
UPDATE readings SET v = 0, q = 0.25, anomaly = 'dropout'
WHERE anomaly IS NULL AND synth.u(k, 1023) < 0.002;
DELETE FROM readings WHERE anomaly IS NULL AND synth.u(k, 1024) < 0.003;   -- realistic gaps

INSERT INTO mobility.sensor_readings (sensor_code, sensor_type, latitude, longitude, location_description, reading_value,
                                      unit_of_measure, reading_time, data_quality_score, calibration_date,
                                      weather_conditions, special_events, raw_data)
SELECT code, stype::mobility.sensor_type, round(lat::numeric, 6), round(lng::numeric, 6), nb_name,
       round(greatest(v, 0)::numeric, 4), unit, ts, round(q::numeric, 2),
       (meta.as_of())::date - 120,
       CASE WHEN synth.u(sid * 10000 + doy::bigint, 1030) < 0.15 THEN 'rain' ELSE 'clear' END,
       NULL,
       jsonb_build_object('firmware', 'v2.' || (sid % 4), 'battery_pct', round((60 + 40 * synth.u(k, 1031))::numeric, 0))
FROM readings
ORDER BY ts, sid;

INSERT INTO meta.ground_truth (entity, entity_id, label, detail)
SELECT 'mobility.sensor_readings', sr.reading_id, r.anomaly, jsonb_build_object('sensor_code', r.code)
FROM readings r
JOIN mobility.sensor_readings sr ON sr.sensor_code = r.code AND sr.reading_time = r.ts
WHERE r.anomaly IS NOT NULL;

-- ===========================================================================
-- 6. Points of interest
-- ===========================================================================

INSERT INTO geo.points_of_interest (name, category, subcategory, phone, website, street_address, zip_code, location_geom,
                                    neighborhood_id, business_hours, services_offered, accessibility_features,
                                    average_rating, review_count, permit_required, inspection_required,
                                    last_inspection_date, is_active, attributes)
SELECT
    s.name || ' ' || initcap(replace(cat, '_', ' ')) || ' ' || i, cat::geo.poi_category, NULL,
    '(469) 555-' || lpad((i % 10000)::text, 4, '0'), NULL,
    (100 + floor(synth.u(i, 1102) * 9800))::int || ' Civic Ave',
    '75' || lpad((100 + s.nb)::text, 3, '0'),
    ST_SetSRID(ST_MakePoint(s.x0 + 0.02 * synth.u(i, 1103), s.y0 + 0.016 * synth.u(i, 1104)), 4326),
    s.nb,
    CASE WHEN cat IN ('hospital','emergency') THEN '{"mon-sun": "00:00-24:00"}'::jsonb
         ELSE '{"mon-fri": "08:00-18:00", "sat": "09:00-14:00"}'::jsonb END,
    ARRAY[cat || '_services'],
    CASE floor(synth.u(i, 1105) * 4)::int
         WHEN 0 THEN ARRAY['wheelchair_ramp','accessible_parking']
         WHEN 1 THEN ARRAY['elevator']
         WHEN 2 THEN ARRAY[]::text[]
         ELSE ARRAY['braille_signage','wheelchair_ramp'] END,
    round((1 + 4 * (synth.u(i, 1106) + synth.u(i, 1107) + synth.u(i, 1108)) / 3)::numeric, 2),
    floor(synth.exp(i, 1109, 60))::int,
    cat IN ('restaurant','retail','gas_station'),
    cat IN ('restaurant','hospital','school'),
    CASE WHEN cat IN ('restaurant','hospital','school') THEN (meta.as_of())::date - (synth.u(i, 1110) * 365)::int END,
    synth.u(i, 1111) < 0.96,
    jsonb_build_object('source', 'polaris-synthetic-v2')
FROM generate_series(1, 600) i
CROSS JOIN LATERAL (SELECT synth.pick(
    ARRAY['restaurant','retail','park','school','bank','gas_station','worship','government','library','community_center','hospital','emergency','transportation','utility','other'],
    ARRAY[120,110,60,45,35,30,40,20,12,18,6,14,30,20,40], synth.u(i, 1100)) AS cat) c
JOIN nb_cdf_pop cd ON synth.u(i, 1101) >= cd.lo AND synth.u(i, 1101) < cd.hi
JOIN nb_seed s ON s.nb = cd.nb
ORDER BY i;

-- ===========================================================================
-- 7. Documents: complaints with planted service-equity gradient, policies
-- ===========================================================================

CREATE TEMP TABLE hotspots AS
SELECT h, -96.86 + 0.12 * synth.u(h, 1200) AS hx, 32.948 + 0.064 * synth.u(h, 1201) AS hy,
       (ARRAY['roads','noise','trash','utilities','parking','graffiti','noise','roads'])[h] AS fav
FROM generate_series(1, 8) h;

CREATE TEMP TABLE cmp AS
SELECT i,
       CASE WHEN synth.u(i, 1210) < 0.6 THEN 1 + floor(synth.u(i, 1211) * 8)::int END AS hs
FROM generate_series(1, (5000 * :scale)::int) i;

ALTER TABLE cmp ADD COLUMN x float8, ADD COLUMN y float8, ADD COLUMN cat text;
UPDATE cmp c SET
    x = least(-96.7401, greatest(-96.8599, coalesce(h.hx + 0.003 * synth.z(c.i, 1212), -96.86 + 0.12 * synth.u(c.i, 1212)))),
    y = least(33.0119, greatest(32.9481, coalesce(h.hy + 0.003 * synth.z(c.i, 1213), 32.948 + 0.064 * synth.u(c.i, 1213)))),
    cat = CASE WHEN h.h IS NOT NULL AND synth.u(c.i, 1214) < 0.6 THEN h.fav
               ELSE synth.pick(ARRAY['roads','noise','utilities','trash','parking','graffiti','animals','other'],
                               ARRAY[24,20,14,14,10,8,5,5], synth.u(c.i, 1215)) END
FROM cmp c2 LEFT JOIN hotspots h ON h.h = c2.hs
WHERE c2.i = c.i;

INSERT INTO documents.complaint_records (
    reporter_citizen_id, complaint_number, subject, description, category, subcategory, priority_level,
    incident_address, incident_latitude, incident_longitude, neighborhood_id, status, assigned_to,
    incident_date, submitted_at, acknowledged_at, resolved_at, resolution_notes, resolution_actions, metadata, created_at, updated_at)
SELECT
    1 + floor(synth.u(c.i, 1220) * (10000 * :scale))::bigint,
    'CMP-' || to_char(sub_at, 'YYYY') || '-' || lpad(c.i::text, 6, '0'),
    t.subject, t.body, c.cat, t.sub, pr::documents.priority_level,
    (100 + floor(synth.u(c.i, 1221) * 9800))::int || ' ' || (ARRAY['Main','Oak','Elm','Cedar','Park'])[1 + floor(synth.u(c.i, 1222) * 5)::int] || ' St',
    round(c.y::numeric, 6), round(c.x::numeric, 6), n.neighborhood_id,
    st::documents.document_status,
    CASE WHEN st <> 'submitted' THEN (ARRAY['Public Works','Code Enforcement','Utilities Dept','Sanitation','Parking Authority','Animal Services'])[1 + floor(synth.u(c.i, 1223) * 6)::int] END,
    sub_at - make_interval(hours => floor(synth.exp(c.i, 1224, 18))::int),
    sub_at,
    CASE WHEN st <> 'submitted' THEN sub_at + make_interval(secs => synth.exp(c.i, 1225, 6) * 3600) END,
    CASE WHEN st IN ('resolved','archived') THEN sub_at + make_interval(secs => res_days * 86400) END,
    CASE WHEN st IN ('resolved','archived') THEN 'Resolved: ' || t.fix END,
    CASE WHEN st IN ('resolved','archived') THEN jsonb_build_array(jsonb_build_object('action', t.fix, 'crew_size', 1 + floor(synth.u(c.i, 1226) * 4))) END,
    t.meta,
    sub_at, sub_at
FROM cmp c
JOIN geo.neighborhood_boundaries n ON ST_Intersects(n.boundary_geom, ST_SetSRID(ST_MakePoint(c.x, c.y), 4326))
JOIN nb_seed s ON s.nb = n.neighborhood_id
CROSS JOIN LATERAL (SELECT meta.as_of() - make_interval(secs => synth.u(c.i, 1230) * 365 * 86400) AS sub_at) a
CROSS JOIN LATERAL (
    SELECT
        -- base median days by category, x exp(-0.25 * income_z) planted gradient, lognormal sigma 0.6
        (CASE c.cat WHEN 'roads' THEN 9 WHEN 'utilities' THEN 3 WHEN 'trash' THEN 2 WHEN 'noise' THEN 4
                    WHEN 'parking' THEN 2 WHEN 'graffiti' THEN 6 WHEN 'animals' THEN 1.5 ELSE 5 END)
        * exp(-0.25 * s.income_z + 0.6 * synth.z(c.i, 1231)) AS res_days,
        synth.pick(ARRAY['low','normal','high','urgent'], ARRAY[20,50,22,8], synth.u(c.i, 1232)) AS pr
) r
CROSS JOIN LATERAL (
    SELECT CASE WHEN sub_at + make_interval(secs => r.res_days * 86400) > meta.as_of()
                THEN synth.pick(ARRAY['submitted','under_review'], ARRAY[3,7], synth.u(c.i, 1233))
                WHEN synth.u(c.i, 1234) < 0.04 THEN 'rejected'
                WHEN sub_at < meta.as_of() - interval '300 days' THEN 'archived'
                ELSE 'resolved' END AS st
) z
CROSS JOIN LATERAL (
    SELECT
        CASE c.cat
          WHEN 'roads'     THEN (ARRAY['Pothole','Damaged pavement','Missing road sign','Faded crosswalk'])[1 + floor(synth.u(c.i, 1240) * 4)::int]
          WHEN 'noise'     THEN (ARRAY['Loud construction','Late-night party','Barking dog','Leaf blower before 7am'])[1 + floor(synth.u(c.i, 1240) * 4)::int]
          WHEN 'utilities' THEN (ARRAY['Streetlight out','Water main leak','Power outage','Low water pressure'])[1 + floor(synth.u(c.i, 1240) * 4)::int]
          WHEN 'trash'     THEN (ARRAY['Missed pickup','Illegal dumping','Overflowing bin','Recycling not collected'])[1 + floor(synth.u(c.i, 1240) * 4)::int]
          WHEN 'parking'   THEN (ARRAY['Blocked driveway','Abandoned vehicle','Parking in fire lane'])[1 + floor(synth.u(c.i, 1240) * 3)::int]
          WHEN 'graffiti'  THEN (ARRAY['Graffiti on wall','Vandalized bus shelter','Tagged traffic box'])[1 + floor(synth.u(c.i, 1240) * 3)::int]
          WHEN 'animals'   THEN (ARRAY['Stray dog','Dead animal on road','Wildlife in yard'])[1 + floor(synth.u(c.i, 1240) * 3)::int]
          ELSE 'General service request' END AS sub,
        CASE c.cat WHEN 'roads' THEN 'replaced asphalt patch' WHEN 'noise' THEN 'issued warning notice'
                   WHEN 'utilities' THEN 'crew repaired fixture' WHEN 'trash' THEN 'collection completed'
                   WHEN 'parking' THEN 'vehicle cited or towed' WHEN 'graffiti' THEN 'surface cleaned'
                   WHEN 'animals' THEN 'animal services responded' ELSE 'request closed' END AS fix
) sx
CROSS JOIN LATERAL (
    SELECT
        sx.sub || ' near ' || s.name AS subject,
        sx.sub || ' reported by resident in ' || s.name || '. '
          || (ARRAY['Issue has persisted for several days.','This is a safety hazard for pedestrians.',
                    'Neighbors have also noticed the problem.','Please send a crew as soon as possible.',
                    'Problem gets worse during rush hour.','Children walk past this location to school.'])[1 + floor(synth.u(c.i, 1241) * 6)::int]
          AS body,
        sx.sub,
        sx.fix,
        CASE c.cat
          WHEN 'noise' THEN jsonb_build_object('category', 'noise', 'decibel_level', round((65 + 20 * synth.u(c.i, 1242))::numeric), 'time_of_day', lpad(floor(synth.u(c.i, 1243) * 24)::text, 2, '0') || ':00')
          WHEN 'utilities' THEN jsonb_build_object('category', 'utilities', 'utility_type', (ARRAY['lighting','water','power'])[1 + floor(synth.u(c.i, 1242) * 3)::int], 'outage_duration', floor(synth.exp(c.i, 1243, 30)) || 'h')
          WHEN 'roads' THEN jsonb_build_object('category', 'roads', 'road_condition', (ARRAY['poor','very_poor','hazardous'])[1 + floor(synth.u(c.i, 1242) * 3)::int], 'hazard_type', lower(sx.sub))
          ELSE jsonb_build_object('category', c.cat, 'channel', (ARRAY['app','phone','web','email'])[1 + floor(synth.u(c.i, 1242) * 4)::int])
        END AS meta
) t
ORDER BY c.i;

-- Acknowledgements that would happen after as_of have not happened yet.
UPDATE documents.complaint_records
SET acknowledged_at = NULL, assigned_to = NULL, status = 'submitted'
WHERE acknowledged_at > meta.as_of();

INSERT INTO documents.policy_documents (
    policy_number, title, version, document_content, document_type, department, policy_area, access_level, status,
    effective_date, expiration_date, review_date, created_by, approved_by, change_log, tags, keywords, metadata)
SELECT
    'POL-' || d.code || '-' || lpad(i::text, 4, '0'), title, '1.0',
    jsonb_build_object('title', title, 'summary', 'Policy governing ' || lower(topic) || ' for the ' || d.dept || ' department.',
        'sections', jsonb_build_array(
            jsonb_build_object('heading', 'Purpose', 'body', 'This policy establishes standards for ' || lower(topic) || ' in Polaris City.'),
            jsonb_build_object('heading', 'Scope', 'body', 'Applies to all ' || d.dept || ' staff, contractors and residents affected by ' || lower(topic) || '.'),
            jsonb_build_object('heading', 'Requirements', 'body', 'Requests must be acknowledged within ' || (1 + i % 5) || ' business days and resolved according to priority.'),
            jsonb_build_object('heading', 'Enforcement', 'body', 'Violations may result in fines, permit suspension or corrective action plans.'))),
    dt::documents.document_type, d.dept, topic,
    synth.pick(ARRAY['public','internal','restricted','confidential'], ARRAY[60,25,10,5], synth.u(i, 1302))::documents.access_level,
    synth.pick(ARRAY['published','approved','draft','under_review','archived'], ARRAY[60,10,10,10,10], synth.u(i, 1303))::documents.document_status,
    eff, eff + 3 * 365, eff + 365,
    1 + floor(synth.u(i, 1304) * (10000 * :scale))::int, 1 + floor(synth.u(i, 1305) * (10000 * :scale))::int,
    jsonb_build_array(jsonb_build_object('version', '1.0', 'date', eff, 'note', 'initial adoption')),
    ARRAY[lower(d.code), lower(replace(topic, ' ', '_'))],
    string_to_array(lower(topic), ' '),
    jsonb_build_object('pages', 2 + i % 9, 'language', 'en')
FROM generate_series(1, 120) i
CROSS JOIN LATERAL (SELECT (ARRAY['PW','TR','HL','PL','FN','PS'])[1 + i % 6] AS code,
                           (ARRAY['Public Works','Transportation','Health','Planning','Finance','Public Safety'])[1 + i % 6] AS dept) d
CROSS JOIN LATERAL (SELECT (ARRAY['Street Maintenance','Noise Control','Waste Collection','Water Quality','Zoning Variance',
                                  'Transit Accessibility','Data Privacy','Emergency Response','Procurement','Food Safety',
                                  'Bicycle Infrastructure','Public Records'])[1 + floor(synth.u(i, 1300) * 12)::int] AS topic) tp
CROSS JOIN LATERAL (SELECT tp.topic || ' Policy ' || i AS title,
                           synth.pick(ARRAY['policy','notice','report','form'], ARRAY[70,10,15,5], synth.u(i, 1301)) AS dt,
                           (meta.as_of())::date - (synth.u(i, 1306) * 2000)::int AS eff) x
ORDER BY i;

-- Version 2.0 of 20% of policies, superseding v1.0.
INSERT INTO documents.policy_documents (
    policy_number, title, version, document_content, document_type, department, policy_area, access_level, status,
    effective_date, expiration_date, review_date, created_by, approved_by, supersedes_policy_id, change_log, tags, keywords, metadata)
SELECT policy_number, title, '2.0',
       jsonb_set(document_content, '{summary}', to_jsonb('Revised: ' || (document_content->>'summary'))),
       document_type, department, policy_area, access_level, 'published',
       effective_date + 365, effective_date + 4 * 365, effective_date + 2 * 365, created_by, approved_by, policy_id,
       change_log || jsonb_build_array(jsonb_build_object('version', '2.0', 'date', effective_date + 365, 'note', 'periodic revision')),
       tags, keywords, metadata
FROM documents.policy_documents
WHERE synth.u(policy_id, 1310) < 0.2 AND effective_date + 365 <= (meta.as_of())::date
ORDER BY policy_id;
UPDATE documents.policy_documents p SET status = 'archived'
WHERE EXISTS (SELECT 1 FROM documents.policy_documents n WHERE n.supersedes_policy_id = p.policy_id);

-- ===========================================================================
-- 8. Finalise: statistics and provenance
-- ===========================================================================

ANALYZE civics.citizens, civics.permit_applications, civics.tax_payments, civics.voting_records,
        commerce.merchants, commerce.business_licenses, commerce.orders, commerce.order_items, commerce.payments,
        mobility.stations, mobility.station_inventory, mobility.trip_segments, mobility.sensor_readings,
        geo.neighborhood_boundaries, geo.points_of_interest, geo.road_segments,
        documents.complaint_records, documents.policy_documents, meta.ground_truth;

UPDATE meta.dataset SET
    generation_ms = round(extract(epoch FROM clock_timestamp() - generated_at) * 1000),
    row_counts = (
        SELECT jsonb_object_agg(t, n ORDER BY t) FROM (
            SELECT 'civics.citizens' t, count(*) n FROM civics.citizens UNION ALL
            SELECT 'civics.permit_applications', count(*) FROM civics.permit_applications UNION ALL
            SELECT 'civics.tax_payments', count(*) FROM civics.tax_payments UNION ALL
            SELECT 'civics.voting_records', count(*) FROM civics.voting_records UNION ALL
            SELECT 'commerce.merchants', count(*) FROM commerce.merchants UNION ALL
            SELECT 'commerce.business_licenses', count(*) FROM commerce.business_licenses UNION ALL
            SELECT 'commerce.orders', count(*) FROM commerce.orders UNION ALL
            SELECT 'commerce.order_items', count(*) FROM commerce.order_items UNION ALL
            SELECT 'commerce.payments', count(*) FROM commerce.payments UNION ALL
            SELECT 'mobility.stations', count(*) FROM mobility.stations UNION ALL
            SELECT 'mobility.station_inventory', count(*) FROM mobility.station_inventory UNION ALL
            SELECT 'mobility.trip_segments', count(*) FROM mobility.trip_segments UNION ALL
            SELECT 'mobility.sensor_readings', count(*) FROM mobility.sensor_readings UNION ALL
            SELECT 'geo.neighborhood_boundaries', count(*) FROM geo.neighborhood_boundaries UNION ALL
            SELECT 'geo.points_of_interest', count(*) FROM geo.points_of_interest UNION ALL
            SELECT 'geo.road_segments', count(*) FROM geo.road_segments UNION ALL
            SELECT 'documents.complaint_records', count(*) FROM documents.complaint_records UNION ALL
            SELECT 'documents.policy_documents', count(*) FROM documents.policy_documents UNION ALL
            SELECT 'meta.ground_truth', count(*) FROM meta.ground_truth) x);

RESET client_min_messages;
SELECT generator_version, scale, seed, as_of, generation_ms, jsonb_pretty(row_counts) AS row_counts FROM meta.dataset;
