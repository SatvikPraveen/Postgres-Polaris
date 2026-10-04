-- Location: /examples/geospatial_showcase.sql
-- =============================================================================
-- Geospatial showcase - PostGIS on the Polaris City dataset
-- =============================================================================
-- Demos (each section says what it teaches):
--   1. Spatial inventory          - geometry types, SRIDs, extents, validity
--   2. Nearest neighbours (KNN)   - ORDER BY <-> uses the GiST index; report
--                                   distances in metres via geography
--   3. Point-in-polygon           - ST_Covers joins (citizens, POIs per hood)
--   4. Buffers / service areas    - ST_DWithin(geography) "within 800 m"
--   5. Aggregation                - ST_Union, ST_ConvexHull, geodesic area
--   6. Lines                      - road lengths (geodesic) by type and hood
--   7. Accessibility gap analysis - citizens farther than X m from a service
--   8. Geometry vs geography      - why degrees and Web Mercator mislead
--   9. Index use                  - EXPLAIN of a KNN and an ST_DWithin query
--
-- Rules followed throughout: all data is SRID 4326 (WGS-84 lon/lat). Distances
-- and areas are measured with ::geography (metres on the spheroid); we never
-- ST_Transform to 3857 to measure. Read-only.
-- Run: psql -X -v ON_ERROR_STOP=1 -d <db> -f /examples/geospatial_showcase.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off
\pset null '-'

SELECT postgis_full_version() IS NOT NULL AS postgis_ready, postgis_lib_version() AS postgis_version;

\echo ''
\echo '=== 1. Spatial inventory: what geometry lives where? ==='
SELECT f_table_schema || '.' || f_table_name AS table_name, f_geometry_column AS column_name,
       type, srid, coord_dimension AS dims
FROM geometry_columns
WHERE f_table_schema IN ('civics', 'geo')
ORDER BY 1, 2;

SELECT 'neighbourhoods' AS layer, count(*) AS features,
       ST_Extent(boundary_geom)::text AS extent,
       count(*) FILTER (WHERE NOT ST_IsValid(boundary_geom)) AS invalid
FROM geo.neighborhood_boundaries
UNION ALL
SELECT 'points of interest', count(*), ST_Extent(location_geom)::text,
       count(*) FILTER (WHERE NOT ST_IsValid(location_geom))
FROM geo.points_of_interest
UNION ALL
SELECT 'road segments', count(*), ST_Extent(segment_geom)::text,
       count(*) FILTER (WHERE NOT ST_IsValid(segment_geom))
FROM geo.road_segments;

\echo ''
\echo '=== 2. KNN: the 3 nearest hospitals / schools / libraries to City Hall (first government POI) ==='
-- ORDER BY geom <-> point is answered by the GiST index (index-assisted KNN);
-- the reported distance uses geography to get metres.
WITH city_hall AS (
    SELECT name, location_geom AS g
    FROM geo.points_of_interest
    WHERE category = 'government'
    ORDER BY poi_id
    LIMIT 1
)
SELECT ch.name AS from_poi, cat.category, near.name AS nearest,
       round(ST_Distance(near.location_geom::geography, ch.g::geography)) AS metres
FROM city_hall ch
CROSS JOIN (VALUES ('hospital'::geo.poi_category), ('school'), ('library')) AS cat(category)
CROSS JOIN LATERAL (
    SELECT p.name, p.location_geom
    FROM geo.points_of_interest p
    WHERE p.category = cat.category
    ORDER BY p.location_geom <-> ch.g
    LIMIT 3
) near
ORDER BY cat.category, metres;

\echo ''
\echo '--- the same idea packaged as a function: geo.find_nearby_pois(lat, lng, radius_m, category) ---'
SELECT * FROM geo.find_nearby_pois(32.98, -96.80, 600) LIMIT 5;

\echo ''
\echo '=== 3. Point-in-polygon: citizens and POIs per neighbourhood ==='
-- ST_Covers (unlike ST_Contains) also counts points exactly on the boundary.
SELECT n.neighborhood_name,
       (SELECT count(*) FROM civics.citizens c WHERE ST_Covers(n.boundary_geom, c.home_geom))       AS residents,
       n.population_estimate                                                                       AS documented_population,
       (SELECT count(*) FROM geo.points_of_interest p WHERE ST_Covers(n.boundary_geom, p.location_geom)) AS pois,
       round(n.median_income)                                                                      AS median_income
FROM geo.neighborhood_boundaries n
ORDER BY residents DESC, n.neighborhood_name
LIMIT 8;

\echo ''
\echo '=== 4. Service areas: residents within 800 m (a 10-minute walk) of a rail station ==='
-- ST_DWithin on geography takes metres and can use a geography-capable index.
WITH rail AS (
    SELECT station_id, station_name,
           ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography AS g
    FROM mobility.stations
    WHERE station_type = 'rail'
)
SELECT r.station_name,
       count(c.citizen_id) AS residents_within_800m
FROM rail r
LEFT JOIN civics.citizens c ON ST_DWithin(c.home_geom::geography, r.g, 800)
GROUP BY r.station_id, r.station_name
ORDER BY residents_within_800m DESC, r.station_name
LIMIT 5;

