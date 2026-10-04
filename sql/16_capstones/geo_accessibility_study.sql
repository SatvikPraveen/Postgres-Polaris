-- =============================================================================
-- File: sql/16_capstones/geo_accessibility_study.sql
-- Capstone: a "15-minute city" accessibility and equity study with PostGIS
-- =============================================================================
-- Research question
--   What share of each neighbourhood's residents can WALK to the essentials
--   (school, hospital, park, library, transit) and is access fair, i.e. does it
--   depend on neighbourhood income?
--
-- What this capstone teaches
--   * geography vs geometry: distances in metres on the spheroid with ::geography.
--     (Never ST_Transform to 3857 to measure: Web Mercator inflates lengths by
--     1/cos(latitude), ~19% at Polaris City's 33 degrees N.)
--   * KNN nearest-neighbour search with ORDER BY geog <-> geog LIMIT 1 inside
--     LATERAL, served by a GiST index on a geography column.
--   * ST_DWithin(geography, geography, metres) for "cumulative opportunities"
--     counts, also index-assisted.
--   * Point-in-polygon assignment (ST_Contains) and a consistency check against
--     the zip-code encoding.
--   * Straight-line vs grid-network (Manhattan) walking distance.
--   * Equity statistics: corr(), regr_slope(), regr_r2(), Spearman via ranks,
--     and a population-weighted concentration curve.
--   * A what-if: transit access before vs after recent station openings.
--
-- Inputs (base, read only): civics.citizens.home_geom, geo.points_of_interest,
-- mobility.stations, geo.neighborhood_boundaries. Everything this file creates
-- lives in schema accessibility and is rebuilt idempotently.
-- =============================================================================

\echo '== 0. Schema and study parameters'
CREATE SCHEMA IF NOT EXISTS accessibility;
COMMENT ON SCHEMA accessibility IS 'Capstone 16: 15-minute-city walking accessibility and equity study.';

-- Essential categories, their weight in the index and a category-specific
-- "acceptable walk". 1200 m ~ 15 minutes at 4.8 km/h; 800 m ~ 10 minutes
-- (the classic transit walk-shed). Hospitals are rare, so 2 km is used there.
CREATE TABLE IF NOT EXISTS accessibility.essential_categories (
    category        text PRIMARY KEY,
    weight          numeric NOT NULL CHECK (weight > 0),
    target_walk_m   integer NOT NULL CHECK (target_walk_m > 0),
    source          text NOT NULL
);
INSERT INTO accessibility.essential_categories VALUES
    ('school',   0.25,  800, 'geo.points_of_interest'),
    ('park',     0.20,  800, 'geo.points_of_interest'),
    ('library',  0.15, 1200, 'geo.points_of_interest'),
    ('hospital', 0.15, 2000, 'geo.points_of_interest'),
    ('transit',  0.25,  800, 'mobility.stations (bus, rail)')
ON CONFLICT (category) DO UPDATE
    SET weight = EXCLUDED.weight, target_walk_m = EXCLUDED.target_walk_m, source = EXCLUDED.source;

-- -----------------------------------------------------------------------------
-- 1. Destinations: one table, geography column, GiST index
-- -----------------------------------------------------------------------------
-- Teaches: harmonise heterogeneous sources (POIs have geometry, stations have
-- numeric lat/lon) into one geography column; index it so <-> and ST_DWithin
-- can use it. Stations: ST_MakePoint takes (x = longitude, y = latitude).
\echo '== 1. Destinations'
DROP TABLE IF EXISTS accessibility.destinations CASCADE;
CREATE TABLE accessibility.destinations (
    dest_id        text PRIMARY KEY,
    category       text NOT NULL REFERENCES accessibility.essential_categories(category),
    name           text NOT NULL,
    opened_on      date,
    geog           geography(Point, 4326) NOT NULL
);
INSERT INTO accessibility.destinations (dest_id, category, name, opened_on, geog)
SELECT 'poi:' || p.poi_id, p.category::text, p.name, p.created_at::date, p.location_geom::geography
FROM geo.points_of_interest p
WHERE p.is_active AND p.category::text IN ('school', 'park', 'library', 'hospital')
UNION ALL
SELECT 'stn:' || s.station_id, 'transit', s.station_name, s.installation_date,
       ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography
FROM mobility.stations s
WHERE s.station_type IN ('bus', 'rail') AND s.status = 'active';
CREATE INDEX destinations_geog_gix ON accessibility.destinations USING gist (geog);
CREATE INDEX destinations_category_idx ON accessibility.destinations (category);
ANALYZE accessibility.destinations;

SELECT category, count(*) AS destinations FROM accessibility.destinations GROUP BY category ORDER BY category;

-- -----------------------------------------------------------------------------
-- 2. Residents: geography + neighbourhood by point-in-polygon
-- -----------------------------------------------------------------------------
-- Teaches: spatial join with ST_Contains (geometry, uses the boundary GiST
-- index), then a data-quality cross-check: zip '751NN' encodes neighbourhood NN.
\echo '== 2. Residents assigned to neighbourhoods'
DROP TABLE IF EXISTS accessibility.residents CASCADE;
CREATE TABLE accessibility.residents AS
SELECT c.citizen_id, n.neighborhood_id, c.home_geom::geography AS geog, c.home_geom
FROM civics.citizens c
JOIN geo.neighborhood_boundaries n ON ST_Contains(n.boundary_geom, c.home_geom)
WHERE c.status = 'active' AND c.home_geom IS NOT NULL;
ALTER TABLE accessibility.residents ADD PRIMARY KEY (citizen_id);
CREATE INDEX residents_geog_gix ON accessibility.residents USING gist (geog);
ANALYZE accessibility.residents;

SELECT count(*) AS active_residents,
       count(*) FILTER (WHERE substr(c.zip_code, 4, 2)::int <> r.neighborhood_id) AS zip_polygon_mismatches
FROM accessibility.residents r JOIN civics.citizens c USING (citizen_id);

-- -----------------------------------------------------------------------------
-- 3. Nearest essential of each category for every resident (KNN)
-- -----------------------------------------------------------------------------
-- Teaches: the KNN idiom. ORDER BY d.geog <-> r.geog LIMIT 1 walks the GiST
-- index nearest-first; for geography, <-> is the true sphere distance, so the
-- ordering is correct (geometry <-> in degrees would favour north-south
-- neighbours at this latitude). We then compute the exact spheroid distance
-- with ST_Distance and a grid-network (Manhattan) approximation: the street
-- network is a regular grid, so a walker covers |dx| + |dy|.
\echo '== 3. Nearest-destination distances (10k residents x 5 categories)'
EXPLAIN (COSTS OFF)
SELECT d.dest_id
FROM accessibility.destinations d
WHERE d.category = 'library'
ORDER BY d.geog <-> (SELECT geog FROM accessibility.residents ORDER BY citizen_id LIMIT 1)
LIMIT 1;

DROP TABLE IF EXISTS accessibility.resident_nearest CASCADE;
CREATE TABLE accessibility.resident_nearest AS
SELECT r.citizen_id, r.neighborhood_id, e.category, nn.dest_id,
       ST_Distance(r.geog, nn.geog)                                           AS crow_m,
       -- Manhattan on the spheroid: east-west leg + north-south leg
       ST_Distance(r.geog, ST_SetSRID(ST_MakePoint(ST_X(nn.geog::geometry), ST_Y(r.home_geom)), 4326)::geography)
     + ST_Distance(r.geog, ST_SetSRID(ST_MakePoint(ST_X(r.home_geom), ST_Y(nn.geog::geometry)), 4326)::geography)
                                                                              AS grid_m
FROM accessibility.residents r
CROSS JOIN accessibility.essential_categories e
CROSS JOIN LATERAL (
    SELECT d.dest_id, d.geog
    FROM accessibility.destinations d
    WHERE d.category = e.category
    ORDER BY d.geog <-> r.geog
    LIMIT 1
) nn;
ALTER TABLE accessibility.resident_nearest ADD PRIMARY KEY (citizen_id, category);
ANALYZE accessibility.resident_nearest;

-- City-wide distribution of nearest distances, and the network detour factor.
SELECT category,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY crow_m)::numeric)  AS median_crow_m,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY crow_m)::numeric)  AS p90_crow_m,
       round(avg(grid_m / nullif(crow_m, 0))::numeric, 2)                   AS mean_detour_factor,
       round(avg((crow_m <= 800)::int)::numeric, 3)                          AS share_800m,
       round(avg((crow_m <= 1200)::int)::numeric, 3)                         AS share_1200m,
       round(avg((grid_m <= 1200)::int)::numeric, 3)                         AS share_1200m_grid
