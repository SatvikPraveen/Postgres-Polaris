-- File: sql/01_schema_design/geo.sql
-- Purpose: Geospatial data including neighborhoods, roads, POIs (geometry/geography)

-- =============================================================================
-- ENUMS AND TYPES
-- =============================================================================

CREATE TYPE geo.poi_category AS ENUM (
    'government', 'school', 'hospital', 'park', 'retail', 'restaurant',
    'bank', 'gas_station', 'library', 'community_center', 'worship',
    'emergency', 'transportation', 'utility', 'other'
);

CREATE TYPE geo.road_type AS ENUM (
    'interstate', 'highway', 'arterial', 'collector', 'local',
    'residential', 'alley', 'walkway', 'bike_lane'
);

CREATE TYPE geo.road_surface AS ENUM ('asphalt', 'concrete', 'gravel', 'dirt', 'cobblestone');

-- =============================================================================
-- NEIGHBORHOOD BOUNDARIES
-- =============================================================================

CREATE TABLE geo.neighborhood_boundaries (
    neighborhood_id BIGSERIAL PRIMARY KEY,

    -- Identification
    neighborhood_name VARCHAR(100) UNIQUE NOT NULL,
    official_name VARCHAR(100), -- May differ from common name
    neighborhood_code VARCHAR(10) UNIQUE,

    -- Geographic data (using PostGIS)
    boundary_geom GEOMETRY(POLYGON, 4326) NOT NULL,
    centroid_geom GEOMETRY(POINT, 4326),
    area_sq_km NUMERIC(10,4),

    -- Demographics (from census or city data)
    population_estimate INTEGER,
    household_count INTEGER,
    median_income NUMERIC(12,2),

    -- Administrative
    city_council_district INTEGER,
    school_district VARCHAR(50),
    police_beat VARCHAR(20),
    fire_district VARCHAR(20),

    -- Planning attributes
    zoning_primary VARCHAR(50),
    development_status VARCHAR(50), -- established, developing, redevelopment

    -- Metadata
    data_source VARCHAR(100),
    last_updated DATE DEFAULT CURRENT_DATE,

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE geo.neighborhood_boundaries IS
'Official neighborhood boundaries with demographic and administrative data.
Requires PostGIS extension. All geometries in WGS84 (SRID 4326)';

-- =============================================================================
-- ROAD SEGMENTS
-- =============================================================================

CREATE TABLE geo.road_segments (
    segment_id BIGSERIAL PRIMARY KEY,

    -- Road identification
    road_name VARCHAR(200),
    road_type geo.road_type NOT NULL,
    route_number VARCHAR(20), -- Highway/route numbers

    -- Addressing
    address_range_start INTEGER,
    address_range_end INTEGER,
    address_side CHAR(1), -- 'L', 'R', 'B' (both)
    zip_code_left VARCHAR(10),
    zip_code_right VARCHAR(10),

    -- Physical attributes
    road_surface geo.road_surface DEFAULT 'asphalt',
    lane_count INTEGER,
    speed_limit INTEGER, -- mph
    one_way BOOLEAN DEFAULT false,

    -- Geographic data
    segment_geom GEOMETRY(LINESTRING, 4326) NOT NULL,
    length_km NUMERIC(8,4),

    -- Infrastructure
    has_sidewalk BOOLEAN DEFAULT false,
    has_bike_lane BOOLEAN DEFAULT false,
    has_street_lighting BOOLEAN DEFAULT false,

    -- Administrative
    maintenance_authority VARCHAR(100), -- City, County, State, etc.
    neighborhood_id BIGINT REFERENCES geo.neighborhood_boundaries(neighborhood_id),

    -- Status
    construction_status VARCHAR(50), -- normal, construction, closed
    last_maintenance DATE,
    condition_rating INTEGER, -- 1-5 scale

    -- Metadata
    data_source VARCHAR(100),
    last_updated DATE DEFAULT CURRENT_DATE,

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE geo.road_segments IS
'Road network with addressing, physical attributes, and maintenance data.
Business Rules: speed_limit > 0, condition_rating 1-5 or NULL';

-- =============================================================================
-- POINTS OF INTEREST
-- =============================================================================

CREATE TABLE geo.points_of_interest (
    poi_id BIGSERIAL PRIMARY KEY,

    -- Basic information
    name VARCHAR(200) NOT NULL,
    category geo.poi_category NOT NULL,
    subcategory VARCHAR(100), -- More specific classification

    -- Contact and web presence
    phone VARCHAR(20),
    website VARCHAR(500),
    email VARCHAR(255),

    -- Address
    street_address VARCHAR(500),
    city VARCHAR(100) DEFAULT 'Polaris City',
    state VARCHAR(2) DEFAULT 'TX',
    zip_code VARCHAR(10),

    -- Geographic data
    location_geom GEOMETRY(POINT, 4326) NOT NULL,
    neighborhood_id BIGINT REFERENCES geo.neighborhood_boundaries(neighborhood_id),

    -- Operational details
    business_hours JSONB, -- {"monday": {"open": "09:00", "close": "17:00"}, ...}
    services_offered TEXT[],
    accessibility_features TEXT[],

    -- Ratings and reviews (if applicable)
    average_rating NUMERIC(3,2), -- 1.00-5.00
    review_count INTEGER DEFAULT 0,

    -- Administrative
    permit_required BOOLEAN DEFAULT false,
    inspection_required BOOLEAN DEFAULT false,
    last_inspection_date DATE,

    -- Status
    is_active BOOLEAN DEFAULT true,
    temporary BOOLEAN DEFAULT false, -- Pop-ups, seasonal, etc.

    -- Additional data
    attributes JSONB, -- Flexible storage for category-specific data

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE geo.points_of_interest IS
'Cataloged points of interest throughout the city with location, contact, and service information.
Business Rules: average_rating 1.00-5.00 or NULL, coordinates must be within city bounds';

-- =============================================================================
-- SPATIAL INDEXES (PostGIS)
-- =============================================================================

-- Neighborhood boundaries indexes
CREATE INDEX idx_neighborhoods_geom ON geo.neighborhood_boundaries USING GIST(boundary_geom);
CREATE INDEX idx_neighborhoods_centroid ON geo.neighborhood_boundaries USING GIST(centroid_geom);
CREATE INDEX idx_neighborhoods_name ON geo.neighborhood_boundaries(neighborhood_name);
CREATE INDEX idx_neighborhoods_district ON geo.neighborhood_boundaries(city_council_district);

-- Road segments indexes
CREATE INDEX idx_roads_geom ON geo.road_segments USING GIST(segment_geom);
CREATE INDEX idx_roads_name ON geo.road_segments(road_name);
CREATE INDEX idx_roads_type ON geo.road_segments(road_type);
CREATE INDEX idx_roads_neighborhood ON geo.road_segments(neighborhood_id);
CREATE INDEX idx_roads_maintenance ON geo.road_segments(maintenance_authority);

-- Points of interest indexes
CREATE INDEX idx_pois_geom ON geo.points_of_interest USING GIST(location_geom);
CREATE INDEX idx_pois_category ON geo.points_of_interest(category);
CREATE INDEX idx_pois_name ON geo.points_of_interest(name);
CREATE INDEX idx_pois_neighborhood ON geo.points_of_interest(neighborhood_id);
CREATE INDEX idx_pois_active ON geo.points_of_interest(is_active) WHERE is_active = true;
CREATE INDEX idx_pois_zip ON geo.points_of_interest(zip_code);

-- =============================================================================
-- SPATIAL FUNCTIONS
-- =============================================================================

-- Function to find POIs within distance of a point
CREATE OR REPLACE FUNCTION geo.find_nearby_pois(
    lat DECIMAL(10,8),
    lng DECIMAL(11,8),
    distance_meters INTEGER DEFAULT 1000,
    poi_category_filter geo.poi_category DEFAULT NULL
)
RETURNS TABLE(
    poi_id BIGINT,
    name VARCHAR(200),
    category geo.poi_category,
    distance_meters INTEGER,
    street_address VARCHAR(500)
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        p.poi_id,
        p.name,
        p.category,
        ST_Distance(
            ST_Transform(ST_SetSRID(ST_Point(lng, lat), 4326), 3857),
            ST_Transform(p.location_geom, 3857)
        )::INTEGER as distance_meters,
        p.street_address
    FROM geo.points_of_interest p
    WHERE p.is_active = true
        AND ST_DWithin(
            ST_Transform(ST_SetSRID(ST_Point(lng, lat), 4326), 3857),
            ST_Transform(p.location_geom, 3857),
            distance_meters
        )
        AND (poi_category_filter IS NULL OR p.category = poi_category_filter)
    ORDER BY ST_Distance(
        ST_Transform(ST_SetSRID(ST_Point(lng, lat), 4326), 3857),
        ST_Transform(p.location_geom, 3857)
    );
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION geo.find_nearby_pois(DECIMAL, DECIMAL, INTEGER, geo.poi_category) IS
'Find points of interest within specified distance of coordinates, optionally filtered by category';

-- Function to determine which neighborhood contains a point
CREATE OR REPLACE FUNCTION geo.point_to_neighborhood(
    lat DECIMAL(10,8),
    lng DECIMAL(11,8)
)
RETURNS TABLE(
    neighborhood_id BIGINT,
    neighborhood_name VARCHAR(100),
    city_council_district INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        n.neighborhood_id,
        n.neighborhood_name,
        n.city_council_district
    FROM geo.neighborhood_boundaries n
    WHERE ST_Contains(n.boundary_geom, ST_SetSRID(ST_Point(lng, lat), 4326))
    LIMIT 1;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION geo.point_to_neighborhood(DECIMAL, DECIMAL) IS
'Determine which neighborhood contains the given coordinates';

-- Function to calculate road network statistics
CREATE OR REPLACE FUNCTION geo.road_network_stats()
RETURNS TABLE(
    road_type geo.road_type,
    segment_count BIGINT,
    total_length_km NUMERIC,
    avg_condition_rating NUMERIC,
    pct_with_sidewalks NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        r.road_type,
        COUNT(*) as segment_count,
        ROUND(SUM(r.length_km), 2) as total_length_km,
        ROUND(AVG(r.condition_rating), 1) as avg_condition_rating,
        ROUND(AVG(CASE WHEN r.has_sidewalk THEN 1.0 ELSE 0.0 END) * 100, 1) as pct_with_sidewalks
    FROM geo.road_segments r
    GROUP BY r.road_type
    ORDER BY total_length_km DESC;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION geo.road_network_stats() IS
'Generate summary statistics for road network by road type';

-- =============================================================================
-- TRIGGERS FOR CALCULATED FIELDS
-- =============================================================================

-- Automatically calculate area for neighborhoods
CREATE OR REPLACE FUNCTION geo.calculate_neighborhood_metrics()
RETURNS TRIGGER AS $$
BEGIN
    -- Calculate area in square kilometers
    NEW.area_sq_km := ST_Area(ST_Transform(NEW.boundary_geom, 3857)) / 1000000.0;

    -- Calculate centroid
    NEW.centroid_geom := ST_Centroid(NEW.boundary_geom);

    NEW.updated_at := NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_neighborhood_metrics
    BEFORE INSERT OR UPDATE OF boundary_geom
    ON geo.neighborhood_boundaries
    FOR EACH ROW
    EXECUTE FUNCTION geo.calculate_neighborhood_metrics();

-- Automatically calculate road segment length
CREATE OR REPLACE FUNCTION geo.calculate_road_metrics()
RETURNS TRIGGER AS $$
BEGIN
    -- Calculate length in kilometers
    NEW.length_km := ST_Length(ST_Transform(NEW.segment_geom, 3857)) / 1000.0;

    NEW.updated_at := NOW();

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_road_metrics
    BEFORE INSERT OR UPDATE OF segment_geom
    ON geo.road_segments
    FOR EACH ROW
    EXECUTE FUNCTION geo.calculate_road_metrics();