SELECT round(100.0 * count(*) FILTER (WHERE EXISTS (
           SELECT 1 FROM mobility.stations s
           WHERE s.station_type = 'rail'
             AND ST_DWithin(c.home_geom::geography,
                            ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326)::geography, 800)))
       / count(*), 1) AS pct_city_within_800m_of_rail
FROM civics.citizens c;

\echo ''
\echo '=== 5. Aggregation: dissolve neighbourhoods by council district ==='
SELECT city_council_district AS district,
       count(*)                                                              AS neighbourhoods,
       ST_GeometryType(ST_Union(boundary_geom))                              AS dissolved_type,
       round((ST_Area(ST_Union(boundary_geom)::geography) / 1e6)::numeric, 2) AS area_km2,
       round((ST_Perimeter(ST_Union(boundary_geom)::geography) / 1e3)::numeric, 2) AS perimeter_km
FROM geo.neighborhood_boundaries
GROUP BY city_council_district
ORDER BY district;

SELECT round((ST_Area(ST_ConvexHull(ST_Collect(location_geom))::geography) / 1e6)::numeric, 2) AS poi_hull_km2,
       round((ST_Area(ST_Union(boundary_geom)::geography) / 1e6)::numeric, 2)                  AS city_area_km2
FROM geo.points_of_interest, (SELECT ST_Union(boundary_geom) AS boundary_geom FROM geo.neighborhood_boundaries) city
GROUP BY city.boundary_geom;

\echo ''
\echo '=== 6. Lines: road network length by type (geodesic km) and the best-paved neighbourhoods ==='
SELECT road_type, count(*) AS segments,
       round((sum(ST_Length(segment_geom::geography)) / 1000)::numeric, 2) AS km,
       round(avg(speed_limit))                                  AS avg_speed_limit,
       round(100.0 * count(*) FILTER (WHERE has_bike_lane) / count(*), 1) AS bike_lane_pct
FROM geo.road_segments
GROUP BY road_type
ORDER BY km DESC;

SELECT n.neighborhood_name,
       round((sum(ST_Length(ST_Intersection(r.segment_geom, n.boundary_geom)::geography)) / 1000)::numeric, 2) AS road_km_inside,
       round(avg(r.condition_rating), 2) AS avg_condition
FROM geo.neighborhood_boundaries n
JOIN geo.road_segments r ON ST_Intersects(r.segment_geom, n.boundary_geom)
GROUP BY n.neighborhood_id, n.neighborhood_name
ORDER BY avg_condition DESC, n.neighborhood_name
LIMIT 5;

\echo ''
\echo '=== 7. Accessibility gaps: where are residents farthest from a hospital? ==='
-- KNN per citizen via LATERAL ... ORDER BY <-> LIMIT 1, then aggregate per hood.
SELECT n.neighborhood_name,
       count(*)                                                             AS residents,
       round(avg(d.metres)::numeric)                                        AS avg_m_to_hospital,
       round(100.0 * count(*) FILTER (WHERE d.metres > 2000) / count(*), 1) AS pct_over_2km
FROM civics.citizens c
JOIN geo.neighborhood_boundaries n ON ST_Covers(n.boundary_geom, c.home_geom)
CROSS JOIN LATERAL (
    SELECT ST_Distance(p.location_geom::geography, c.home_geom::geography) AS metres
    FROM geo.points_of_interest p
    WHERE p.category = 'hospital'
    ORDER BY p.location_geom <-> c.home_geom
    LIMIT 1
) d
GROUP BY n.neighborhood_name
ORDER BY avg_m_to_hospital DESC
LIMIT 5;

\echo ''
\echo '=== 8. Geometry vs geography: same two points, three answers ==='
-- Degrees are not a distance; Web Mercator (3857) inflates lengths by
-- ~1/cos(latitude) (about 19% at 33 N). Geography is the right tool here.
WITH pts AS (
    SELECT ST_SetSRID(ST_MakePoint(-96.86, 32.948), 4326) AS a,
           ST_SetSRID(ST_MakePoint(-96.74, 33.012), 4326) AS b
)
SELECT round(ST_Distance(a, b)::numeric, 5)                                          AS degrees_meaningless,
       round(ST_Distance(ST_Transform(a, 3857), ST_Transform(b, 3857))::numeric)     AS web_mercator_m_wrong,
       round(ST_Distance(a::geography, b::geography)::numeric)                       AS geography_m,
       round((ST_Distance(ST_Transform(a, 3857), ST_Transform(b, 3857))
              / ST_Distance(a::geography, b::geography))::numeric, 3)                AS mercator_inflation
FROM pts;

\echo ''
\echo '=== 9. Index use: KNN and radius search plans ==='
EXPLAIN (COSTS OFF)
SELECT poi_id FROM geo.points_of_interest
ORDER BY location_geom <-> ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)
LIMIT 5;

-- ST_DWithin(geometry, geometry, degrees) uses the geometry GiST index directly;
-- for an exact metre radius, pre-filter with the index and confirm with geography.
-- The degree pre-filter must be generous: 0.01 deg is ~1.11 km N-S and ~0.93 km
-- E-W at 33 N, so it safely encloses an 800 m circle.
EXPLAIN (COSTS OFF)
SELECT poi_id FROM geo.points_of_interest
WHERE ST_DWithin(location_geom, ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326), 0.01)
  AND ST_DWithin(location_geom::geography, ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)::geography, 800);
