-- File: sql/07_geospatial/routing_nearest.sql
-- Purpose: Nearest POI analysis, reachability demos, and routing foundations

-- =============================================================================
-- NEAREST POI ANALYSIS
-- =============================================================================

-- Find nearest essential services for each citizen
CREATE OR REPLACE FUNCTION geo.find_nearest_services(
    citizen_lat DECIMAL(10,8),
    citizen_lng DECIMAL(11,8),
    service_types TEXT[] DEFAULT ARRAY['hospital', 'school', 'library', 'government']
)
RETURNS TABLE(
    service_type TEXT,
    poi_name TEXT,
    distance_meters INTEGER,
    street_address TEXT,
    phone TEXT,
    coordinates TEXT
) AS $$
DECLARE
    citizen_point GEOMETRY;
BEGIN
    citizen_point := ST_SetSRID(ST_Point(citizen_lng, citizen_lat), 4326);

    RETURN QUERY
    WITH ranked_services AS (
        SELECT
            poi.category::TEXT as service_type,
            poi.name as poi_name,
            ST_Distance(poi.location_geom::geography, citizen_point::geography) as distance_meters,
            poi.street_address,
            poi.phone,
            ST_X(poi.location_geom) || ',' || ST_Y(poi.location_geom) as coordinates,
            ROW_NUMBER() OVER (PARTITION BY poi.category ORDER BY poi.location_geom <-> citizen_point) as rn
        FROM geo.points_of_interest poi
        WHERE poi.category = ANY(service_types)
            AND poi.is_active = true
    )
    SELECT
        rs.service_type,
        rs.poi_name,
        rs.distance_meters::INTEGER,
        rs.street_address,
        rs.phone,
        rs.coordinates
    FROM ranked_services rs
    WHERE rs.rn = 1
    ORDER BY rs.distance_meters;
END;
$$ LANGUAGE plpgsql;

-- Find service gaps - areas far from essential services
CREATE OR REPLACE FUNCTION geo.analyze_service_gaps(
    max_acceptable_distance_meters INTEGER DEFAULT 1000
)
RETURNS TABLE(
    neighborhood_name TEXT,
    service_type TEXT,
    avg_distance_to_nearest NUMERIC,
    max_distance_to_nearest NUMERIC,
    citizens_underserved BIGINT
) AS $$
BEGIN
    RETURN QUERY
    WITH citizen_service_distances AS (
        SELECT
            c.citizen_id,
            c.zip_code,
            poi.category as service_type,
            MIN(ST_Distance(
                ST_SetSRID(ST_Point(
                    CASE WHEN c.street_address LIKE '%Main%' THEN -96.8040 ELSE -96.7950 END,
                    CASE WHEN c.zip_code = '75032' THEN 32.9850 ELSE 32.9800 END
                ), 4326)::geography,
                poi.location_geom::geography
            )) as distance_to_nearest
        FROM civics.citizens c
        CROSS JOIN geo.points_of_interest poi
        WHERE c.status = 'active'
            AND poi.category IN ('hospital', 'school', 'library', 'government')
            AND poi.is_active = true
        GROUP BY c.citizen_id, c.zip_code, poi.category
    ),
    neighborhood_mapping AS (
        SELECT
            nb.neighborhood_name,
            csd.service_type,
            AVG(csd.distance_to_nearest) as avg_distance,
            MAX(csd.distance_to_nearest) as max_distance,
            COUNT(*) FILTER (WHERE csd.distance_to_nearest > max_acceptable_distance_meters) as underserved_count
        FROM citizen_service_distances csd
        JOIN geo.neighborhood_boundaries nb ON nb.neighborhood_name LIKE '%' -- Simplified mapping
        GROUP BY nb.neighborhood_name, csd.service_type
    )
    SELECT
        nm.neighborhood_name,
        nm.service_type,
        ROUND(nm.avg_distance, 0) as avg_distance_to_nearest,
        ROUND(nm.max_distance, 0) as max_distance_to_nearest,
        nm.underserved_count as citizens_underserved
    FROM neighborhood_mapping nm
    WHERE nm.underserved_count > 0
    ORDER BY nm.underserved_count DESC, nm.max_distance DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- REACHABILITY ANALYSIS
