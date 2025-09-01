-- File: sql/07_geospatial/postgis_basics.sql
-- Purpose: SRID, projections, geometry vs geography fundamentals

-- =============================================================================
-- SPATIAL REFERENCE SYSTEMS (SRID) OVERVIEW
-- =============================================================================

-- Check available spatial reference systems
SELECT
    srid,
    auth_name,
    auth_srid,
    srtext,
    proj4text
FROM spatial_ref_sys
WHERE srid IN (4326, 3857, 2276, 4269)
ORDER BY srid;

-- Common SRIDs for city planning:
-- 4326 - WGS 84 (GPS coordinates, lat/lng)
-- 3857 - Web Mercator (Google Maps, web mapping)
-- 2276 - NAD83 Texas North Central (local accurate measurements)

-- =============================================================================
-- GEOMETRY vs GEOGRAPHY DATA TYPES
-- =============================================================================

-- Create demo table to show geometry vs geography differences
CREATE TEMP TABLE spatial_demo AS
SELECT
    'Downtown Dallas' as location_name,
    32.7767 as latitude,
    -96.7970 as longitude,
    -- Geometry column (planar, fast but less accurate for large distances)
    ST_SetSRID(ST_Point(-96.7970, 32.7767), 4326) as geom_point,
    -- Geography column (spherical, slower but more accurate)
    ST_SetSRID(ST_Point(-96.7970, 32.7767), 4326)::geography as geog_point

UNION ALL SELECT
    'Downtown Austin', 30.2672, -97.7431,
    ST_SetSRID(ST_Point(-97.7431, 30.2672), 4326),
    ST_SetSRID(ST_Point(-97.7431, 30.2672), 4326)::geography

UNION ALL SELECT
    'Downtown Houston', 29.7604, -95.3698,
    ST_SetSRID(ST_Point(-95.3698, 29.7604), 4326),
    ST_SetSRID(ST_Point(-95.3698, 29.7604), 4326)::geography;

-- Compare distance calculations
SELECT
    d1.location_name as from_city,
    d2.location_name as to_city,
    -- Geometry distance (planar, in degrees - not useful!)
    ROUND(ST_Distance(d1.geom_point, d2.geom_point)::NUMERIC, 6) as geom_distance_degrees,
    -- Geometry distance transformed to meters
    ROUND(ST_Distance(ST_Transform(d1.geom_point, 3857), ST_Transform(d2.geom_point, 3857))) as geom_distance_meters,
    -- Geography distance (spherical, in meters - accurate!)
    ROUND(ST_Distance(d1.geog_point, d2.geog_point)) as geog_distance_meters,
    -- Difference between methods
    ROUND(ST_Distance(d1.geog_point, d2.geog_point) -
          ST_Distance(ST_Transform(d1.geom_point, 3857), ST_Transform(d2.geom_point, 3857))) as difference_meters
FROM spatial_demo d1
CROSS JOIN spatial_demo d2
WHERE d1.location_name < d2.location_name;

-- =============================================================================
-- COORDINATE SYSTEM TRANSFORMATIONS
-- =============================================================================

-- Transform coordinates between different projections
WITH coordinate_transforms AS (
    SELECT
        poi.name,
        poi.location_geom as original_4326,
        -- Transform to Web Mercator (meters)
        ST_Transform(poi.location_geom, 3857) as web_mercator_3857,
        -- Transform to Texas State Plane North Central
        ST_Transform(poi.location_geom, 2276) as texas_state_plane_2276,
        -- Extract coordinates in different systems
        ST_X(poi.location_geom) as longitude_wgs84,
        ST_Y(poi.location_geom) as latitude_wgs84,
        ST_X(ST_Transform(poi.location_geom, 3857)) as x_web_mercator,
        ST_Y(ST_Transform(poi.location_geom, 3857)) as y_web_mercator
    FROM geo.points_of_interest poi
    LIMIT 5
)
SELECT
    name,
    ROUND(longitude_wgs84::NUMERIC, 6) as lng_wgs84,
    ROUND(latitude_wgs84::NUMERIC, 6) as lat_wgs84,
    ROUND(x_web_mercator::NUMERIC, 2) as x_mercator,
    ROUND(y_web_mercator::NUMERIC, 2) as y_mercator,
    -- Show the geometry in different formats
    ST_AsText(original_4326) as wkt_4326,
    ST_AsGeoJSON(original_4326)::json as geojson_4326