FROM accessibility.resident_nearest
GROUP BY category
ORDER BY category;

-- -----------------------------------------------------------------------------
-- 4. Neighbourhood accessibility table and the index
-- -----------------------------------------------------------------------------
-- Teaches: conditional aggregation into a wide, analysis-ready table.
--   share_<cat>_800 / _1200 : share of residents within 800 / 1200 m (geodesic)
--   access_index            : weighted mean over categories of the share within
--                             the category's target walk (0..100)
--   share_15min_all         : share of residents reaching ALL five essentials
--                             within 1200 m: the strict "15-minute city" test.
\echo '== 4. Neighbourhood accessibility'
CREATE OR REPLACE VIEW accessibility.neighborhood_access AS
WITH per_resident AS (
    SELECT rn.citizen_id, rn.neighborhood_id,
           sum(e.weight * (rn.crow_m <= e.target_walk_m)::int) / sum(e.weight)  AS resident_score,
           bool_and(rn.crow_m <= 1200)                                         AS all_within_1200,
           max(rn.crow_m) FILTER (WHERE rn.category = 'school')                AS d_school,
           max(rn.crow_m) FILTER (WHERE rn.category = 'park')                  AS d_park,
           max(rn.crow_m) FILTER (WHERE rn.category = 'library')               AS d_library,
           max(rn.crow_m) FILTER (WHERE rn.category = 'hospital')              AS d_hospital,
           max(rn.crow_m) FILTER (WHERE rn.category = 'transit')               AS d_transit
    FROM accessibility.resident_nearest rn
    JOIN accessibility.essential_categories e USING (category)
    GROUP BY rn.citizen_id, rn.neighborhood_id
)
SELECT n.neighborhood_id, n.neighborhood_name, n.median_income,
       count(*)                                               AS residents,
       round(avg((d_school   <=  800)::int), 3)               AS share_school_800,
       round(avg((d_school   <= 1200)::int), 3)               AS share_school_1200,
       round(avg((d_park     <=  800)::int), 3)               AS share_park_800,
       round(avg((d_park     <= 1200)::int), 3)               AS share_park_1200,
       round(avg((d_library  <=  800)::int), 3)               AS share_library_800,
       round(avg((d_library  <= 1200)::int), 3)               AS share_library_1200,
       round(avg((d_hospital <=  800)::int), 3)               AS share_hospital_800,
       round(avg((d_hospital <= 1200)::int), 3)               AS share_hospital_1200,
       round(avg((d_transit  <=  800)::int), 3)               AS share_transit_800,
       round(avg((d_transit  <= 1200)::int), 3)               AS share_transit_1200,
       round(100 * avg(resident_score), 1)                    AS access_index,
       round(avg(all_within_1200::int), 3)                    AS share_15min_all
