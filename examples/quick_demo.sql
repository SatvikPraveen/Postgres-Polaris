-- Location: /examples/quick_demo.sql
-- =============================================================================
-- PostgreSQL Polaris - a 5-minute tour
-- =============================================================================
-- One synthetic city ("Polaris City"), five domains, one reproducible dataset.
-- This tour shows:
--   0. where the data comes from (meta.dataset: generator, scale, seed, as_of)
--   1. one query per domain: civics, commerce, mobility, geo, documents
--   2. a window function (monthly revenue, running total, month-over-month)
--   3. a spatial join (complaints per km² per neighbourhood, geodesic area)
--   4. full-text search with ranking and highlighted snippets
--   5. recovering a planted effect: the generator made peak-hour transit
--      delays 3x longer - can SQL find that number again?
--
-- Read-only. Every "recent" window is anchored on meta.as_of() (the dataset's
-- "now", 2025-12-31 23:59:59 UTC), never on now(): the data ends there.
-- Run: psql -X -v ON_ERROR_STOP=1 -d <db> -f /examples/quick_demo.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset null '-'

\echo ''
\echo '=== 0. Provenance: which dataset am I looking at? ==='
-- Same scale + seed => the same rows, byte for byte (see meta.fingerprint()).
SELECT generator_version, scale, seed, as_of, server_version
FROM meta.dataset;

SELECT key AS table_name, value::bigint AS row_count
FROM meta.dataset, jsonb_each_text(row_counts)
ORDER BY value::bigint DESC, key
LIMIT 8;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== 1a. Civics: permit outcomes by type (FILTER clause for conditional counts) ==='
SELECT permit_type,
       count(*)                                         AS applications,
       count(*) FILTER (WHERE status = 'approved')      AS approved,
       count(*) FILTER (WHERE status = 'denied')        AS denied,
       round(100.0 * count(*) FILTER (WHERE status = 'denied') / count(*), 1) AS denial_pct,
       round(avg(fee_amount), 2)                        AS avg_fee
FROM civics.permit_applications
GROUP BY permit_type
ORDER BY applications DESC, permit_type;

\echo ''
\echo '=== 1b. Commerce: last 30 days of revenue by business type ==='
SELECT m.business_type,
       count(*)                     AS orders,
       sum(o.total_amount)          AS revenue,
       round(avg(o.total_amount), 2) AS avg_ticket
FROM commerce.orders o
JOIN commerce.merchants m USING (merchant_id)
WHERE o.order_date >  meta.as_of() - interval '30 days'
  AND o.status NOT IN ('cancelled', 'refunded')
GROUP BY m.business_type
ORDER BY revenue DESC;

\echo ''
\echo '=== 1c. Mobility: last 7 days of trips by mode ==='
SELECT trip_mode,
       count(*)                          AS trips,
       round(avg(distance_km), 2)        AS avg_km,
       round(avg(duration_minutes), 1)   AS avg_min,
       round(avg(delay_minutes), 2)      AS avg_delay_min
FROM mobility.trip_segments
WHERE start_time > meta.as_of() - interval '7 days'
GROUP BY trip_mode
ORDER BY trips DESC;

\echo ''
\echo '=== 1d. Geo: the road network (helper function geo.road_network_stats) ==='
SELECT * FROM geo.road_network_stats() ORDER BY total_length_km DESC;

\echo ''
\echo '=== 1e. Documents: complaint categories and how fast they are resolved ==='
SELECT * FROM documents.complaint_stats_by_category() ORDER BY total_complaints DESC LIMIT 6;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== 2. Window functions: monthly revenue, running total, month-over-month growth ==='
-- The generator plants order growth over the year (meta.planted_effects:
-- order_growth_exponent), so revenue should trend upward.
WITH monthly AS (
    SELECT date_trunc('month', order_date)::date AS month,
           sum(total_amount)                     AS revenue
    FROM commerce.orders
    WHERE status NOT IN ('cancelled', 'refunded')
      AND order_date >= date_trunc('year', meta.as_of())   -- whole months of the as_of year
    GROUP BY 1
)
SELECT month,
       revenue,
       sum(revenue) OVER (ORDER BY month)                                    AS running_total,
       round(100.0 * (revenue / lag(revenue) OVER (ORDER BY month) - 1), 1)  AS mom_growth_pct,
       rank() OVER (ORDER BY revenue DESC)                                   AS revenue_rank
FROM monthly
ORDER BY month;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== 3. Spatial join: complaint density per neighbourhood (geography = real km²) ==='
-- Complaints carry raw lat/long; build a point and test which polygon covers it.
-- Area comes from the geography type (WGS-84 spheroid), never from a 3857 projection.
SELECT n.neighborhood_name,
       count(c.complaint_id)                                          AS complaints,
       round((ST_Area(n.boundary_geom::geography) / 1e6)::numeric, 2) AS area_km2,
       round(count(c.complaint_id) / (ST_Area(n.boundary_geom::geography) / 1e6)::numeric, 1) AS per_km2,
       round(n.median_income)                                         AS median_income