FROM coordinate_transforms;

-- =============================================================================
-- BASIC SPATIAL OPERATIONS
-- =============================================================================

-- Point-in-polygon queries (which POIs are in which neighborhoods)
SELECT
    nb.neighborhood_name,
    COUNT(poi.poi_id) as poi_count,
    STRING_AGG(poi.name, ', ' ORDER BY poi.name) as poi_list
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.points_of_interest poi ON ST_Contains(nb.boundary_geom, poi.location_geom)
GROUP BY nb.neighborhood_id, nb.neighborhood_name
ORDER BY poi_count DESC;

-- Buffer operations (find all POIs within 500m of stations)
SELECT
    s.station_name,
    s.station_type,
    COUNT(poi.poi_id) as nearby_pois,
    STRING_AGG(poi.name, ', ' ORDER BY poi.name) as poi_list
FROM mobility.stations s
LEFT JOIN geo.points_of_interest poi ON ST_DWithin(
    ST_Transform(ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326), 3857),
    ST_Transform(poi.location_geom, 3857),
    500  -- 500 meters
)
GROUP BY s.station_id, s.station_name, s.station_type
ORDER BY nearby_pois DESC;

-- =============================================================================
-- GEOMETRIC MEASUREMENTS AND CALCULATIONS
-- =============================================================================

-- Calculate area and perimeter of neighborhoods
SELECT
    neighborhood_name,
    -- Area in square kilometers
    ROUND((ST_Area(ST_Transform(boundary_geom, 3857)) / 1000000.0)::NUMERIC, 3) as area_sq_km,
    -- Perimeter in kilometers
    ROUND((ST_Perimeter(ST_Transform(boundary_geom, 3857)) / 1000.0)::NUMERIC, 3) as perimeter_km,
    -- Centroid coordinates
    ROUND(ST_X(ST_Centroid(boundary_geom))::NUMERIC, 6) as centroid_lng,
    ROUND(ST_Y(ST_Centroid(boundary_geom))::NUMERIC, 6) as centroid_lat,
    -- Bounding box
    ST_AsText(ST_Envelope(boundary_geom)) as bounding_box
FROM geo.neighborhood_boundaries
ORDER BY area_sq_km DESC;

-- Calculate road network statistics
SELECT
    nb.neighborhood_name,
    COUNT(rs.segment_id) as road_segments,
    -- Total length in kilometers
    ROUND(SUM(ST_Length(ST_Transform(rs.segment_geom, 3857)) / 1000.0)::NUMERIC, 2) as total_length_km,
    -- Average segment length
    ROUND(AVG(ST_Length(ST_Transform(rs.segment_geom, 3857)))::NUMERIC, 0) as avg_segment_length_m,
    -- Road density (km of road per sq km of area)
    ROUND((SUM(ST_Length(ST_Transform(rs.segment_geom, 3857)) / 1000.0) /
           (ST_Area(ST_Transform(nb.boundary_geom, 3857)) / 1000000.0))::NUMERIC, 1) as road_density_km_per_sq_km
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.road_segments rs ON ST_Intersects(nb.boundary_geom, rs.segment_geom)
GROUP BY nb.neighborhood_id, nb.neighborhood_name, nb.boundary_geom
ORDER BY road_density_km_per_sq_km DESC;

-- =============================================================================
-- SPATIAL RELATIONSHIP FUNCTIONS
-- =============================================================================

-- Demonstrate various spatial relationships
WITH spatial_relationships AS (
    SELECT
        poi1.name as poi1_name,
        poi2.name as poi2_name,
        ROUND(ST_Distance(ST_Transform(poi1.location_geom, 3857),
                         ST_Transform(poi2.location_geom, 3857))::NUMERIC, 0) as distance_meters,
        ST_DWithin(ST_Transform(poi1.location_geom, 3857),
                  ST_Transform(poi2.location_geom, 3857), 1000) as within_1km,
        ST_Equals(poi1.location_geom, poi2.location_geom) as same_location,
        -- Calculate bearing between points
        ROUND(degrees(ST_Azimuth(poi1.location_geom, poi2.location_geom))::NUMERIC, 1) as bearing_degrees
    FROM geo.points_of_interest poi1
    CROSS JOIN geo.points_of_interest poi2
    WHERE poi1.poi_id < poi2.poi_id
        AND poi1.category = 'restaurant'
        AND poi2.category = 'restaurant'
)
SELECT
    poi1_name,
    poi2_name,
    distance_meters,
    within_1km,
    bearing_degrees,
    CASE
        WHEN bearing_degrees BETWEEN 0 AND 22.5 OR bearing_degrees > 337.5 THEN 'North'
        WHEN bearing_degrees BETWEEN 22.5 AND 67.5 THEN 'Northeast'
        WHEN bearing_degrees BETWEEN 67.5 AND 112.5 THEN 'East'
        WHEN bearing_degrees BETWEEN 112.5 AND 157.5 THEN 'Southeast'
        WHEN bearing_degrees BETWEEN 157.5 AND 202.5 THEN 'South'
        WHEN bearing_degrees BETWEEN 202.5 AND 247.5 THEN 'Southwest'
        WHEN bearing_degrees BETWEEN 247.5 AND 292.5 THEN 'West'
        WHEN bearing_degrees BETWEEN 292.5 AND 337.5 THEN 'Northwest'
    END as direction
