-- File: sql/07_geospatial/spatial_indexes_queries.sql
-- Purpose: GiST indexes, KNN, buffers, intersections, clustering and spatial query optimization
--
-- Conventions (see postgis_basics.sql):
--   * Data is stored as geometry(…, 4326).
--   * Anything in metres uses ::geography (ST_DWithin / ST_Distance / ST_Area / ST_Buffer).
--   * We never project to 3857 to measure: it inflates lengths ~19% at this latitude.
--
-- Idempotent: indexes use IF NOT EXISTS, scratch objects are TEMP tables.

\echo '== 1. Spatial indexes: geometry GiST vs geography expression GiST =='
-- What teaches: the base already has GiST indexes on the geometry columns. A query
-- that casts to geography (ST_DWithin(geom::geography, ..., metres)) can only use an
-- index built on that SAME expression, so we add expression indexes.
CREATE INDEX IF NOT EXISTS idx_pois_geog
    ON geo.points_of_interest USING gist ((location_geom::geography));
CREATE INDEX IF NOT EXISTS idx_roads_geog
    ON geo.road_segments USING gist ((segment_geom::geography));
-- Stations store latitude/longitude numerics; an expression index makes them spatial.
CREATE INDEX IF NOT EXISTS idx_stations_geog
    ON mobility.stations USING gist ((ST_SetSRID(ST_MakePoint(longitude::float8, latitude::float8), 4326)::geography));
ANALYZE geo.points_of_interest;
ANALYZE geo.road_segments;
ANALYZE mobility.stations;

SELECT indexrelid::regclass AS index_name, indrelid::regclass AS table_name,
       pg_get_indexdef(indexrelid) AS definition
FROM pg_index
WHERE indexrelid::regclass::text IN ('geo.idx_pois_geom', 'geo.idx_pois_geog',
                                     'geo.idx_roads_geog', 'mobility.idx_stations_geog')
ORDER BY 1;

-- On 600 rows the planner may prefer a seq scan; disable it briefly to SHOW the
-- index being usable. (Never do this in production code.)
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT poi_id, name
FROM geo.points_of_interest
WHERE ST_DWithin(location_geom::geography,
                 ST_SetSRID(ST_MakePoint(-96.8040, 32.9855), 4326)::geography, 500);
COMMIT;

\echo '== 2. K-nearest-neighbour (KNN) with <-> =='
-- What teaches: ORDER BY a <-> b LIMIT k is answered by a GiST index scan that walks
-- the tree in distance order (no need to compute every distance).
--   geometry <-> geometry : distance in DEGREES (fine for ranking in a small area,
--                           but 1 deg of longitude is shorter than 1 deg of latitude)
--   geography <-> geography: true spheroid distance in METRES (index-assisted too)
EXPLAIN (COSTS OFF)
SELECT poi_id
FROM geo.points_of_interest
ORDER BY location_geom::geography <-> ST_SetSRID(ST_MakePoint(-96.8040, 32.9855), 4326)::geography
LIMIT 5;

-- 5 nearest active POIs to City Hall
SELECT
    poi.poi_id,
    poi.name,
    poi.category,
    round((poi.location_geom::geography <-> ch.g)::numeric) AS distance_m
FROM geo.points_of_interest poi,
     LATERAL (SELECT ST_SetSRID(ST_MakePoint(-96.8040, 32.9855), 4326)::geography AS g) ch
WHERE poi.is_active
ORDER BY poi.location_geom::geography <-> ch.g, poi.poi_id
LIMIT 5;

-- Nearest POI of each category: a LATERAL KNN per category is far cheaper than
-- ROW_NUMBER() over every POI because each lateral probe stops after 1 row.
WITH city_hall AS (
    SELECT ST_SetSRID(ST_MakePoint(-96.8040, 32.9855), 4326)::geography AS g
)
SELECT
    c.category,
    nearest.name,
    round(nearest.distance_m::numeric) AS distance_m
FROM unnest(enum_range(NULL::geo.poi_category)) AS c(category)
CROSS JOIN city_hall ch
CROSS JOIN LATERAL (
    SELECT poi.name, poi.location_geom::geography <-> ch.g AS distance_m
    FROM geo.points_of_interest poi
    WHERE poi.category = c.category AND poi.is_active
    ORDER BY poi.location_geom::geography <-> ch.g, poi.poi_id
    LIMIT 1
) nearest
ORDER BY distance_m, c.category;

