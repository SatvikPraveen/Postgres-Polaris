-- File: sql/07_geospatial/spatial_indexes_queries.sql
-- Purpose: KNN, buffers, intersections, and spatial query optimization

-- =============================================================================
-- K-NEAREST NEIGHBOR (KNN) QUERIES
-- =============================================================================

-- Find 5 nearest POIs to a given point using KNN (<-> operator)
SELECT
    poi.name,
    poi.category,
    poi.street_address,
    -- Distance in meters using geography
    ROUND(ST_Distance(poi.location_geom::geography, ST_SetSRID(ST_Point(-96.8040, 32.9855), 4326)::geography)) as distance_meters,
    -- KNN distance (for ordering)
    poi.location_geom <-> ST_SetSRID(ST_Point(-96.8040, 32.9855), 4326) as knn_distance
FROM geo.points_of_interest poi
WHERE poi.is_active = true
ORDER BY poi.location_geom <-> ST_SetSRID(ST_Point(-96.8040, 32.9855), 4326)
LIMIT 5;

-- Find nearest POI of each category to city hall
WITH city_hall AS (
    SELECT ST_SetSRID(ST_Point(-96.8040, 32.9855), 4326) as location
),
ranked_pois AS (
    SELECT
        poi.name,
        poi.category,
        poi.street_address,
        ST_Distance(poi.location_geom::geography, ch.location::geography) as distance_meters,
        ROW_NUMBER() OVER (PARTITION BY poi.category ORDER BY poi.location_geom <-> ch.location) as rn
    FROM geo.points_of_interest poi
    CROSS JOIN city_hall ch
    WHERE poi.is_active = true
)
SELECT
    category,
    name,
    street_address,
    ROUND(distance_meters) as distance_meters
FROM ranked_pois
WHERE rn = 1
ORDER BY distance_meters;

-- =============================================================================
-- BUFFER OPERATIONS
-- =============================================================================

-- Find all POIs within 1km buffer of transit stations
SELECT
    s.station_name,
    s.station_type,
    COUNT(poi.poi_id) as pois_within_1km,
    STRING_AGG(poi.name, ', ' ORDER BY poi.name) as poi_names
FROM mobility.stations s
LEFT JOIN geo.points_of_interest poi ON ST_DWithin(
    ST_Transform(ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326), 3857),
    ST_Transform(poi.location_geom, 3857),
    1000  -- 1000 meters
)
WHERE poi.is_active = true OR poi.poi_id IS NULL
GROUP BY s.station_id, s.station_name, s.station_type
ORDER BY pois_within_1km DESC;

-- Create walkability analysis with multiple buffer zones
WITH station_buffers AS (
    SELECT
        s.station_id,
        s.station_name,
        s.station_type,
        ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326) as station_point,
        ST_Buffer(ST_Transform(ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326), 3857), 400) as walk_buffer_400m,
        ST_Buffer(ST_Transform(ST_SetSRID(ST_Point(s.longitude, s.latitude), 4326), 3857), 800) as walk_buffer_800m
    FROM mobility.stations s
    WHERE s.status = 'active'
)
SELECT
    sb.station_name,
    sb.station_type,
    COUNT(CASE WHEN ST_Contains(ST_Transform(sb.walk_buffer_400m, 4326), poi.location_geom) THEN 1 END) as pois_within_400m,
    COUNT(CASE WHEN ST_Contains(ST_Transform(sb.walk_buffer_800m, 4326), poi.location_geom)
               AND NOT ST_Contains(ST_Transform(sb.walk_buffer_400m, 4326), poi.location_geom) THEN 1 END) as pois_400m_to_800m,
    COUNT(poi.poi_id) as total_within_800m
FROM station_buffers sb
LEFT JOIN geo.points_of_interest poi ON ST_Contains(ST_Transform(sb.walk_buffer_800m, 4326), poi.location_geom)
WHERE poi.is_active = true OR poi.poi_id IS NULL
GROUP BY sb.station_id, sb.station_name, sb.station_type
ORDER BY total_within_800m DESC;

-- =============================================================================
-- INTERSECTION OPERATIONS
-- =============================================================================