-- =============================================================================

-- Calculate walkable area from transit stations
CREATE OR REPLACE FUNCTION geo.calculate_walkable_area(
    station_lat DECIMAL(10,8),
    station_lng DECIMAL(11,8),
    walk_distance_meters INTEGER DEFAULT 800
)
RETURNS TABLE(
    reachable_pois INTEGER,
    reachable_area_sq_km NUMERIC,
    poi_categories TEXT,
    population_served INTEGER
) AS $$
DECLARE
    station_point GEOMETRY;
    walkable_buffer GEOMETRY;
BEGIN
    station_point := ST_SetSRID(ST_Point(station_lng, station_lat), 4326);
    walkable_buffer := ST_Buffer(ST_Transform(station_point, 3857), walk_distance_meters);

    RETURN QUERY
    SELECT
        COUNT(poi.poi_id)::INTEGER as reachable_pois,
        ROUND(ST_Area(walkable_buffer) / 1000000.0, 3) as reachable_area_sq_km,
        STRING_AGG(DISTINCT poi.category, ', ' ORDER BY poi.category) as poi_categories,
        -- Estimate population served (simplified calculation)
        ROUND(ST_Area(walkable_buffer) / 1000000.0 * 2000)::INTEGER as population_served
    FROM geo.points_of_interest poi
    WHERE ST_Contains(walkable_buffer, ST_Transform(poi.location_geom, 3857))
        AND poi.is_active = true;
END;
$$ LANGUAGE plpgsql;

-- Multi-modal reachability analysis
CREATE OR REPLACE FUNCTION geo.analyze_multimodal_access(
    origin_lat DECIMAL(10,8),
    origin_lng DECIMAL(11,8)
)
RETURNS TABLE(
    access_mode TEXT,
    reachable_stations INTEGER,
    nearest_station_name TEXT,
    nearest_station_distance_m INTEGER,
    total_pois_reachable INTEGER
) AS $$
DECLARE
    origin_point GEOMETRY;
BEGIN
    origin_point := ST_SetSRID(ST_Point(origin_lng, origin_lat), 4326);

    RETURN QUERY
    -- Walking access
    SELECT
        'Walking (800m)'::TEXT as access_mode,
        COUNT(DISTINCT s.station_id)::INTEGER as reachable_stations,
        (SELECT station_name FROM mobility.stations
         ORDER BY ST_SetSRID(ST_Point(longitude, latitude), 4326) <-> origin_point
         LIMIT 1) as nearest_station_name,
        (SELECT ROUND(ST_Distance(
            ST_SetSRID(ST_Point(longitude, latitude), 4326)::geography,
            origin_point::geography
        ))::INTEGER FROM mobility.stations
         ORDER BY ST_SetSRID(ST_Point(longitude, latitude), 4326) <-> origin_point
         LIMIT 1) as nearest_station_distance_m,
        (SELECT COUNT(*)::INTEGER FROM geo.points_of_interest poi
         WHERE ST_DWithin(ST_Transform(poi.location_geom, 3857), ST_Transform(origin_point, 3857), 800)
           AND poi.is_active = true) as total_pois_reachable
    FROM mobility.stations s
    WHERE ST_DWithin(
        ST_Transform(ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326), 3857),
        ST_Transform(origin_point, 3857),
        800
    )

    UNION ALL

    -- Cycling access
    SELECT
        'Cycling (2000m)'::TEXT as access_mode,
        COUNT(DISTINCT s.station_id)::INTEGER as reachable_stations,
        (SELECT station_name FROM mobility.stations
         WHERE station_type = 'bike_share'
         ORDER BY ST_SetSRID(ST_Point(longitude, latitude), 4326) <-> origin_point
         LIMIT 1) as nearest_station_name,
        (SELECT ROUND(ST_Distance(
            ST_SetSRID(ST_Point(longitude, latitude), 4326)::geography,
            origin_point::geography
        ))::INTEGER FROM mobility.stations
         WHERE station_type = 'bike_share'
         ORDER BY ST_SetSRID(ST_Point(longitude, latitude), 4326) <-> origin_point
         LIMIT 1) as nearest_station_distance_m,
        (SELECT COUNT(*)::INTEGER FROM geo.points_of_interest poi
         WHERE ST_DWithin(ST_Transform(poi.location_geom, 3857), ST_Transform(origin_point, 3857), 2000)
           AND poi.is_active = true) as total_pois_reachable
    FROM mobility.stations s
    WHERE ST_DWithin(
        ST_Transform(ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326), 3857),
        ST_Transform(origin_point, 3857),
        2000
    )
    ORDER BY access_mode;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SIMPLE ROUTING FOUNDATIONS