FROM geo.neighborhood_boundaries n
LEFT JOIN documents.complaint_records c
       ON ST_Covers(n.boundary_geom,
                    ST_SetSRID(ST_MakePoint(c.incident_longitude, c.incident_latitude), 4326))
GROUP BY n.neighborhood_id
ORDER BY per_km2 DESC
LIMIT 5;

\echo ''
\echo '--- ...and the 3 nearest parks to the busiest transit station (KNN + geodesic metres) ---'
WITH busiest AS (
    SELECT s.station_id, s.station_name,
           ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326) AS geom
    FROM mobility.stations s
    JOIN mobility.trip_segments t ON t.start_station_id = s.station_id
    GROUP BY s.station_id
    ORDER BY count(*) DESC, s.station_id
    LIMIT 1
)
SELECT b.station_name, p.name AS park,
       round(ST_Distance(p.location_geom::geography, b.geom::geography)) AS metres
FROM busiest b
CROSS JOIN LATERAL (
    SELECT name, location_geom
    FROM geo.points_of_interest
    WHERE category = 'park'
    ORDER BY location_geom <-> b.geom          -- GiST-assisted nearest-neighbour
    LIMIT 3
) p
ORDER BY metres;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== 4. Full-text search: web-style query "water main" -sewer, ranked, with highlights ==='
SELECT complaint_number,
       category,
       round(ts_rank(search_vector, q)::numeric, 3) AS rank,
       ts_headline('english', description, q, 'MaxWords=12, MinWords=5, StartSel=[, StopSel=]') AS snippet
FROM documents.complaint_records,
     websearch_to_tsquery('english', '"water main" -sewer') AS q   -- phrase + negation
WHERE search_vector @@ q
ORDER BY rank DESC, submitted_at DESC
LIMIT 5;

-- -----------------------------------------------------------------------------
\echo ''
\echo '=== 5. Planted-effect recovery: peak-hour transit delay ratio ==='
-- Ground truth: meta.planted_effects says mean bus/rail delay is 3x longer in
-- weekday peaks (07-09 and 16-19). Timestamps are generated in UTC.
WITH trips AS (
    SELECT delay_minutes,
           extract(isodow FROM start_time AT TIME ZONE 'UTC') < 6
           AND (extract(hour FROM start_time AT TIME ZONE 'UTC') BETWEEN 7 AND 8
                OR extract(hour FROM start_time AT TIME ZONE 'UTC') BETWEEN 16 AND 18) AS is_peak
    FROM mobility.trip_segments
    WHERE trip_mode IN ('bus', 'rail')
)
SELECT round(avg(delay_minutes) FILTER (WHERE is_peak), 2)      AS peak_delay_min,
       round(avg(delay_minutes) FILTER (WHERE NOT is_peak), 2)  AS offpeak_delay_min,
       round(avg(delay_minutes) FILTER (WHERE is_peak)
           / avg(delay_minutes) FILTER (WHERE NOT is_peak), 2)  AS recovered_ratio,
       (SELECT true_value FROM meta.planted_effects
        WHERE effect = 'peak_hour_bus_delay_ratio')             AS planted_ratio
FROM trips;

\echo ''
\echo '--- ...and labelled anomalies: how well does a simple 10x-median rule find planted order outliers? ---'
WITH flagged AS (
    SELECT o.order_id
    FROM commerce.orders o
    JOIN (SELECT merchant_id, percentile_cont(0.5) WITHIN GROUP (ORDER BY total_amount) AS med
          FROM commerce.orders GROUP BY merchant_id) m USING (merchant_id)
    WHERE o.total_amount > 10 * m.med
), truth AS (
    SELECT entity_id AS order_id FROM meta.ground_truth
    WHERE entity = 'commerce.orders' AND label = 'order_amount_outlier'
)
SELECT (SELECT count(*) FROM flagged)                              AS flagged,
       (SELECT count(*) FROM truth)                                AS labelled,
       (SELECT count(*) FROM flagged JOIN truth USING (order_id))  AS true_positives,
       round(100.0 * (SELECT count(*) FROM flagged JOIN truth USING (order_id))
             / nullif((SELECT count(*) FROM flagged), 0), 1)       AS precision_pct,
       round(100.0 * (SELECT count(*) FROM flagged JOIN truth USING (order_id))
             / nullif((SELECT count(*) FROM truth), 0), 1)         AS recall_pct;

\echo ''
\echo 'Tour complete. Next: sql/01_schema_design (schemas), tests/ (pgTAP suites: pg_prove /tests/*.sql),'
\echo 'and the other showcases in examples/ (analytics, geospatial, performance, security).'