-- Find which roads intersect with each neighborhood
SELECT
    nb.neighborhood_name,
    COUNT(rs.segment_id) as intersecting_roads,
    COUNT(CASE WHEN rs.road_type = 'arterial' THEN 1 END) as arterial_roads,
    COUNT(CASE WHEN rs.road_type = 'local' THEN 1 END) as local_roads,
    -- Total road length within neighborhood (km)
    ROUND(
        SUM(ST_Length(ST_Intersection(
            ST_Transform(nb.boundary_geom, 3857),
            ST_Transform(rs.segment_geom, 3857)
        ))) / 1000.0, 2
    ) as total_road_length_km
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.road_segments rs ON ST_Intersects(nb.boundary_geom, rs.segment_geom)
GROUP BY nb.neighborhood_id, nb.neighborhood_name
ORDER BY total_road_length_km DESC;

-- Find POIs that are within 100m of major roads
WITH major_roads AS (
    SELECT
        rs.segment_id,
        rs.road_name,
        rs.road_type,
        ST_Buffer(ST_Transform(rs.segment_geom, 3857), 100) as road_buffer_100m
    FROM geo.road_segments rs
    WHERE rs.road_type IN ('arterial', 'highway', 'collector')
)
SELECT
    poi.name,
    poi.category,
    mr.road_name,
    mr.road_type,
    -- Exact distance to road centerline
    ROUND(ST_Distance(
        ST_Transform(poi.location_geom, 3857),
        ST_Transform(rs.segment_geom, 3857)
    )) as distance_to_road_meters
FROM geo.points_of_interest poi
JOIN major_roads mr ON ST_Contains(mr.road_buffer_100m, ST_Transform(poi.location_geom, 3857))
JOIN geo.road_segments rs ON mr.segment_id = rs.segment_id
WHERE poi.is_active = true
ORDER BY poi.category, distance_to_road_meters;

-- =============================================================================
-- SPATIAL AGGREGATIONS
-- =============================================================================

-- Density analysis: POIs per square kilometer by neighborhood
SELECT
    nb.neighborhood_name,
    nb.area_sq_km,
    COUNT(poi.poi_id) as poi_count,
    ROUND(COUNT(poi.poi_id)::NUMERIC / NULLIF(nb.area_sq_km, 0), 2) as poi_density_per_sq_km,
    -- Breakdown by category
    COUNT(CASE WHEN poi.category = 'restaurant' THEN 1 END) as restaurants,
    COUNT(CASE WHEN poi.category = 'retail' THEN 1 END) as retail,
    COUNT(CASE WHEN poi.category = 'government' THEN 1 END) as government,
    COUNT(CASE WHEN poi.category = 'park' THEN 1 END) as parks
FROM geo.neighborhood_boundaries nb
LEFT JOIN geo.points_of_interest poi ON ST_Contains(nb.boundary_geom, poi.location_geom)
    AND poi.is_active = true
GROUP BY nb.neighborhood_id, nb.neighborhood_name, nb.area_sq_km
ORDER BY poi_density_per_sq_km DESC;

-- Service coverage analysis: percentage of neighborhood area within 500m of essential services
WITH essential_services AS (
    SELECT location_geom
    FROM geo.points_of_interest
    WHERE category IN ('hospital', 'school', 'library', 'government')
        AND is_active = true
),
service_buffers AS (
    SELECT ST_Union(ST_Buffer(ST_Transform(location_geom, 3857), 500)) as coverage_area
    FROM essential_services
)
SELECT
    nb.neighborhood_name,
    nb.area_sq_km,
    -- Calculate coverage percentage
    ROUND(
        (ST_Area(ST_Intersection(
            ST_Transform(nb.boundary_geom, 3857),
            sb.coverage_area
        )) / ST_Area(ST_Transform(nb.boundary_geom, 3857))) * 100, 1
    ) as service_coverage_pct,
    -- Check if entire neighborhood is covered
    ST_Contains(sb.coverage_area, ST_Transform(nb.boundary_geom, 3857)) as fully_covered
FROM geo.neighborhood_boundaries nb
CROSS JOIN service_buffers sb
ORDER BY service_coverage_pct DESC;

