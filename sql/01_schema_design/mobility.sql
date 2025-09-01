-- File: sql/01_schema_design/mobility.sql
-- Purpose: Transportation system with trips, sensors, stations, and inventory

-- =============================================================================
-- ENUMS AND TYPES
-- =============================================================================

CREATE TYPE mobility.station_type AS ENUM ('bus', 'rail', 'bike_share', 'scooter', 'park_ride', 'ev_charging');
CREATE TYPE mobility.station_status AS ENUM ('active', 'maintenance', 'offline', 'full', 'empty');
CREATE TYPE mobility.trip_mode AS ENUM ('walking', 'cycling', 'bus', 'rail', 'car', 'rideshare', 'scooter', 'other');
CREATE TYPE mobility.sensor_type AS ENUM ('traffic_counter', 'air_quality', 'noise', 'occupancy', 'speed', 'weather');

-- =============================================================================
-- STATIONS (Transit, Bike Share, EV Charging, etc.)
-- =============================================================================

CREATE TABLE mobility.stations (
    station_id BIGSERIAL PRIMARY KEY,

    -- Identification
    station_code VARCHAR(20) UNIQUE NOT NULL, -- User-friendly ID like "BUS_001"
    station_name VARCHAR(200) NOT NULL,
    station_type mobility.station_type NOT NULL,

    -- Location
    latitude DECIMAL(10,8) NOT NULL,
    longitude DECIMAL(11,8) NOT NULL,
    address VARCHAR(500),
    neighborhood VARCHAR(100),

    -- Capacity and Features
    total_capacity INTEGER NOT NULL DEFAULT 0,
    accessible BOOLEAN DEFAULT false,
    covered BOOLEAN DEFAULT false,
    lighting BOOLEAN DEFAULT false,

    -- Status
    status mobility.station_status DEFAULT 'active' NOT NULL,

    -- Operational
    operator VARCHAR(100), -- Transit agency or company
    installation_date DATE,
    last_maintenance DATE,
    next_maintenance_due DATE,

    -- Metadata
    amenities JSONB, -- {"wifi": true, "restroom": false, "vending": true}

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE mobility.stations IS
'All types of mobility stations including transit stops, bike shares, EV charging.
Business Rules: station_code must be unique, coordinates must be within city bounds';

-- =============================================================================
-- STATION INVENTORY (Real-time availability)
-- =============================================================================

CREATE TABLE mobility.station_inventory (
    inventory_id BIGSERIAL PRIMARY KEY,
    station_id BIGINT NOT NULL REFERENCES mobility.stations(station_id),

    -- Availability counts
    available_count INTEGER NOT NULL DEFAULT 0,
    in_use_count INTEGER NOT NULL DEFAULT 0,
    maintenance_count INTEGER NOT NULL DEFAULT 0,

    -- Timestamp
    recorded_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,

    -- Type-specific details
    inventory_details JSONB -- bike types, charging levels, etc.
);

COMMENT ON TABLE mobility.station_inventory IS
'Real-time inventory snapshots for stations (bikes available, charging ports free, etc.)
Business Rules: available_count + in_use_count + maintenance_count <= station.total_capacity';

-- =============================================================================
-- TRIP RECORDS (Multi-modal journey tracking)
-- =============================================================================

CREATE TABLE mobility.trip_segments (
    trip_segment_id BIGSERIAL PRIMARY KEY,

    -- Trip identification
    trip_id VARCHAR(100) NOT NULL, -- Groups related segments
    segment_order INTEGER NOT NULL DEFAULT 1,
    user_id BIGINT REFERENCES civics.citizens(citizen_id), -- NULL for anonymous

    -- Mode and timing
    trip_mode mobility.trip_mode NOT NULL,
    start_time TIMESTAMPTZ NOT NULL,
    end_time TIMESTAMPTZ,
    duration_minutes INTEGER,

    -- Location data
    start_latitude DECIMAL(10,8),
    start_longitude DECIMAL(11,8),
    end_latitude DECIMAL(10,8),
    end_longitude DECIMAL(11,8),
    start_station_id BIGINT REFERENCES mobility.stations(station_id),
    end_station_id BIGINT REFERENCES mobility.stations(station_id),

    -- Trip metrics
    distance_km DECIMAL(8,3),
    average_speed_kmh DECIMAL(6,2),

    -- Cost information
    fare_paid NUMERIC(6,2),
    payment_method VARCHAR(50),

    -- Trip quality
    comfort_rating INTEGER, -- 1-5 scale
    delay_minutes INTEGER DEFAULT 0,

    -- Additional data
    route_taken JSONB, -- GPS breadcrumb trail if available
    trip_purpose VARCHAR(50), -- commute, leisure, business, etc.

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE mobility.trip_segments IS
'Individual segments of multi-modal trips with timing, location, and quality metrics.
Business Rules: end_time > start_time, comfort_rating 1-5 or NULL';

-- =============================================================================
-- SENSOR READINGS (Environmental and traffic monitoring)
-- =============================================================================

CREATE TABLE mobility.sensor_readings (
    reading_id BIGSERIAL PRIMARY KEY,

    -- Sensor identification
    sensor_code VARCHAR(50) NOT NULL,
    sensor_type mobility.sensor_type NOT NULL,

    -- Location
    latitude DECIMAL(10,8) NOT NULL,
    longitude DECIMAL(11,8) NOT NULL,
    location_description VARCHAR(200),

    -- Reading data
    reading_value NUMERIC(12,4) NOT NULL,
    unit_of_measure VARCHAR(20) NOT NULL, -- mph, ppm, dB, count, etc.
    reading_time TIMESTAMPTZ DEFAULT NOW() NOT NULL,

    -- Quality indicators
    data_quality_score DECIMAL(3,2), -- 0.00-1.00
    calibration_date DATE,

    -- Additional context
    weather_conditions VARCHAR(100),
    special_events VARCHAR(200), -- Construction, event, etc.

    -- Raw sensor data
    raw_data JSONB
);

COMMENT ON TABLE mobility.sensor_readings IS
'Time-series data from various sensors monitoring transportation infrastructure.
Business Rules: reading_value units must match sensor_type, quality_score 0-1';

-- =============================================================================
-- PERFORMANCE INDEXES
-- =============================================================================

-- Stations indexes
CREATE INDEX idx_stations_code ON mobility.stations(station_code);
CREATE INDEX idx_stations_type ON mobility.stations(station_type);
CREATE INDEX idx_stations_location ON mobility.stations(latitude, longitude);
CREATE INDEX idx_stations_status ON mobility.stations(status) WHERE status != 'active';
CREATE INDEX idx_stations_maintenance ON mobility.stations(next_maintenance_due)
    WHERE next_maintenance_due IS NOT NULL;

-- Inventory indexes
CREATE INDEX idx_inventory_station ON mobility.station_inventory(station_id);
CREATE INDEX idx_inventory_time ON mobility.station_inventory(recorded_at DESC);
CREATE INDEX idx_inventory_station_time ON mobility.station_inventory(station_id, recorded_at DESC);

-- Trip segments indexes
CREATE INDEX idx_trips_trip_id ON mobility.trip_segments(trip_id, segment_order);
CREATE INDEX idx_trips_user ON mobility.trip_segments(user_id);
CREATE INDEX idx_trips_time ON mobility.trip_segments(start_time DESC);
CREATE INDEX idx_trips_mode ON mobility.trip_segments(trip_mode);
CREATE INDEX idx_trips_stations ON mobility.trip_segments(start_station_id, end_station_id);
CREATE INDEX idx_trips_location_start ON mobility.trip_segments(start_latitude, start_longitude);

-- Sensor readings indexes (time-series optimized)
CREATE INDEX idx_sensors_code_time ON mobility.sensor_readings(sensor_code, reading_time DESC);
CREATE INDEX idx_sensors_type_time ON mobility.sensor_readings(sensor_type, reading_time DESC);
CREATE INDEX idx_sensors_location ON mobility.sensor_readings(latitude, longitude);
CREATE INDEX idx_sensors_time_only ON mobility.sensor_readings(reading_time DESC);

-- =============================================================================
-- PARTITIONING SETUP (for time-series data)
-- =============================================================================

-- Partition sensor readings by month for better performance
-- This would be implemented after the base table is created
/*
-- Convert sensor_readings to partitioned table
ALTER TABLE mobility.sensor_readings RENAME TO sensor_readings_old;

CREATE TABLE mobility.sensor_readings (
    LIKE mobility.sensor_readings_old INCLUDING ALL
) PARTITION BY RANGE (reading_time);

-- Create partitions for recent months
CREATE TABLE mobility.sensor_readings_2024_12
    PARTITION OF mobility.sensor_readings
    FOR VALUES FROM ('2024-12-01') TO ('2025-01-01');

CREATE TABLE mobility.sensor_readings_2025_01
    PARTITION OF mobility.sensor_readings
    FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');

-- Insert existing data
INSERT INTO mobility.sensor_readings SELECT * FROM mobility.sensor_readings_old;
DROP TABLE mobility.sensor_readings_old;
*/

-- =============================================================================
-- USEFUL ANALYTICS FUNCTIONS
-- =============================================================================

-- Function to calculate station utilization
CREATE OR REPLACE FUNCTION mobility.station_utilization(
    station_id_param BIGINT,
    hours_back INTEGER DEFAULT 24
)
RETURNS TABLE(
    station_name TEXT,
    avg_available INTEGER,
    avg_in_use INTEGER,
    utilization_pct NUMERIC
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s.station_name::TEXT,
        ROUND(AVG(inv.available_count))::INTEGER,
        ROUND(AVG(inv.in_use_count))::INTEGER,
        ROUND(AVG(inv.in_use_count::NUMERIC / NULLIF(s.total_capacity, 0)) * 100, 1)
    FROM mobility.stations s
    JOIN mobility.station_inventory inv ON s.station_id = inv.station_id
    WHERE s.station_id = station_id_param
        AND inv.recorded_at >= NOW() - (hours_back || ' hours')::INTERVAL
    GROUP BY s.station_id, s.station_name, s.total_capacity;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION mobility.station_utilization(BIGINT, INTEGER) IS
'Calculate average utilization percentage for a station over specified hours';

-- Function to get popular routes
CREATE OR REPLACE FUNCTION mobility.popular_routes(days_back INTEGER DEFAULT 30)
RETURNS TABLE(
    start_station TEXT,
    end_station TEXT,
    trip_count BIGINT,
    avg_duration_min NUMERIC,
    most_common_mode TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        s1.station_name::TEXT as start_station,
        s2.station_name::TEXT as end_station,
        COUNT(*) as trip_count,
        ROUND(AVG(ts.duration_minutes), 1) as avg_duration_min,
        MODE() WITHIN GROUP (ORDER BY ts.trip_mode)::TEXT as most_common_mode
    FROM mobility.trip_segments ts
    JOIN mobility.stations s1 ON ts.start_station_id = s1.station_id
    JOIN mobility.stations s2 ON ts.end_station_id = s2.station_id
    WHERE ts.start_time >= CURRENT_DATE - (days_back || ' days')::INTERVAL
        AND ts.start_station_id != ts.end_station_id
    GROUP BY s1.station_id, s1.station_name, s2.station_id, s2.station_name
    HAVING COUNT(*) >= 5
    ORDER BY trip_count DESC;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION mobility.popular_routes(INTEGER) IS
'Identify most popular station-to-station routes with usage metrics';