-- =============================================================================

-- Calculate straight-line routes between points
CREATE OR REPLACE FUNCTION geo.calculate_straight_line_route(
    start_lat DECIMAL(10,8),
    start_lng DECIMAL(11,8),
    end_lat DECIMAL(10,8),
    end_lng DECIMAL(11,8)
)
RETURNS TABLE(
    route_geojson TEXT,
    distance_meters INTEGER,
    bearing_degrees NUMERIC,
    estimated_walk_minutes INTEGER,
    estimated_bike_minutes INTEGER,
    waypoints_crossed INTEGER
) AS $$
DECLARE
    start_point GEOMETRY;
    end_point GEOMETRY;
    route_line GEOMETRY;
    route_distance NUMERIC;
    route_bearing NUMERIC;
BEGIN
    start_point := ST_SetSRID(ST_Point(start_lng, start_lat), 4326);
    end_point := ST_SetSRID(ST_Point(end_lng, end_lat), 4326);
    route_line := ST_MakeLine(start_point, end_point);

    route_distance := ST_Distance(start_point::geography, end_point::geography);
    route_bearing := degrees(ST_Azimuth(start_point, end_point));

    RETURN QUERY
    SELECT
        ST_AsGeoJSON(route_line)::TEXT as route_geojson,
        route_distance::INTEGER as distance_meters,
        ROUND(route_bearing, 1) as bearing_degrees,
        ROUND(route_distance / 80)::INTEGER as estimated_walk_minutes,  -- 4.8 km/h walking speed
        ROUND(route_distance / 250)::INTEGER as estimated_bike_minutes, -- 15 km/h cycling speed
        (SELECT COUNT(*)::INTEGER
         FROM geo.points_of_interest poi
         WHERE ST_DWithin(poi.location_geom, route_line, 0.001)) as waypoints_crossed;
END;
$$ LANGUAGE plpgsql;