FROM per_resident p
JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
GROUP BY n.neighborhood_id, n.neighborhood_name, n.median_income;

SELECT neighborhood_name, residents, round(median_income) AS median_income,
       share_school_800 AS school_800, share_park_800 AS park_800, share_library_1200 AS library_1200,
       share_hospital_1200 AS hosp_1200, share_transit_800 AS transit_800,
       access_index, share_15min_all
FROM accessibility.neighborhood_access
ORDER BY access_index DESC, neighborhood_name
LIMIT 24;

-- Cumulative opportunities: how MANY essentials are within 800 m (not just the
-- nearest). ST_DWithin on geography is index-assisted and exact in metres.
\echo '== 4b. Cumulative opportunities within 800 m (mean count per resident)'
SELECT n.neighborhood_name,
       round(avg(o.n_school), 2)  AS schools, round(avg(o.n_park), 2) AS parks,
       round(avg(o.n_transit), 2) AS transit_stops
FROM accessibility.residents r
JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
CROSS JOIN LATERAL (
    SELECT count(*) FILTER (WHERE d.category = 'school')  AS n_school,
           count(*) FILTER (WHERE d.category = 'park')    AS n_park,
           count(*) FILTER (WHERE d.category = 'transit') AS n_transit
    FROM accessibility.destinations d
    WHERE ST_DWithin(d.geog, r.geog, 800)
) o
GROUP BY n.neighborhood_name
ORDER BY avg(o.n_transit) DESC, n.neighborhood_name
LIMIT 6;

