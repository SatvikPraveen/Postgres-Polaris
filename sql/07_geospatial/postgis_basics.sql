-- File: sql/07_geospatial/postgis_basics.sql
-- Purpose: SRID, projections, geometry vs geography fundamentals
--
-- Polaris City lives around (-96.80, 32.98) in North Texas. All stored geometries
-- use SRID 4326 (WGS 84 longitude/latitude, units = degrees).
--
-- Rule of thumb used throughout this module:
--   * Store in 4326 geometry (fast, indexable, works with every PostGIS function).
--   * MEASURE (distance, length, area, "within N metres") with ::geography, which
--     computes on the spheroid and returns metres / square metres.
--   * Never ST_Transform to 3857 (Web Mercator) to measure anything: Mercator
--     inflates lengths by 1/cos(latitude) (~19% at 33 degrees N). 3857 is for
--     drawing web map tiles only.
--   * A local projected CRS (e.g. State Plane 2276) is accurate locally but has its
--     own units (US survey feet for 2276!) - check the unit before trusting numbers.
--
-- Idempotent: only CREATE OR REPLACE functions and TEMP tables.

\echo '== 1. Spatial reference systems =='
-- What teaches: spatial_ref_sys is the catalogue of CRSs; proj4text shows units.
SELECT
    srid,
    auth_name,
    auth_srid,
    left(srtext, 60)    AS srtext_start,
    proj4text
FROM spatial_ref_sys
WHERE srid IN (4326, 4269, 3857, 2276, 32614)
ORDER BY srid;

-- Common SRIDs for city planning:
--   4326  - WGS 84 lon/lat (GPS). Units: degrees.
--   4269  - NAD83 lon/lat (US federal data). Units: degrees.
--   3857  - Web Mercator (web map tiles). Units: "metres" that are only true at the equator.
--   2276  - NAD83 / Texas North Central (ftUS). Units: US survey feet.
--   32614 - WGS 84 / UTM zone 14N. Units: metres (true-ish within the zone).

\echo '== 2. Geometry vs geography =='
-- What teaches: the same coordinates measured four ways; only geography (and a
-- correct local projection) gives real-world metres.
DROP TABLE IF EXISTS spatial_demo;
CREATE TEMP TABLE spatial_demo AS
SELECT *
FROM (VALUES
    ('Downtown Dallas',  -96.7970, 32.7767),
    ('Downtown Austin',  -97.7431, 30.2672),
    ('Downtown Houston', -95.3698, 29.7604)
) AS v(location_name, longitude, latitude)
CROSS JOIN LATERAL (
    SELECT ST_SetSRID(ST_MakePoint(v.longitude, v.latitude), 4326)            AS geom_point,
           ST_SetSRID(ST_MakePoint(v.longitude, v.latitude), 4326)::geography AS geog_point
) p;

SELECT
    d1.location_name AS from_city,
    d2.location_name AS to_city,
    -- Planar distance in DEGREES: meaningless as a length
    round(ST_Distance(d1.geom_point, d2.geom_point)::numeric, 4)                     AS geom_degrees,
    -- ANTI-PATTERN: Web Mercator "metres" (inflated by ~15-19% at these latitudes)
    round(ST_Distance(ST_Transform(d1.geom_point, 3857),
                      ST_Transform(d2.geom_point, 3857))::numeric)                    AS mercator_m_wrong,
    -- Correct: geodesic distance on the WGS 84 spheroid, in metres
    round(ST_Distance(d1.geog_point, d2.geog_point)::numeric)                        AS geography_m,
    -- Spherical approximation (faster, ~0.3% error)
    round(ST_Distance(d1.geog_point, d2.geog_point, false)::numeric)                 AS sphere_m,
    round((100 * ST_Distance(ST_Transform(d1.geom_point, 3857), ST_Transform(d2.geom_point, 3857))
           / ST_Distance(d1.geog_point, d2.geog_point) - 100)::numeric, 1)          AS mercator_error_pct
FROM spatial_demo d1
JOIN spatial_demo d2 ON d1.location_name < d2.location_name
ORDER BY from_city, to_city;

\echo '== 3. Coordinate transformations and output formats =='
-- What teaches: ST_Transform re-projects coordinates; ST_AsText/GeoJSON/EWKT serialise.
-- Note the 2276 coordinates are in US survey FEET.
SELECT
    poi.poi_id,
    poi.name,
    round(ST_X(poi.location_geom)::numeric, 6)                          AS lng_wgs84,
    round(ST_Y(poi.location_geom)::numeric, 6)                          AS lat_wgs84,
    round(ST_X(ST_Transform(poi.location_geom, 2276))::numeric, 1)      AS x_stateplane_ft,
    round(ST_Y(ST_Transform(poi.location_geom, 2276))::numeric, 1)      AS y_stateplane_ft,
    round(ST_X(ST_Transform(poi.location_geom, 32614))::numeric, 1)     AS x_utm14_m,
    ST_AsEWKT(poi.location_geom)                                        AS ewkt,
    ST_AsGeoJSON(poi.location_geom, 6)::jsonb                           AS geojson
