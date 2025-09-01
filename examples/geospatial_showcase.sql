-- Location: /examples/geospatial_showcase.sql
-- PostGIS capabilities demonstration

SELECT '🗺️ Geospatial Showcase - PostGIS Capabilities' as title;

-- Check PostGIS availability
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_extension WHERE extname = 'postgis') THEN
        RAISE EXCEPTION 'PostGIS extension required. Run: CREATE EXTENSION postgis;';
    END IF;
    RAISE NOTICE '✓ PostGIS version: %', postgis_version();
END $$;

-- Demo 1: Spatial Data Overview
SELECT 'Demo 1: Spatial Features Overview' as demo;

SELECT
    properties->>'type' as feature_type,
    COUNT(*) as feature_count,
    AVG(ST_Area(geometry))::decimal(10,6) as avg_area_sq_degrees,
    AVG(ST_Perimeter(geometry))::decimal(10,6) as avg_perimeter,
    ST_AsText(ST_Centroid(ST_Union(geometry))) as center_point
FROM spatial_features
WHERE geometry IS NOT NULL
GROUP BY properties->>'type'
ORDER BY feature_count DESC;

-- Demo 2: Distance Analysis
SELECT 'Demo 2: Distance Analysis - Nearest Neighbors' as demo;

WITH downtown_center AS (
    SELECT geometry as center_geom
    FROM spatial_features
    WHERE properties->>'name' = 'Downtown District'
    LIMIT 1
)
SELECT
    sf.properties->>'name' as feature_name,
    sf.properties->>'type' as feature_type,
    ST_Distance(sf.geometry, dc.center_geom)::decimal(8,6) as distance_degrees,
    ST_Distance(
        ST_Transform(sf.geometry, 3857),
        ST_Transform(dc.center_geom, 3857)
    )::decimal(10,2) as distance_meters
FROM spatial_features sf
CROSS JOIN downtown_center dc
WHERE sf.properties->>'name' != 'Downtown District'
ORDER BY ST_Distance(sf.geometry, dc.center_geom)
LIMIT 10;

-- Demo 3: Spatial Relationships
SELECT 'Demo 3: Spatial Relationships - Points Within Neighborhoods' as demo;

WITH neighborhoods AS (
    SELECT properties->>'name' as neighborhood_name, geometry
    FROM spatial_features
    WHERE properties->>'type' = 'neighborhood'
),
points_of_interest AS (
    SELECT properties->>'name' as poi_name, properties->>'type' as poi_type, geometry
    FROM spatial_features
    WHERE geometry IS NOT NULL
    AND ST_GeometryType(geometry) = 'ST_Point'
)
SELECT
    n.neighborhood_name,
    COUNT(p.poi_name) as poi_count,
    STRING_AGG(p.poi_name || ' (' || p.poi_type || ')', ', ') as pois_within
FROM neighborhoods n
LEFT JOIN points_of_interest p ON ST_Contains(n.geometry, p.geometry)
GROUP BY n.neighborhood_name, n.geometry
ORDER BY poi_count DESC;

-- Demo 4: Buffer Analysis
SELECT 'Demo 4: Buffer Analysis - Service Areas' as demo;

SELECT
    properties->>'name' as station_name,
    properties->>'type' as station_type,
    ST_Area(ST_Buffer(geometry, 0.01))::decimal(10,6) as service_area_1km_sq_degrees,
    ST_AsText(ST_Centroid(ST_Buffer(geometry, 0.005))) as half_km_buffer_center
FROM spatial_features
WHERE properties->>'type' IN ('transit_hub', 'emergency_services')
AND ST_GeometryType(geometry) = 'ST_Point'
ORDER BY properties->>'name';

-- Demo 5: Spatial Aggregation
SELECT 'Demo 5: Spatial Aggregation - Convex Hull and Union' as demo;

SELECT
    properties->>'type' as feature_type,
    COUNT(*) as feature_count,
    ST_AsText(ST_Centroid(ST_Union(geometry))) as aggregated_centroid,
    ST_Area(ST_ConvexHull(ST_Union(geometry)))::decimal(10,6) as convex_hull_area,
    ST_Area(ST_Union(geometry))::decimal(10,6) as total_area
FROM spatial_features
WHERE geometry IS NOT NULL
GROUP BY properties->>'type'
HAVING COUNT(*) > 1;