-- Find optimal station-to-station connections
CREATE OR REPLACE FUNCTION geo.find_station_connections(
    max_distance_meters INTEGER DEFAULT 2000
)
RETURNS TABLE(
    from_station TEXT,
    to_station TEXT,
    connection_type TEXT,
    distance_meters INTEGER,
    estimated_time_minutes INTEGER,
    poi_count_along_route INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s1.station_name as from_station,
        s2.station_name as to_station,
        CASE
            WHEN s1.station_type = 'bike_share' AND s2.station_type = 'bike_share' THEN 'Bike-to-Bike'
            WHEN s1.station_type = 'bus' AND s2.station_type = 'rail' THEN 'Bus-to-Rail'
            WHEN s1.station_type = 'rail' AND s2.station_type = 'bus' THEN 'Rail-to-Bus'
            ELSE 'Multi-Modal'
        END as connection_type,
        ROUND(ST_Distance(
            ST_SetSRID(ST_Point(s1.longitude, s1.latitude), 4326)::geography,
            ST_SetSRID(ST_Point(s2.longitude, s2.latitude), 4326)::geography
        ))::INTEGER as distance_meters,
        CASE
            WHEN s1.station_type = 'bike_share' OR s2.station_type = 'bike_share'
            THEN ROUND(ST_Distance(
                ST_SetSRID(ST_Point(s1.longitude, s1.latitude), 4326)::geography,
                ST_SetSRID(ST_Point(s2.longitude, s2.latitude), 4326)::geography
            ) / 250)::INTEGER  -- 15 km/h cycling
            ELSE ROUND(ST_Distance(
                ST_SetSRID(ST_Point(s1.longitude, s1.latitude), 4326)::geography,
                ST_SetSRID(ST_Point(s2.longitude, s2.latitude), 4326)::geography
            ) / 80)::INTEGER   -- 4.8 km/h walking
        END as estimated_time_minutes,
        (SELECT COUNT(*)::INTEGER
         FROM geo.points_of_interest poi
         WHERE ST_DWithin(poi.location_geom,
               ST_MakeLine(
                   ST_SetSRID(ST_Point(s1.longitude, s1.latitude), 4326),
                   ST_SetSRID(ST_Point(s2.longitude, s2.latitude), 4326)
               ), 0.002)) as poi_count_along_route
    FROM mobility.stations s1
    CROSS JOIN mobility.stations s2
    WHERE s1.station_id < s2.station_id  -- Avoid duplicates
        AND s1.status = 'active' AND s2.status = 'active'
        AND ST_Distance(
            ST_SetSRID(ST_Point(s1.longitude, s1.latitude), 4326)::geography,
            ST_SetSRID(ST_Point(s2.longitude, s2.latitude), 4326)::geography
        ) <= max_distance_meters
    ORDER BY distance_meters
    LIMIT 20;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ACCESSIBILITY SCORING
-- =============================================================================

-- Calculate accessibility score for locations
CREATE OR REPLACE FUNCTION geo.calculate_accessibility_score(
    location_lat DECIMAL(10,8),
    location_lng DECIMAL(11,8)
)
RETURNS TABLE(
    overall_score NUMERIC,
    transit_score NUMERIC,
    walkability_score NUMERIC,
    service_accessibility_score NUMERIC,
    score_breakdown JSONB
) AS $$
DECLARE
    location_point GEOMETRY;
    transit_count INTEGER;
    poi_count INTEGER;
    essential_services INTEGER;
    breakdown JSONB;
BEGIN
    location_point := ST_SetSRID(ST_Point(location_lng, location_lat), 4326);

    -- Count nearby transit stations (within 800m)
    SELECT COUNT(*) INTO transit_count
    FROM mobility.stations s
    WHERE ST_DWithin(
        ST_Transform(ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326), 3857),
        ST_Transform(location_point, 3857),
        800
    ) AND s.status = 'active';

    -- Count nearby POIs (within 1km)
    SELECT COUNT(*) INTO poi_count
    FROM geo.points_of_interest poi
    WHERE ST_DWithin(ST_Transform(poi.location_geom, 3857), ST_Transform(location_point, 3857), 1000)
        AND poi.is_active = true;

    -- Count essential services (within 1.5km)
    SELECT COUNT(*) INTO essential_services
    FROM geo.points_of_interest poi
    WHERE poi.category IN ('hospital', 'school', 'library', 'government')
        AND ST_DWithin(ST_Transform(poi.location_geom, 3857), ST_Transform(location_point, 3857), 1500)
        AND poi.is_active = true;

    -- Calculate component scores (0-100)
    breakdown := jsonb_build_object(
        'transit_stations_800m', transit_count,
        'pois_1km', poi_count,
        'essential_services_1500m', essential_services,
        'transit_score', LEAST(transit_count * 25, 100),
        'walkability_score', LEAST(poi_count * 5, 100),
        'service_score', LEAST(essential_services * 20, 100)
    );

    RETURN QUERY
    SELECT
        ROUND(((LEAST(transit_count * 25, 100) + LEAST(poi_count * 5, 100) + LEAST(essential_services * 20, 100)) / 3.0), 1) as overall_score,
        ROUND(LEAST(transit_count * 25, 100)::NUMERIC, 1) as transit_score,
        ROUND(LEAST(poi_count * 5, 100)::NUMERIC, 1) as walkability_score,
        ROUND(LEAST(essential_services * 20, 100)::NUMERIC, 1) as service_accessibility_score,
        breakdown as score_breakdown;
END;
$$ LANGUAGE plpgsql;