-- =============================================================================
-- SPATIAL CLUSTERING ANALYSIS
-- =============================================================================

-- Find clusters of restaurants using ST_ClusterDBSCAN
WITH restaurant_clusters AS (
    SELECT
        poi.poi_id,
        poi.name,
        poi.location_geom,
        -- Cluster restaurants within 200m of each other (minimum 3 in cluster)
        ST_ClusterDBSCAN(ST_Transform(poi.location_geom, 3857), 200, 3) OVER () as cluster_id
    FROM geo.points_of_interest poi
    WHERE poi.category = 'restaurant' AND poi.is_active = true
)
SELECT
    cluster_id,
    COUNT(*) as restaurants_in_cluster,
    STRING_AGG(name, ', ' ORDER BY name) as restaurant_names,
    -- Calculate cluster centroid
    ST_AsText(ST_Centroid(ST_Collect(location_geom))) as cluster_center,
    -- Calculate cluster area (convex hull)
    ROUND(ST_Area(ST_Transform(ST_ConvexHull(ST_Collect(location_geom)), 3857))) as cluster_area_sq_meters
FROM restaurant_clusters
WHERE cluster_id IS NOT NULL
GROUP BY cluster_id
ORDER BY restaurants_in_cluster DESC;

-- =============================================================================
-- ADVANCED SPATIAL QUERIES
-- =============================================================================

-- Find the most "central" POI in each category (closest to neighborhood geometric center)
WITH neighborhood_centers AS (
    SELECT
        neighborhood_id,
        neighborhood_name,
        ST_Centroid(boundary_geom) as center_point
    FROM geo.neighborhood_boundaries
),
poi_distances_to_centers AS (
    SELECT
        poi.poi_id,
        poi.name,
        poi.category,
        nc.neighborhood_name,
        ST_Distance(poi.location_geom::geography, nc.center_point::geography) as distance_to_center,
        ROW_NUMBER() OVER (PARTITION BY nc.neighborhood_id, poi.category
                          ORDER BY poi.location_geom <-> nc.center_point) as centrality_rank
    FROM geo.points_of_interest poi
    JOIN neighborhood_centers nc ON ST_Contains(
        (SELECT boundary_geom FROM geo.neighborhood_boundaries WHERE neighborhood_id = nc.neighborhood_id),
        poi.location_geom
    )
    WHERE poi.is_active = true
)
SELECT
    neighborhood_name,
    category,
    name as most_central_poi,
    ROUND(distance_to_center) as distance_from_center_meters
FROM poi_distances_to_centers
WHERE centrality_rank = 1
    AND category IN ('restaurant', 'retail', 'park', 'school')
ORDER BY neighborhood_name, category;

-- Accessibility analysis: Find underserved areas (far from any POI)
WITH poi_coverage AS (
    SELECT ST_Union(ST_Buffer(ST_Transform(location_geom, 3857), 800)) as covered_area
    FROM geo.points_of_interest
    WHERE category IN ('restaurant', 'retail', 'school', 'hospital', 'library')
        AND is_active = true
),
underserved_areas AS (
    SELECT
        nb.neighborhood_id,
        nb.neighborhood_name,
        -- Calculate underserved area
        ST_Difference(ST_Transform(nb.boundary_geom, 3857), pc.covered_area) as underserved_geom
    FROM geo.neighborhood_boundaries nb
    CROSS JOIN poi_coverage pc
)
SELECT
    neighborhood_name,
    -- Convert back to WGS84 for display
    ST_AsGeoJSON(ST_Transform(underserved_geom, 4326))::json as underserved_areas_geojson,
    ROUND(ST_Area(underserved_geom) / 1000000.0, 3) as underserved_area_sq_km,
    ROUND(ST_Area(underserved_geom) * 100.0 /
          ST_Area(ST_Transform((SELECT boundary_geom FROM geo.neighborhood_boundaries WHERE neighborhood_id = ua.neighborhood_id), 3857)), 1) as underserved_pct
FROM underserved_areas ua
WHERE ST_Area(underserved_geom) > 10000  -- Only show areas > 10,000 sq meters
ORDER BY underserved_area_sq_km DESC;