FROM spatial_relationships
WHERE distance_meters < 2000  -- Within 2km
ORDER BY distance_meters;

-- =============================================================================
-- COORDINATE VALIDATION FUNCTIONS
-- =============================================================================

-- Function to validate coordinates are within reasonable bounds
CREATE OR REPLACE FUNCTION geo.validate_coordinates(
    latitude DECIMAL(10,8),
    longitude DECIMAL(11,8),
    region_bounds GEOMETRY DEFAULT NULL
)
RETURNS TABLE(
    is_valid BOOLEAN,
    validation_message TEXT,
    suggested_srid INTEGER
) AS $$
DECLARE
    test_point GEOMETRY;
    texas_bounds GEOMETRY;
BEGIN
    -- Basic coordinate range validation
    IF latitude < -90 OR latitude > 90 OR longitude < -180 OR longitude > 180 THEN
        RETURN QUERY SELECT false, 'Coordinates outside valid range', NULL::INTEGER;
        RETURN;
    END IF;

    -- Create point geometry
    test_point := ST_SetSRID(ST_Point(longitude, latitude), 4326);

    -- Texas approximate bounds for regional validation
    texas_bounds := ST_GeomFromText('POLYGON((-106.65 25.84, -106.65 36.5, -93.51 36.5, -93.51 25.84, -106.65 25.84))', 4326);

    -- Check if point is within Texas (assuming this is for Texas city)
    IF NOT ST_Contains(texas_bounds, test_point) THEN
        RETURN QUERY SELECT true, 'Coordinates valid but outside Texas region', 4326;
        RETURN;
    END IF;

    -- Check against custom region bounds if provided
    IF region_bounds IS NOT NULL THEN
        IF NOT ST_Contains(region_bounds, test_point) THEN
            RETURN QUERY SELECT true, 'Coordinates valid but outside specified region', 4326;
            RETURN;
        END IF;
    END IF;

    -- All validations passed
    RETURN QUERY SELECT true, 'Coordinates valid', 4326;
END;
$$ LANGUAGE plpgsql;

-- Function to convert between coordinate formats
CREATE OR REPLACE FUNCTION geo.convert_coordinate_format(
    input_value TEXT,
    input_format TEXT,  -- 'dms', 'dm', 'dd'
    output_format TEXT DEFAULT 'dd'
)
RETURNS NUMERIC AS $$
DECLARE
    decimal_degrees NUMERIC;
    degrees INTEGER;
    minutes INTEGER;
    seconds NUMERIC;
BEGIN
    CASE input_format
        WHEN 'dd' THEN -- Decimal degrees
            decimal_degrees := input_value::NUMERIC;
        WHEN 'dms' THEN -- Degrees, minutes, seconds (e.g., "32°46'40.2"N")
            -- This is a simplified parser - production would need more robust parsing
            decimal_degrees := input_value::NUMERIC; -- Placeholder
        WHEN 'dm' THEN -- Degrees, decimal minutes
            decimal_degrees := input_value::NUMERIC; -- Placeholder
        ELSE
            RAISE EXCEPTION 'Unsupported input format: %', input_format;
    END CASE;

    -- Convert to requested output format
    CASE output_format
        WHEN 'dd' THEN
            RETURN decimal_degrees;
        ELSE
            RAISE EXCEPTION 'Unsupported output format: %', output_format;
    END CASE;
END;
$$ LANGUAGE plpgsql;