-- -----------------------------------------------------------------------------
-- 5. Equity analysis: is access correlated with income?
-- -----------------------------------------------------------------------------
-- Teaches: statistical aggregates on the neighbourhood table.
--   corr(y, x)          Pearson correlation
--   regr_slope(y, x)    OLS slope of the access metric on income_z (standardised
--                       ln(median_income)): change per +1 SD of income
--   regr_r2(y, x)       share of variance explained
--   Spearman rho        = Pearson correlation of ranks (robust to outliers)
-- With only 24 neighbourhoods, report n and treat |r| < 0.4 as weak evidence
-- (the 5% critical value of r for n = 24 is about 0.40).
-- Ground truth: the generator places POIs and stations by neighbourhood
-- density / commercial intensity, NOT by income (meta.planted_effects has no
-- access-income effect). Correlations near zero are therefore the correct,
-- verifiable answer here: a study must be able to report a null result.
-- Note how the quintile table below is non-monotonic: big neighbourhoods
-- dominate their quintile, which is why the weighting choice must be stated.
\echo '== 5. Equity: access vs neighbourhood income'
CREATE OR REPLACE VIEW accessibility.equity_stats AS
WITH na AS (
    SELECT a.*,
           (ln(a.median_income) - avg(ln(a.median_income)) OVER ()) / stddev_pop(ln(a.median_income)) OVER () AS income_z,
           rank() OVER (ORDER BY a.median_income) AS r_income
    FROM accessibility.neighborhood_access a
),
metrics AS (
    SELECT m.metric, m.y, na.income_z, na.r_income, na.residents,
           rank() OVER (PARTITION BY m.metric ORDER BY m.y) AS r_y
    FROM na
    CROSS JOIN LATERAL (VALUES
        ('access_index',      na.access_index::float8),
        ('share_15min_all',   na.share_15min_all::float8),
        ('share_transit_800', na.share_transit_800::float8),
        ('share_park_800',    na.share_park_800::float8),
        ('share_school_800',  na.share_school_800::float8),
        ('share_hospital_1200', na.share_hospital_1200::float8)
    ) m(metric, y)
)
SELECT metric, count(*) AS n_neighborhoods,
       round(corr(y, income_z)::numeric, 3)        AS pearson_r,
       round(corr(r_y, r_income)::numeric, 3)      AS spearman_rho,
       round(regr_slope(y, income_z)::numeric, 4)  AS slope_per_income_sd,
       round(regr_r2(y, income_z)::numeric, 3)     AS r2
FROM metrics
GROUP BY metric;

SELECT * FROM accessibility.equity_stats ORDER BY metric;

-- Resident-level view of the same question: income-quintile (of the home
-- neighbourhood) vs mean access. Population weighting matters: a small rich
-- neighbourhood should not count as much as a large poor one.
\echo '== 5b. Access by neighbourhood-income quintile (population weighted)'
WITH res AS (
    SELECT rn.citizen_id, n.median_income,
           sum(e.weight * (rn.crow_m <= e.target_walk_m)::int) / sum(e.weight) AS score
    FROM accessibility.resident_nearest rn
    JOIN accessibility.essential_categories e USING (category)
    JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
    GROUP BY rn.citizen_id, n.median_income
)
SELECT q AS income_quintile, count(*) AS residents,
       round(min(median_income)) AS min_income, round(max(median_income)) AS max_income,
       round(100 * avg(score), 1) AS mean_access_index
