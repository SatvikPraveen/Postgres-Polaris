-- File: sql/99_capstones/geo_accessibility_study.sql
-- Purpose: spatial joins + windows + routing for accessibility analysis

-- =============================================================================
-- GEOSPATIAL ACCESSIBILITY INFRASTRUCTURE
-- =============================================================================

-- Create schema for accessibility analysis
CREATE SCHEMA IF NOT EXISTS accessibility;

-- Enable PostGIS extension for spatial operations
-- CREATE EXTENSION IF NOT EXISTS postgis;

-- Points of Interest (POI) for accessibility analysis
CREATE TABLE accessibility.points_of_interest (
    poi_id BIGSERIAL PRIMARY KEY,
    poi_name TEXT NOT NULL,
    poi_type TEXT CHECK (poi_type IN ('hospital', 'school', 'transit_station', 'grocery', 'pharmacy', 'government', 'park', 'library')),
    street_address TEXT,
    city TEXT,
    state_province TEXT,
    -- coordinates GEOMETRY(POINT, 4326), -- PostGIS geometry column
    latitude NUMERIC(10, 7),
    longitude NUMERIC(11, 7),
    accessibility_features JSONB, -- wheelchair_accessible, parking, etc.
    operating_hours JSONB,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Transit routes and stops
CREATE TABLE accessibility.transit_routes (
    route_id BIGSERIAL PRIMARY KEY,
    route_name TEXT NOT NULL,
    route_type TEXT CHECK (route_type IN ('bus', 'subway', 'train', 'tram')),
    -- route_geometry GEOMETRY(LINESTRING, 4326), -- Route path
    accessibility_rating TEXT CHECK (accessibility_rating IN ('full', 'partial', 'none')),
    frequency_minutes INTEGER, -- Average time between vehicles
    operating_hours JSONB,
    is_active BOOLEAN DEFAULT TRUE
);

-- Transit stops
CREATE TABLE accessibility.transit_stops (
    stop_id BIGSERIAL PRIMARY KEY,
    route_id BIGINT REFERENCES accessibility.transit_routes(route_id),
    stop_name TEXT NOT NULL,
    street_address TEXT,
    -- stop_location GEOMETRY(POINT, 4326),
    latitude NUMERIC(10, 7),
    longitude NUMERIC(11, 7),
    accessibility_features JSONB,
    is_accessible BOOLEAN DEFAULT FALSE,
    stop_sequence INTEGER -- Order along route
);

-- Accessibility assessment results
CREATE TABLE accessibility.accessibility_scores (
    assessment_id BIGSERIAL PRIMARY KEY,
    citizen_id BIGINT REFERENCES civics.citizens(citizen_id),
    assessment_type TEXT CHECK (assessment_type IN ('overall', 'healthcare', 'education', 'transportation', 'services')),
    accessibility_score NUMERIC(4,2) CHECK (accessibility_score BETWEEN 0 AND 100),
    score_components JSONB, -- Breakdown of score factors
    assessment_date TIMESTAMPTZ DEFAULT NOW(),
    methodology_version TEXT DEFAULT '1.0'
);

-- =============================================================================
-- SPATIAL UTILITY FUNCTIONS
-- =============================================================================

-- Calculate distance between two points using Haversine formula
CREATE OR REPLACE FUNCTION accessibility.calculate_distance_km(
    lat1 NUMERIC, lon1 NUMERIC,
    lat2 NUMERIC, lon2 NUMERIC
)
RETURNS NUMERIC AS $$
DECLARE
    dlat NUMERIC;
    dlon NUMERIC;
    a NUMERIC;
    c NUMERIC;
    r NUMERIC := 6371; -- Earth's radius in km
BEGIN
    dlat := radians(lat2 - lat1);
    dlon := radians(lon2 - lon1);

    a := sin(dlat/2) * sin(dlat/2) +
         cos(radians(lat1)) * cos(radians(lat2)) *
         sin(dlon/2) * sin(dlon/2);
    c := 2 * atan2(sqrt(a), sqrt(1-a));

    RETURN r * c;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Get coordinates for citizen address (simplified - would use geocoding service in reality)
CREATE OR REPLACE FUNCTION accessibility.get_citizen_coordinates(citizen_id BIGINT)
RETURNS TABLE(latitude NUMERIC, longitude NUMERIC) AS $$
BEGIN
    -- Simplified coordinate assignment based on city/state
    -- In production, this would use a geocoding service
    RETURN QUERY
    SELECT
        CASE c.city
            WHEN 'Downtown' THEN 40.7128::NUMERIC
            WHEN 'Midtown' THEN 40.7589::NUMERIC
            WHEN 'Uptown' THEN 40.7831::NUMERIC
            WHEN 'Westside' THEN 40.7505::NUMERIC
            WHEN 'Eastside' THEN 40.7282::NUMERIC
            ELSE 40.7500::NUMERIC
        END as latitude,
        CASE c.city
            WHEN 'Downtown' THEN -74.0060::NUMERIC
            WHEN 'Midtown' THEN -73.9851::NUMERIC
            WHEN 'Uptown' THEN -73.9712::NUMERIC
            WHEN 'Westside' THEN -73.9934::NUMERIC
            WHEN 'Eastside' THEN -73.9942::NUMERIC
            ELSE -74.0000::NUMERIC
        END as longitude
    FROM civics.citizens c
    WHERE c.citizen_id = get_citizen_coordinates.citizen_id;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- HEALTHCARE ACCESSIBILITY ANALYSIS
-- =============================================================================

-- Analyze healthcare accessibility for citizens
CREATE OR REPLACE FUNCTION accessibility.analyze_healthcare_accessibility()
RETURNS TABLE(
    citizen_id BIGINT,
    nearest_hospital_distance_km NUMERIC,
    hospitals_within_5km INTEGER,
    hospitals_within_10km INTEGER,
    accessible_hospitals_within_5km INTEGER,
    healthcare_accessibility_score NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH citizen_coords AS (
        SELECT
            c.citizen_id,
            cc.latitude as citizen_lat,
            cc.longitude as citizen_lon
        FROM civics.citizens c
        CROSS JOIN LATERAL accessibility.get_citizen_coordinates(c.citizen_id) cc
        WHERE c.status = 'active'
    ),
    hospital_distances AS (
        SELECT
            cc.citizen_id,
            poi.poi_id,
            poi.poi_name,
            accessibility.calculate_distance_km(
                cc.citizen_lat, cc.citizen_lon,
                poi.latitude, poi.longitude
            ) as distance_km,
            CASE WHEN poi.accessibility_features->>'wheelchair_accessible' = 'true' THEN 1 ELSE 0 END as is_accessible
        FROM citizen_coords cc
        CROSS JOIN accessibility.points_of_interest poi
        WHERE poi.poi_type = 'hospital' AND poi.is_active = TRUE
    ),
    accessibility_metrics AS (
        SELECT
            hd.citizen_id,
            MIN(hd.distance_km) as nearest_hospital_distance_km,
            COUNT(*) FILTER (WHERE hd.distance_km <= 5) as hospitals_within_5km,
            COUNT(*) FILTER (WHERE hd.distance_km <= 10) as hospitals_within_10km,
            COUNT(*) FILTER (WHERE hd.distance_km <= 5 AND hd.is_accessible = 1) as accessible_hospitals_within_5km
        FROM hospital_distances hd
        GROUP BY hd.citizen_id
    )
    SELECT
        am.citizen_id,
        am.nearest_hospital_distance_km,
        am.hospitals_within_5km::INTEGER,
        am.hospitals_within_10km::INTEGER,
        am.accessible_hospitals_within_5km::INTEGER,
        -- Calculate healthcare accessibility score (0-100)
        ROUND(
            GREATEST(0,
                100 - (am.nearest_hospital_distance_km * 10) + -- Penalty for distance
                (am.hospitals_within_5km * 10) + -- Bonus for nearby options
                (am.accessible_hospitals_within_5km * 5) -- Bonus for accessible options
            ), 2
        ) as healthcare_accessibility_score
    FROM accessibility_metrics am
    ORDER BY healthcare_accessibility_score DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- TRANSPORTATION ACCESSIBILITY ANALYSIS
-- =============================================================================

-- Analyze public transit accessibility
CREATE OR REPLACE FUNCTION accessibility.analyze_transit_accessibility()
RETURNS TABLE(
    citizen_id BIGINT,
    nearest_transit_stop_distance_km NUMERIC,
    transit_stops_within_1km INTEGER,
    accessible_stops_within_1km INTEGER,
    unique_routes_accessible INTEGER,
    transit_accessibility_score NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    WITH citizen_coords AS (
        SELECT
            c.citizen_id,
            cc.latitude as citizen_lat,
            cc.longitude as citizen_lon
        FROM civics.citizens c
        CROSS JOIN LATERAL accessibility.get_citizen_coordinates(c.citizen_id) cc
        WHERE c.status = 'active'
    ),
    stop_distances AS (
        SELECT
            cc.citizen_id,
            ts.stop_id,
            ts.route_id,
            ts.stop_name,
            accessibility.calculate_distance_km(
                cc.citizen_lat, cc.citizen_lon,
                ts.latitude, ts.longitude
            ) as distance_km,
            ts.is_accessible,
            tr.route_type,
            tr.frequency_minutes
        FROM citizen_coords cc
        CROSS JOIN accessibility.transit_stops ts
        JOIN accessibility.transit_routes tr ON ts.route_id = tr.route_id
        WHERE tr.is_active = TRUE
    ),
    transit_metrics AS (
        SELECT
            sd.citizen_id,
            MIN(sd.distance_km) as nearest_transit_stop_distance_km,
            COUNT(*) FILTER (WHERE sd.distance_km <= 1.0) as transit_stops_within_1km,
            COUNT(*) FILTER (WHERE sd.distance_km <= 1.0 AND sd.is_accessible = TRUE) as accessible_stops_within_1km,
            COUNT(DISTINCT sd.route_id) FILTER (WHERE sd.distance_km <= 1.0 AND sd.is_accessible = TRUE) as unique_routes_accessible,
            -- Calculate frequency score (better frequency = higher score)
            AVG(CASE WHEN sd.distance_km <= 1.0 THEN (60.0 / GREATEST(sd.frequency_minutes, 5)) ELSE NULL END) as avg_frequency_score
        FROM stop_distances sd
        GROUP BY sd.citizen_id
    )
    SELECT
        tm.citizen_id,
        tm.nearest_transit_stop_distance_km,
        tm.transit_stops_within_1km::INTEGER,
        tm.accessible_stops_within_1km::INTEGER,
        tm.unique_routes_accessible::INTEGER,
        -- Calculate transit accessibility score (0-100)
        ROUND(
            LEAST(100,
                GREATEST(0,
                    -- Base score reduced by distance to nearest stop
                    80 - (tm.nearest_transit_stop_distance_km * 20) +
                    -- Bonus for multiple nearby stops
                    (tm.transit_stops_within_1km * 3) +
                    -- Bonus for accessible stops
                    (tm.accessible_stops_within_1km * 5) +
                    -- Bonus for route diversity
                    (tm.unique_routes_accessible * 3) +
                    -- Bonus for frequency
                    COALESCE(tm.avg_frequency_score * 2, 0)
                )
            ), 2
        ) as transit_accessibility_score
    FROM transit_metrics tm
    ORDER BY transit_accessibility_score DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- COMPREHENSIVE ACCESSIBILITY SCORING
-- =============================================================================

-- Calculate overall accessibility score for all citizens
CREATE OR REPLACE FUNCTION accessibility.calculate_comprehensive_accessibility()
RETURNS VOID AS $$
DECLARE
    citizen_record RECORD;
    healthcare_score NUMERIC;
    transit_score NUMERIC;
    services_score NUMERIC;
    overall_score NUMERIC;
BEGIN
    -- Clear existing assessments for today
    DELETE FROM accessibility.accessibility_scores WHERE assessment_date::DATE = CURRENT_DATE;

    -- Calculate accessibility for each citizen
    FOR citizen_record IN
        SELECT citizen_id FROM civics.citizens WHERE status = 'active'
    LOOP
        -- Get healthcare accessibility score
        SELECT ha.healthcare_accessibility_score INTO healthcare_score
        FROM accessibility.analyze_healthcare_accessibility() ha
        WHERE ha.citizen_id = citizen_record.citizen_id;

        -- Get transit accessibility score
        SELECT ta.transit_accessibility_score INTO transit_score
        FROM accessibility.analyze_transit_accessibility() ta
        WHERE ta.citizen_id = citizen_record.citizen_id;

        -- Calculate services accessibility (schools, grocery, government)
        WITH service_access AS (
            SELECT
                AVG(
                    CASE
                        WHEN accessibility.calculate_distance_km(
                            cc.latitude, cc.longitude, poi.latitude, poi.longitude
                        ) <= 2.0 THEN 80
                        WHEN accessibility.calculate_distance_km(
                            cc.latitude, cc.longitude, poi.latitude, poi.longitude
                        ) <= 5.0 THEN 60
                        ELSE 20
                    END
                ) as avg_service_score
            FROM accessibility.get_citizen_coordinates(citizen_record.citizen_id) cc
            CROSS JOIN accessibility.points_of_interest poi
            WHERE poi.poi_type IN ('school', 'grocery', 'government', 'library', 'pharmacy')
            AND poi.is_active = TRUE
        )
        SELECT avg_service_score INTO services_score FROM service_access;

        -- Calculate weighted overall score
        overall_score := ROUND(
            (COALESCE(healthcare_score, 50) * 0.4) + -- 40% weight
            (COALESCE(transit_score, 50) * 0.35) +   -- 35% weight
            (COALESCE(services_score, 50) * 0.25),   -- 25% weight
            2
        );

        -- Insert assessment results
        INSERT INTO accessibility.accessibility_scores (
            citizen_id, assessment_type, accessibility_score, score_components
        ) VALUES (
            citizen_record.citizen_id,
            'overall',
            overall_score,
            json_build_object(
                'healthcare_score', COALESCE(healthcare_score, 50),
                'transit_score', COALESCE(transit_score, 50),
                'services_score', COALESCE(services_score, 50),
                'weights', json_build_object(
                    'healthcare', 0.4,
                    'transit', 0.35,
                    'services', 0.25
                )
            )
        );

        -- Insert individual component scores
        INSERT INTO accessibility.accessibility_scores (
            citizen_id, assessment_type, accessibility_score, score_components
        ) VALUES
        (citizen_record.citizen_id, 'healthcare', COALESCE(healthcare_score, 50),
         json_build_object('component', 'healthcare')),
        (citizen_record.citizen_id, 'transportation', COALESCE(transit_score, 50),
         json_build_object('component', 'transportation')),
        (citizen_record.citizen_id, 'services', COALESCE(services_score, 50),
         json_build_object('component', 'services'));
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ACCESSIBILITY GAP ANALYSIS
-- =============================================================================

-- Identify accessibility gaps and underserved areas
CREATE OR REPLACE FUNCTION accessibility.identify_accessibility_gaps()
RETURNS TABLE(
    gap_category TEXT,
    affected_citizens INTEGER,
    avg_accessibility_score NUMERIC,
    geographic_area TEXT,
    priority_level TEXT,
    recommended_actions TEXT[]
) AS $$
BEGIN
    -- Low healthcare accessibility areas
    RETURN QUERY
    SELECT
        'Healthcare Access'::TEXT as gap_category,
        COUNT(*)::INTEGER as affected_citizens,
        AVG(accessibility_score) as avg_accessibility_score,
        c.city as geographic_area,
        CASE
            WHEN AVG(accessibility_score) < 30 THEN 'CRITICAL'
            WHEN AVG(accessibility_score) < 50 THEN 'HIGH'
            ELSE 'MEDIUM'
        END as priority_level,
        ARRAY[
            'Consider mobile health clinics',
            'Evaluate new healthcare facility locations',
            'Improve healthcare transportation services'
        ] as recommended_actions
    FROM accessibility.accessibility_scores ascore
    JOIN civics.citizens c ON ascore.citizen_id = c.citizen_id
    WHERE ascore.assessment_type = 'healthcare'
    AND ascore.assessment_date::DATE = CURRENT_DATE
    AND ascore.accessibility_score < 60
    GROUP BY c.city
    HAVING COUNT(*) >= 5 -- At least 5 affected citizens

    UNION ALL

    -- Low transit accessibility areas
    SELECT
        'Transit Access'::TEXT,
        COUNT(*)::INTEGER,
        AVG(accessibility_score),
        c.city,
        CASE
            WHEN AVG(accessibility_score) < 25 THEN 'CRITICAL'
            WHEN AVG(accessibility_score) < 40 THEN 'HIGH'
            ELSE 'MEDIUM'
        END,
        ARRAY[
            'Expand bus route coverage',
            'Add accessible transit stops',
            'Increase service frequency',
            'Consider shuttle services'
        ]
    FROM accessibility.accessibility_scores ascore
    JOIN civics.citizens c ON ascore.citizen_id = c.citizen_id
    WHERE ascore.assessment_type = 'transportation'
    AND ascore.assessment_date::DATE = CURRENT_DATE
    AND ascore.accessibility_score < 50
    GROUP BY c.city
    HAVING COUNT(*) >= 5

    UNION ALL

    -- Overall accessibility gaps
    SELECT
        'Overall Access'::TEXT,
        COUNT(*)::INTEGER,
        AVG(accessibility_score),
        c.city,
        CASE
            WHEN AVG(accessibility_score) < 40 THEN 'CRITICAL'
            WHEN AVG(accessibility_score) < 55 THEN 'HIGH'
            ELSE 'MEDIUM'
        END,
        ARRAY[
            'Comprehensive accessibility audit needed',
            'Multi-modal transportation improvements',
            'Strategic service location planning'
        ]
    FROM accessibility.accessibility_scores ascore
    JOIN civics.citizens c ON ascore.citizen_id = c.citizen_id
    WHERE ascore.assessment_type = 'overall'
    AND ascore.assessment_date::DATE = CURRENT_DATE
    AND ascore.accessibility_score < 65
    GROUP BY c.city
    HAVING COUNT(*) >= 10;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ACCESSIBILITY TREND ANALYSIS
-- =============================================================================

-- Analyze accessibility trends over time
CREATE OR REPLACE FUNCTION accessibility.analyze_accessibility_trends(
    months_back INTEGER DEFAULT 12
)
RETURNS TABLE(
    trend_period TEXT,
    assessment_type TEXT,
    avg_score NUMERIC,
    score_change NUMERIC,
    citizens_assessed INTEGER,
    trend_direction TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH monthly_scores AS (
        SELECT
            DATE_TRUNC('month', assessment_date) as month,
            ascore.assessment_type,
            AVG(ascore.accessibility_score) as avg_score,
            COUNT(*) as citizens_assessed
        FROM accessibility.accessibility_scores ascore
        WHERE assessment_date >= CURRENT_DATE - (months_back || ' months')::INTERVAL
        GROUP BY DATE_TRUNC('month', assessment_date), ascore.assessment_type
    ),
    trend_analysis AS (
        SELECT
            TO_CHAR(month, 'YYYY-MM') as trend_period,
            assessment_type,
            avg_score,
            citizens_assessed,
            LAG(avg_score) OVER (PARTITION BY assessment_type ORDER BY month) as prev_score,
            avg_score - LAG(avg_score) OVER (PARTITION BY assessment_type ORDER BY month) as score_change
        FROM monthly_scores
    )
    SELECT
        ta.trend_period,
        ta.assessment_type,
        ROUND(ta.avg_score, 2) as avg_score,
        ROUND(COALESCE(ta.score_change, 0), 2) as score_change,
        ta.citizens_assessed::INTEGER,
        CASE
            WHEN ta.score_change > 2 THEN 'IMPROVING'
            WHEN ta.score_change < -2 THEN 'DECLINING'
            WHEN ta.score_change IS NULL THEN 'BASELINE'
            ELSE 'STABLE'
        END as trend_direction
    FROM trend_analysis ta
    WHERE ta.month >= CURRENT_DATE - (months_back || ' months')::INTERVAL
    ORDER BY ta.assessment_type, ta.trend_period;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- ACCESSIBILITY REPORTING DASHBOARD
-- =============================================================================

-- Generate comprehensive accessibility report
CREATE OR REPLACE FUNCTION accessibility.generate_accessibility_dashboard()
RETURNS TABLE(
    dashboard_section TEXT,
    metric_name TEXT,
    metric_value TEXT,
    benchmark_comparison TEXT,
    status_indicator TEXT
) AS $$
BEGIN
    -- Overall accessibility summary
    RETURN QUERY
    SELECT
        'City Overview'::TEXT as dashboard_section,
        'Average Overall Accessibility'::TEXT as metric_name,
        ROUND(AVG(accessibility_score), 1)::TEXT || '%' as metric_value,
        CASE
            WHEN AVG(accessibility_score) >= 75 THEN 'Above national average (70%)'
            WHEN AVG(accessibility_score) >= 60 THEN 'Meeting minimum standards (60%)'
            ELSE 'Below minimum standards'
        END as benchmark_comparison,
        CASE
            WHEN AVG(accessibility_score) >= 75 THEN 'EXCELLENT'
            WHEN AVG(accessibility_score) >= 60 THEN 'GOOD'
            WHEN AVG(accessibility_score) >= 45 THEN 'NEEDS_IMPROVEMENT'
            ELSE 'CRITICAL'
        END as status_indicator
    FROM accessibility.accessibility_scores
    WHERE assessment_type = 'overall'
    AND assessment_date::DATE = CURRENT_DATE;

    -- Component breakdowns
    RETURN QUERY
    SELECT
        'Component Scores'::TEXT,
        INITCAP(assessment_type) || ' Accessibility',
        ROUND(AVG(accessibility_score), 1)::TEXT || '%',
        CASE assessment_type
            WHEN 'healthcare' THEN 'Target: 70%+'
            WHEN 'transportation' THEN 'Target: 65%+'
            WHEN 'services' THEN 'Target: 60%+'
            ELSE 'Target: 65%+'
        END,
        CASE
            WHEN assessment_type = 'healthcare' AND AVG(accessibility_score) >= 70 THEN 'GOOD'
            WHEN assessment_type = 'transportation' AND AVG(accessibility_score) >= 65 THEN 'GOOD'
            WHEN assessment_type = 'services' AND AVG(accessibility_score) >= 60 THEN 'GOOD'
            WHEN AVG(accessibility_score) >= 50 THEN 'NEEDS_IMPROVEMENT'
            ELSE 'CRITICAL'
        END
    FROM accessibility.accessibility_scores
    WHERE assessment_type IN ('healthcare', 'transportation', 'services')
    AND assessment_date::DATE = CURRENT_DATE
    GROUP BY assessment_type;

    -- Geographic disparities
    RETURN QUERY
    SELECT
        'Geographic Analysis'::TEXT,
        c.city || ' Accessibility',
        ROUND(AVG(ascore.accessibility_score), 1)::TEXT || '%',
        'Compared to city average',
        CASE
            WHEN AVG(ascore.accessibility_score) >= 70 THEN 'ABOVE_AVERAGE'
            WHEN AVG(ascore.accessibility_score) >= 50 THEN 'AVERAGE'
            ELSE 'BELOW_AVERAGE'
        END
    FROM accessibility.accessibility_scores ascore
    JOIN civics.citizens c ON ascore.citizen_id = c.citizen_id
    WHERE ascore.assessment_type = 'overall'
    AND ascore.assessment_date::DATE = CURRENT_DATE
    GROUP BY c.city
    ORDER BY AVG(ascore.accessibility_score) DESC;

    -- Accessibility gaps summary
    RETURN QUERY
    SELECT
        'Priority Areas'::TEXT,
        gap_category || ' - ' || geographic_area,
        affected_citizens::TEXT || ' citizens affected',
        'Priority: ' || priority_level,
        CASE priority_level
            WHEN 'CRITICAL' THEN 'URGENT_ACTION'
            WHEN 'HIGH' THEN 'HIGH_PRIORITY'
            ELSE 'MONITOR'
        END
    FROM accessibility.identify_accessibility_gaps()
    ORDER BY
        CASE priority_level
            WHEN 'CRITICAL' THEN 1
            WHEN 'HIGH' THEN 2
            ELSE 3
        END,
        affected_citizens DESC;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- SETUP AND INITIALIZATION
-- =============================================================================

-- Initialize sample POIs and transit data
CREATE OR REPLACE FUNCTION accessibility.setup_sample_accessibility_data()
RETURNS TEXT AS $$
DECLARE
    pois_created INTEGER := 0;
    routes_created INTEGER := 0;
BEGIN
    -- Sample hospitals
    INSERT INTO accessibility.points_of_interest (
        poi_name, poi_type, street_address, city, state_province,
        latitude, longitude, accessibility_features
    ) VALUES
    ('Downtown General Hospital', 'hospital', '100 Main St', 'Downtown', 'State',
     40.7128, -74.0060, '{"wheelchair_accessible": true, "parking": true}'),
    ('Midtown Medical Center', 'hospital', '200 Center Ave', 'Midtown', 'State',
     40.7589, -73.9851, '{"wheelchair_accessible": true, "parking": false}'),
    ('Westside Community Hospital', 'hospital', '300 West St', 'Westside', 'State',
     40.7505, -73.9934, '{"wheelchair_accessible": false, "parking": true}')
    ON CONFLICT DO NOTHING;

    pois_created := pois_created + 3;

    -- Sample schools
    INSERT INTO accessibility.points_of_interest (
        poi_name, poi_type, street_address, city, state_province,
        latitude, longitude, accessibility_features
    ) VALUES
    ('Downtown Elementary', 'school', '150 School St', 'Downtown', 'State',
     40.7150, -74.0080, '{"wheelchair_accessible": true, "parking": true}'),
    ('Midtown High School', 'school', '250 Education Blvd', 'Midtown', 'State',
     40.7600, -73.9870, '{"wheelchair_accessible": true, "parking": true}')
    ON CONFLICT DO NOTHING;

    pois_created := pois_created + 2;

    -- Sample transit routes
    INSERT INTO accessibility.transit_routes (
        route_name, route_type, accessibility_rating, frequency_minutes
    ) VALUES
    ('Metro Line 1', 'subway', 'full', 8),
    ('Bus Route 42', 'bus', 'full', 15),
    ('Express Bus A', 'bus', 'partial', 20)
    ON CONFLICT DO NOTHING;

    routes_created := 3;

    -- Sample transit stops
    INSERT INTO accessibility.transit_stops (
        route_id, stop_name, street_address, latitude, longitude,
        is_accessible, stop_sequence
    )
    SELECT
        tr.route_id,
        'Downtown Station', '110 Transit St', 40.7140, -74.0070,
        true, 1
    FROM accessibility.transit_routes tr WHERE route_name = 'Metro Line 1'

    UNION ALL

    SELECT
        tr.route_id,
        'Midtown Hub', '220 Transit Ave', 40.7580, -73.9860,
        true, 2
    FROM accessibility.transit_routes tr WHERE route_name = 'Metro Line 1'
    ON CONFLICT DO NOTHING;

    RETURN 'Created ' || pois_created || ' POIs and ' || routes_created || ' transit routes';
END;
$$ LANGUAGE plpgsql;