FROM geo.points_of_interest poi
ORDER BY poi.poi_id
LIMIT 5;

-- Projection sanity check: a ~400 m street segment measured several ways
SELECT
    segment_id,
    round(ST_Length(segment_geom::geography)::numeric, 1)                     AS geography_m,
    round(ST_Length(ST_Transform(segment_geom, 32614))::numeric, 1)           AS utm14_m,
    round((ST_Length(ST_Transform(segment_geom, 2276)) * 0.3048006096)::numeric, 1) AS stateplane_ft_to_m,
    round(ST_Length(ST_Transform(segment_geom, 3857))::numeric, 1)            AS mercator_m_wrong
FROM geo.road_segments
ORDER BY segment_id
LIMIT 3;

\echo '== 4. Basic spatial operations =='
-- What teaches: point-in-polygon with ST_Contains (geometry, index-assisted).
SELECT
    nb.neighborhood_name,
    COUNT(poi.poi_id)                                                    AS poi_count,
    COUNT(*) FILTER (WHERE poi.category = 'restaurant')                  AS restaurants,
    COUNT(*) FILTER (WHERE poi.category = 'park')                        AS parks
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.points_of_interest poi ON ST_Contains(nb.boundary_geom, poi.location_geom)
GROUP BY nb.neighborhood_id, nb.neighborhood_name
ORDER BY poi_count DESC, nb.neighborhood_name
LIMIT 10;

-- What teaches: "within N metres" = ST_DWithin on geography (metres, uses GiST index
-- on the geography expression or falls back to a filter for small tables).
-- Stations store latitude/longitude numerics, so we build the point on the fly.
SELECT
    s.station_name,
    s.station_type,
    COUNT(poi.poi_id) AS pois_within_500m
FROM mobility.stations s
LEFT JOIN geo.points_of_interest poi
       ON ST_DWithin(ST_SetSRID(ST_MakePoint(s.longitude, s.latitude), 4326)::geography,
                     poi.location_geom::geography,
                     500)          -- 500 metres
GROUP BY s.station_id, s.station_name, s.station_type
ORDER BY pois_within_500m DESC, s.station_name
LIMIT 10;

\echo '== 5. Measurements: area, perimeter, length =='
-- What teaches: ST_Area/ST_Perimeter/ST_Length on geography return m^2 / m.
-- The stored area_sq_km column was computed the same way by a trigger.
SELECT
    neighborhood_name,
    area_sq_km                                                            AS stored_area_sq_km,
    round((ST_Area(boundary_geom::geography) / 1e6)::numeric, 3)          AS area_sq_km,
    round((ST_Perimeter(boundary_geom::geography) / 1e3)::numeric, 3)     AS perimeter_km,
    round(ST_X(ST_Centroid(boundary_geom))::numeric, 6)                   AS centroid_lng,
    round(ST_Y(ST_Centroid(boundary_geom))::numeric, 6)                   AS centroid_lat,
    ST_AsText(ST_Envelope(boundary_geom))                                 AS bounding_box
FROM geo.neighborhood_boundaries
ORDER BY area_sq_km DESC, neighborhood_name
LIMIT 10;

-- Road network per neighbourhood. ST_Intersection clips each segment to the
-- polygon so a segment straddling two neighbourhoods is not double counted.
SELECT
    nb.neighborhood_name,
    COUNT(rs.segment_id)                                                              AS road_segments,
    round((SUM(ST_Length(ST_Intersection(rs.segment_geom, nb.boundary_geom)::geography)) / 1e3)::numeric, 2)
                                                                                      AS road_km_inside,
    round(((SUM(ST_Length(ST_Intersection(rs.segment_geom, nb.boundary_geom)::geography)) / 1e3)
           / NULLIF(ST_Area(nb.boundary_geom::geography) / 1e6, 0))::numeric, 1)      AS road_km_per_sq_km
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.road_segments rs ON ST_Intersects(nb.boundary_geom, rs.segment_geom)
GROUP BY nb.neighborhood_id, nb.neighborhood_name, nb.boundary_geom
ORDER BY road_km_per_sq_km DESC NULLS LAST, nb.neighborhood_name
LIMIT 10;

\echo '== 6. Spatial relationships and bearings =='
-- What teaches: ST_DWithin / ST_Distance on geography, ST_Azimuth for bearing.
-- ST_Azimuth on geography gives the true bearing (radians, clockwise from north).
WITH spatial_relationships AS (
    SELECT
        poi1.name AS poi1_name,
        poi2.name AS poi2_name,
        ST_Distance(poi1.location_geom::geography, poi2.location_geom::geography)       AS distance_m,
        ST_DWithin(poi1.location_geom::geography, poi2.location_geom::geography, 1000)  AS within_1km,
        degrees(ST_Azimuth(poi1.location_geom::geography, poi2.location_geom::geography)) AS bearing_degrees
    FROM geo.points_of_interest poi1
    JOIN geo.points_of_interest poi2
      ON poi1.poi_id < poi2.poi_id
     AND ST_DWithin(poi1.location_geom::geography, poi2.location_geom::geography, 2000)
    WHERE poi1.category = 'restaurant'
      AND poi2.category = 'restaurant'
)
SELECT
    poi1_name,
    poi2_name,
    round(distance_m::numeric)           AS distance_m,
    within_1km,
    round(bearing_degrees::numeric, 1)   AS bearing_degrees,
    -- 8-point compass rose: each sector is 45 degrees, centred on N/NE/E/...
    (ARRAY['North','Northeast','East','Southeast','South','Southwest','West','Northwest'])
        [((floor((bearing_degrees + 22.5) / 45))::int % 8) + 1] AS direction