\echo '== 3. Radius searches and walk-shed buffers =='
-- What teaches: "within N metres" should be ST_DWithin(geography), not
-- ST_Buffer + ST_Contains (slower and less accurate). Ring counts use FILTER.
SELECT
    s.station_name,
    s.station_type,
    COUNT(poi.poi_id) FILTER (WHERE ST_DWithin(sg.g, poi.location_geom::geography, 400)) AS pois_within_400m,
    COUNT(poi.poi_id) FILTER (WHERE NOT ST_DWithin(sg.g, poi.location_geom::geography, 400)) AS pois_400_to_800m,
    COUNT(poi.poi_id)                                                                       AS pois_within_800m
FROM mobility.stations s
CROSS JOIN LATERAL (SELECT ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography AS g) sg
LEFT JOIN geo.points_of_interest poi
       ON poi.is_active
      AND ST_DWithin(sg.g, poi.location_geom::geography, 800)
WHERE s.status = 'active'
GROUP BY s.station_id, s.station_name, s.station_type
ORDER BY pois_within_800m DESC, s.station_name
LIMIT 10;

-- When you DO need a buffer polygon (e.g. to draw it or union it), buffer the
-- geography: PostGIS picks a suitable local projection internally and the radius
-- is in metres. Here: area of an 800 m walk-shed should be ~ pi * 800^2 = 2.01 km^2.
SELECT
    round((ST_Area(ST_Buffer(ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)::geography, 800)) / 1e6)::numeric, 3)
        AS buffer_area_sq_km,
    round((pi() * 800 ^ 2 / 1e6)::numeric, 3) AS expected_sq_km;

\echo '== 4. Intersections =='
-- What teaches: ST_Intersects (index-assisted predicate) vs ST_Intersection (geometry
-- construction). Lengths of the clipped pieces are measured as geography.
SELECT
    nb.neighborhood_name,
    COUNT(rs.segment_id)                                          AS intersecting_segments,
    COUNT(*) FILTER (WHERE rs.road_type = 'arterial')             AS arterial,
    COUNT(*) FILTER (WHERE rs.road_type = 'collector')            AS collector,
    COUNT(*) FILTER (WHERE rs.road_type = 'residential')          AS residential,
    round((SUM(ST_Length(ST_Intersection(nb.boundary_geom, rs.segment_geom)::geography)) / 1000.0)::numeric, 2)
                                                                  AS road_km_inside
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.road_segments rs ON ST_Intersects(nb.boundary_geom, rs.segment_geom)
GROUP BY nb.neighborhood_id, nb.neighborhood_name
ORDER BY road_km_inside DESC NULLS LAST, nb.neighborhood_name
LIMIT 10;

-- POIs within 100 m of an arterial/collector road, with the nearest such road
-- found by a LATERAL KNN probe (one row per POI, no duplicates).
SELECT
    poi.category,
    COUNT(*)                                   AS pois_near_major_road,
    round(AVG(nr.distance_m)::numeric, 1)      AS avg_distance_m
FROM geo.points_of_interest poi
CROSS JOIN LATERAL (
    SELECT rs.road_name, rs.road_type,
           ST_Distance(poi.location_geom::geography, rs.segment_geom::geography) AS distance_m
    FROM geo.road_segments rs
    WHERE rs.road_type IN ('arterial', 'collector', 'highway')
    ORDER BY rs.segment_geom::geography <-> poi.location_geom::geography, rs.segment_id
    LIMIT 1
) nr
WHERE poi.is_active
  AND nr.distance_m <= 100
GROUP BY poi.category
ORDER BY pois_near_major_road DESC, poi.category;

\echo '== 5. Spatial aggregations =='
-- What teaches: density per km^2 and service-coverage via unioned geography buffers.
SELECT
    nb.neighborhood_name,
    nb.area_sq_km,
    COUNT(poi.poi_id)                                                    AS poi_count,
    round(COUNT(poi.poi_id)::numeric / NULLIF(nb.area_sq_km, 0), 2)      AS poi_per_sq_km,
    COUNT(*) FILTER (WHERE poi.category = 'restaurant')                  AS restaurants,
    COUNT(*) FILTER (WHERE poi.category = 'retail')                      AS retail,
    COUNT(*) FILTER (WHERE poi.category = 'park')                        AS parks
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.points_of_interest poi
       ON ST_Contains(nb.boundary_geom, poi.location_geom) AND poi.is_active
GROUP BY nb.neighborhood_id, nb.neighborhood_name, nb.area_sq_km
ORDER BY poi_per_sq_km DESC, nb.neighborhood_name
LIMIT 10;