-- Demo 6: Route Analysis
SELECT 'Demo 6: Route Analysis - Transit Line Properties' as demo;

SELECT
    properties->>'name' as route_name,
    properties->>'route_id' as route_id,
    ST_Length(geometry)::decimal(10,6) as length_degrees,
    ST_Length(ST_Transform(geometry, 3857))::decimal(10,2) as length_meters,
    ST_NumPoints(geometry) as waypoint_count,
    ST_AsText(ST_StartPoint(geometry)) as start_point,
    ST_AsText(ST_EndPoint(geometry)) as end_point
FROM spatial_features
WHERE properties->>'type' = 'transit_route'
AND ST_GeometryType(geometry) = 'ST_LineString'
ORDER BY ST_Length(geometry) DESC;

-- Demo 7: Spatial Queries with Citizens
SELECT 'Demo 7: Citizen Location Analysis' as demo;

DO $$
DECLARE
    citizens_table_exists boolean;
BEGIN
    SELECT EXISTS (
        SELECT FROM information_schema.columns
        WHERE table_name = 'citizens'
        AND column_name IN ('latitude', 'longitude')
    ) INTO citizens_table_exists;

    IF citizens_table_exists THEN
        RAISE NOTICE 'Analyzing citizen locations with spatial queries...';

        -- Create temporary spatial view of citizens
        CREATE TEMP VIEW citizen_points AS
        SELECT
            citizen_id,
            name,
            city,
            ST_MakePoint(longitude, latitude) as location
        FROM citizens
        WHERE latitude IS NOT NULL AND longitude IS NOT NULL;

        -- Find citizens within neighborhoods
        FOR rec IN
            SELECT
                sf.properties->>'name' as neighborhood,
                COUNT(cp.citizen_id) as citizen_count
            FROM spatial_features sf
            LEFT JOIN citizen_points cp ON ST_Contains(sf.geometry, cp.location)
            WHERE sf.properties->>'type' = 'neighborhood'
            GROUP BY sf.properties->>'name'
            ORDER BY COUNT(cp.citizen_id) DESC
        LOOP
            RAISE NOTICE '  %: % citizens', rec.neighborhood, rec.citizen_count;
        END LOOP;
    ELSE
        RAISE NOTICE 'Citizens table does not have spatial coordinates';
    END IF;
END $$;

-- Demo 8: Accessibility Analysis
SELECT 'Demo 8: Accessibility Analysis - Service Coverage' as demo;

WITH service_buffers AS (
    SELECT
        properties->>'name' as service_name,
        properties->>'type' as service_type,
        ST_Buffer(geometry, 0.01) as service_area -- ~1km buffer
    FROM spatial_features
    WHERE properties->>'type' IN ('healthcare', 'education', 'emergency_services')
    AND ST_GeometryType(geometry) = 'ST_Point'
),
coverage_analysis AS (
    SELECT
        n.properties->>'name' as neighborhood,
        COUNT(sb.service_name) as services_within_1km,
        STRING_AGG(sb.service_name || ' (' || sb.service_type || ')', ', ') as available_services
    FROM spatial_features n
    LEFT JOIN service_buffers sb ON ST_Intersects(n.geometry, sb.service_area)
    WHERE n.properties->>'type' = 'neighborhood'
    GROUP BY n.properties->>'name'
)
SELECT
    neighborhood,
    services_within_1km,
    CASE
        WHEN services_within_1km >= 3 THEN 'Well Served'
        WHEN services_within_1km >= 1 THEN 'Moderately Served'
        ELSE 'Underserved'
    END as service_level,
    available_services
FROM coverage_analysis
ORDER BY services_within_1km DESC;

-- Demo 9: Geometric Calculations
SELECT 'Demo 9: Advanced Geometric Calculations' as demo;

WITH geometric_analysis AS (
    SELECT
        properties->>'name' as feature_name,
        properties->>'type' as feature_type,
        geometry,
        ST_GeometryType(geometry) as geometry_type,
        ST_Area(geometry) as area,
        ST_Perimeter(geometry) as perimeter,
        ST_Centroid(geometry) as centroid
    FROM spatial_features
    WHERE geometry IS NOT NULL
)
SELECT
    feature_name,
    feature_type,
    geometry_type,
    area::decimal(10,6) as area_sq_degrees,
    perimeter::decimal(10,6) as perimeter_degrees,
    CASE
        WHEN perimeter > 0 THEN (4 * PI() * area / (perimeter * perimeter))::decimal(6,4)
        ELSE NULL
    END as shape_compactness_ratio,
    ST_X(centroid)::decimal(8,6) as centroid_longitude,
    ST_Y(centroid)::decimal(8,6) as centroid_latitude