FROM spatial_relationships
ORDER BY distance_m, poi1_name, poi2_name
LIMIT 15;

\echo '== 7. Coordinate validation helpers =='
-- What teaches: defensive input validation in PL/pgSQL before building geometries.
CREATE OR REPLACE FUNCTION geo.validate_coordinates(
    latitude      numeric,
    longitude     numeric,
    region_bounds geometry DEFAULT NULL
)
RETURNS TABLE(is_valid boolean, validation_message text, suggested_srid integer)
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    test_point   geometry;
    texas_bounds geometry := ST_MakeEnvelope(-106.65, 25.84, -93.51, 36.50, 4326);
BEGIN
    IF latitude IS NULL OR longitude IS NULL THEN
        RETURN QUERY SELECT false, 'Latitude and longitude are required', NULL::integer;
        RETURN;
    END IF;

    -- Range check. A very common bug is swapped lat/lng: lng=32, lat=-96 fails here.
    IF latitude < -90 OR latitude > 90 OR longitude < -180 OR longitude > 180 THEN
        RETURN QUERY SELECT false, 'Coordinates outside valid range (lat +/-90, lng +/-180)', NULL::integer;
        RETURN;
    END IF;

    -- PostGIS points are (X = longitude, Y = latitude)
    test_point := ST_SetSRID(ST_MakePoint(longitude, latitude), 4326);

    IF region_bounds IS NOT NULL AND NOT ST_Covers(region_bounds, test_point) THEN
        RETURN QUERY SELECT true, 'Coordinates valid but outside specified region', 4326;
        RETURN;
    END IF;

    IF NOT ST_Covers(texas_bounds, test_point) THEN
        RETURN QUERY SELECT true, 'Coordinates valid but outside Texas region (check for swapped lat/lng)', 4326;
        RETURN;
    END IF;

    RETURN QUERY SELECT true, 'Coordinates valid', 4326;
END;
$$;

SELECT t.label, v.*
FROM (VALUES
    ('city centre',     32.98::numeric,  -96.80::numeric),
    ('swapped lat/lng', -96.80,          32.98),
    ('London',          51.50,           -0.12)
) AS t(label, lat, lng)
CROSS JOIN LATERAL geo.validate_coordinates(t.lat, t.lng) v
ORDER BY t.label;

-- Convert degrees/minutes/seconds text to decimal degrees.
-- Accepts e.g. 32°46'40.2"N, 96 47 49.2 W, 32:46:40.2, -96.797, 32 46.67 N.
CREATE OR REPLACE FUNCTION geo.convert_coordinate_format(
    input_value  text,
    input_format text,               -- 'dd', 'dm', 'dms'
    output_format text DEFAULT 'dd'  -- only 'dd' is produced
)
RETURNS numeric
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    parts      text[];
    hemisphere text;
    sign       int := 1;
    result     numeric;
BEGIN
    IF output_format <> 'dd' THEN
        RAISE EXCEPTION 'Unsupported output format: % (only dd)', output_format;
    END IF;

    hemisphere := upper(substring(input_value FROM '([NSEWnsew])\s*$'));
    IF hemisphere IN ('S', 'W') OR btrim(input_value) LIKE '-%' THEN
        sign := -1;
    END IF;

    -- Pull out the numeric components in order
    SELECT array_agg(m[1]) INTO parts
    FROM regexp_matches(input_value, '(\d+(?:\.\d+)?)', 'g') AS m;

    CASE input_format
        WHEN 'dd' THEN
            result := parts[1]::numeric;
        WHEN 'dm' THEN
            result := parts[1]::numeric + coalesce(parts[2]::numeric, 0) / 60;
        WHEN 'dms' THEN
            result := parts[1]::numeric + coalesce(parts[2]::numeric, 0) / 60
                                        + coalesce(parts[3]::numeric, 0) / 3600;
        ELSE
            RAISE EXCEPTION 'Unsupported input format: %', input_format;
    END CASE;

    RETURN round(sign * result, 7);
END;
$$;

SELECT
    geo.convert_coordinate_format('32°46''40.2"N', 'dms')  AS dallas_lat,
    geo.convert_coordinate_format('96 47 49.2 W', 'dms')   AS dallas_lng,
    geo.convert_coordinate_format('32 46.67 N', 'dm')      AS dm_example,
    geo.convert_coordinate_format('-96.7970', 'dd')        AS dd_example;