FROM (SELECT res.*, ntile(5) OVER (ORDER BY median_income, citizen_id) AS q FROM res) x
GROUP BY q
ORDER BY q;

-- Concentration index (health-economics style): 2 * cov(score, fractional
-- income rank) / mean(score). > 0 means access concentrated among the richer.
WITH res AS (
    SELECT rn.citizen_id, n.median_income,
           sum(e.weight * (rn.crow_m <= e.target_walk_m)::int) / sum(e.weight) AS score
    FROM accessibility.resident_nearest rn
    JOIN accessibility.essential_categories e USING (category)
    JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
    GROUP BY rn.citizen_id, n.median_income
),
ranked AS (
    SELECT score, (cume_dist() OVER (ORDER BY median_income) - 0.5 / count(*) OVER ()) AS frac_rank
    FROM res
)
SELECT round((2 * covar_pop(score, frac_rank) / avg(score))::numeric, 4) AS concentration_index
FROM ranked;

-- -----------------------------------------------------------------------------
-- 6. Gap analysis: where would a new transit stop help most?
-- -----------------------------------------------------------------------------
-- Teaches: aggregate geometry (ST_Collect + ST_Centroid) of the underserved
-- residents as a naive siting heuristic, and a before/after evaluation of the
-- candidate with ST_DWithin.
\echo '== 6. Transit gap: residents > 800 m from a stop, candidate site per neighbourhood'
WITH unserved AS (
    SELECT r.neighborhood_id, r.citizen_id, r.home_geom
    FROM accessibility.resident_nearest rn
    JOIN accessibility.residents r USING (citizen_id)
    WHERE rn.category = 'transit' AND rn.crow_m > 800
),
cand AS (
    SELECT neighborhood_id, count(*) AS unserved_residents,
           ST_Centroid(ST_Collect(home_geom)) AS site
    FROM unserved GROUP BY neighborhood_id
)
SELECT n.neighborhood_name, c.unserved_residents,
       round(ST_Y(c.site)::numeric, 5) AS cand_lat, round(ST_X(c.site)::numeric, 5) AS cand_lon,
       (SELECT count(*) FROM unserved u
         WHERE u.neighborhood_id = c.neighborhood_id
           AND ST_DWithin(u.home_geom::geography, c.site::geography, 800)) AS newly_served
FROM cand c
JOIN geo.neighborhood_boundaries n USING (neighborhood_id)
ORDER BY c.unserved_residents DESC, n.neighborhood_name
LIMIT 5;

-- -----------------------------------------------------------------------------
-- 7. Change over time: transit access before the last two years of openings
-- -----------------------------------------------------------------------------
-- Teaches: time-travel on attribute dates. Re-run the KNN with only stations
-- installed before meta.as_of() - 2 years and compare walk-shed coverage.
\echo '== 7. Transit access then (stations open 2 years before as_of) vs now'
WITH then_nn AS (
    SELECT r.citizen_id, r.neighborhood_id,
           (SELECT ST_Distance(d.geog, r.geog)
              FROM accessibility.destinations d
             WHERE d.category = 'transit'
               AND d.opened_on <= (meta.as_of() - interval '2 years')::date
             ORDER BY d.geog <-> r.geog LIMIT 1) AS then_m
    FROM accessibility.residents r
)
SELECT n.neighborhood_name,
       round(avg((t.then_m <= 800)::int), 3)   AS share_800_then,
       round(avg((rn.crow_m <= 800)::int), 3)  AS share_800_now,
       round(avg((rn.crow_m <= 800)::int) - avg((t.then_m <= 800)::int), 3) AS gain
FROM then_nn t
JOIN accessibility.resident_nearest rn ON rn.citizen_id = t.citizen_id AND rn.category = 'transit'
JOIN geo.neighborhood_boundaries n ON n.neighborhood_id = t.neighborhood_id
GROUP BY n.neighborhood_name
ORDER BY gain DESC, n.neighborhood_name
LIMIT 5;