FROM geometric_analysis
WHERE area > 0
ORDER BY area DESC;

-- Demo 10: Spatial Indexing Performance Test
SELECT 'Demo 10: Spatial Index Performance Demonstration' as demo;

DO $$
DECLARE
    start_time timestamp;
    end_time timestamp;
    duration_ms numeric;
    result_count integer;
BEGIN
    RAISE NOTICE 'Testing spatial query performance...';

    -- Test spatial intersection query
    start_time := clock_timestamp();

    SELECT COUNT(*) INTO result_count
    FROM spatial_features sf1
    JOIN spatial_features sf2 ON ST_Intersects(sf1.geometry, sf2.geometry)
    WHERE sf1.properties->>'type' = 'neighborhood'
    AND sf2.properties->>'type' != 'neighborhood';

    end_time := clock_timestamp();
    duration_ms := EXTRACT(milliseconds FROM end_time - start_time);

    RAISE NOTICE 'Spatial intersection query:';
    RAISE NOTICE '  Results found: %', result_count;
    RAISE NOTICE '  Execution time: % ms', duration_ms;

    IF duration_ms < 100 THEN
        RAISE NOTICE '  ✓ Good performance (spatial indexes working)';
    ELSE
        RAISE NOTICE '  ⚠ Consider adding spatial indexes for better performance';
    END IF;
END $$;

-- Summary and Spatial Analytics Recommendations
SELECT 'Geospatial Analysis Summary and Recommendations' as summary;

DO $$
DECLARE
    total_features integer;
    neighborhood_count integer;
    poi_count integer;
    route_count integer;
    avg_feature_area numeric;
BEGIN
    -- Get spatial data statistics
    SELECT COUNT(*) INTO total_features FROM spatial_features WHERE geometry IS NOT NULL;

    SELECT COUNT(*) INTO neighborhood_count
    FROM spatial_features WHERE properties->>'type' = 'neighborhood';

    SELECT COUNT(*) INTO poi_count
    FROM spatial_features WHERE ST_GeometryType(geometry) = 'ST_Point';

    SELECT COUNT(*) INTO route_count
    FROM spatial_features WHERE properties->>'type' = 'transit_route';

    SELECT AVG(ST_Area(geometry)) INTO avg_feature_area
    FROM spatial_features WHERE geometry IS NOT NULL;

    RAISE NOTICE '===========================================';
    RAISE NOTICE 'GEOSPATIAL ANALYSIS SUMMARY';
    RAISE NOTICE '===========================================';
    RAISE NOTICE 'Total Spatial Features: %', total_features;
    RAISE NOTICE 'Neighborhoods: %', neighborhood_count;
    RAISE NOTICE 'Points of Interest: %', poi_count;
    RAISE NOTICE 'Transit Routes: %', route_count;
    RAISE NOTICE 'Average Feature Area: % sq degrees', round(avg_feature_area::numeric, 6);
    RAISE NOTICE '';
    RAISE NOTICE 'Spatial Capabilities Demonstrated:';
    RAISE NOTICE '• Distance calculations and nearest neighbor analysis';
    RAISE NOTICE '• Spatial containment (points within polygons)';
    RAISE NOTICE '• Buffer analysis for service areas';
    RAISE NOTICE '• Geometric aggregation (union, convex hull)';
    RAISE NOTICE '• Route analysis with line string geometry';
    RAISE NOTICE '• Accessibility and coverage analysis';
    RAISE NOTICE '• Advanced geometric calculations';
    RAISE NOTICE '• Spatial indexing performance optimization';
    RAISE NOTICE '';
    RAISE NOTICE 'Recommended Applications:';
    RAISE NOTICE '• Location-based service optimization';
    RAISE NOTICE '• Urban planning and zoning analysis';
    RAISE NOTICE '• Emergency response optimization';
    RAISE NOTICE '• Retail site selection analysis';
    RAISE NOTICE '• Transportation network analysis';
    RAISE NOTICE '• Environmental impact studies';
    RAISE NOTICE '===========================================';
END $$;