-- Share of each neighbourhood within 500 m of an essential service.
-- Buffers are built on geography (metres) and cast back to geometry for ST_Union.
DROP TABLE IF EXISTS tmp_service_coverage;
CREATE TEMP TABLE tmp_service_coverage AS
SELECT ST_Union(ST_Buffer(location_geom::geography, 500)::geometry) AS coverage_geom
FROM geo.points_of_interest
WHERE category IN ('hospital', 'school', 'library', 'government')
  AND is_active;

SELECT
    nb.neighborhood_name,
    round((100 * ST_Area(ST_Intersection(nb.boundary_geom, sc.coverage_geom)::geography)
               / ST_Area(nb.boundary_geom::geography))::numeric, 1)  AS service_coverage_pct,
    ST_Covers(sc.coverage_geom, nb.boundary_geom)                     AS fully_covered
FROM geo.neighborhood_boundaries nb
CROSS JOIN tmp_service_coverage sc
ORDER BY service_coverage_pct DESC, nb.neighborhood_name
LIMIT 10;

\echo '== 6. Clustering with ST_ClusterDBSCAN =='
-- What teaches: density-based clustering. eps is in the units of the input, so we
-- cluster in UTM 14N (metres, accurate locally) rather than in degrees or 3857.
WITH restaurant_clusters AS (
    SELECT
        poi.poi_id,
        poi.name,
        poi.location_geom,
        ST_ClusterDBSCAN(ST_Transform(poi.location_geom, 32614), eps => 250, minpoints => 3) OVER () AS cluster_id
    FROM geo.points_of_interest poi
    WHERE poi.category = 'restaurant' AND poi.is_active
)
SELECT
    cluster_id,
    COUNT(*)                                                        AS restaurants_in_cluster,
    left(string_agg(name, ', ' ORDER BY name), 80)                  AS sample_names,
    ST_AsText(ST_Centroid(ST_Collect(location_geom)), 5)            AS cluster_center,
    round(ST_Area(ST_ConvexHull(ST_Collect(location_geom))::geography)::numeric) AS hull_area_sq_m
FROM restaurant_clusters
WHERE cluster_id IS NOT NULL
GROUP BY cluster_id
ORDER BY restaurants_in_cluster DESC, cluster_id
LIMIT 10;

\echo '== 7. Advanced: centrality and underserved areas =='
-- Most central POI per (neighbourhood, category): LATERAL KNN to the centroid.
SELECT
    nb.neighborhood_name,
    c.category,
    central.name                          AS most_central_poi,
    round(central.distance_m::numeric)    AS distance_from_center_m
FROM geo.neighborhood_boundaries nb
CROSS JOIN unnest(ARRAY['restaurant', 'retail', 'park', 'school']::geo.poi_category[]) AS c(category)
CROSS JOIN LATERAL (
    SELECT poi.name,
           ST_Distance(poi.location_geom::geography, ST_Centroid(nb.boundary_geom)::geography) AS distance_m
    FROM geo.points_of_interest poi
    WHERE poi.category = c.category
      AND poi.is_active
      AND ST_Contains(nb.boundary_geom, poi.location_geom)
    ORDER BY poi.location_geom <-> ST_Centroid(nb.boundary_geom), poi.poi_id
    LIMIT 1
) central
ORDER BY nb.neighborhood_name, c.category
LIMIT 16;

-- Underserved area: parts of each neighbourhood more than 800 m from any
-- everyday service. ST_Difference of the polygon minus the unioned coverage.
DROP TABLE IF EXISTS tmp_everyday_coverage;
CREATE TEMP TABLE tmp_everyday_coverage AS
SELECT ST_Union(ST_Buffer(location_geom::geography, 800)::geometry) AS covered_geom
FROM geo.points_of_interest
WHERE category IN ('restaurant', 'retail', 'school', 'hospital', 'library')
  AND is_active;

WITH underserved AS (
    SELECT nb.neighborhood_name,
           nb.boundary_geom,
           ST_Difference(nb.boundary_geom, pc.covered_geom) AS underserved_geom
    FROM geo.neighborhood_boundaries nb
    CROSS JOIN tmp_everyday_coverage pc
)
SELECT
    neighborhood_name,
    round((ST_Area(underserved_geom::geography) / 1e6)::numeric, 3)                          AS underserved_sq_km,
    round((100 * ST_Area(underserved_geom::geography) / ST_Area(boundary_geom::geography))::numeric, 1) AS underserved_pct,
    left(ST_AsGeoJSON(underserved_geom, 5), 60) || '...'                                     AS geojson_preview
FROM underserved
WHERE NOT ST_IsEmpty(underserved_geom)
  AND ST_Area(underserved_geom::geography) > 10000   -- ignore slivers < 1 ha
ORDER BY underserved_sq_km DESC, neighborhood_name
LIMIT 10;
