-- File: sql/02_constraints_indexes/indexing_basics.sql
-- Purpose: B-tree, Hash, GIN, GiST, BRIN indexes with performance examples

-- =============================================================================
-- B-TREE INDEXES (Default - for equality, range, sorting)
-- =============================================================================

-- Single column B-tree indexes
CREATE INDEX idx_citizens_last_name_btree ON civics.citizens USING btree(last_name);
CREATE INDEX idx_orders_order_date_btree ON commerce.orders USING btree(order_date);
CREATE INDEX idx_trips_start_time_btree ON mobility.trip_segments USING btree(start_time);

-- Multi-column B-tree indexes (order matters!)
CREATE INDEX idx_tax_citizen_year_btree ON civics.tax_payments USING btree(citizen_id, tax_year);
CREATE INDEX idx_permits_type_status_btree ON civics.permit_applications USING btree(permit_type, status);
CREATE INDEX idx_orders_merchant_date_btree ON commerce.orders USING btree(merchant_id, order_date DESC);

-- B-tree with DESC for common ORDER BY DESC patterns
CREATE INDEX idx_complaints_submitted_desc ON documents.complaint_records USING btree(submitted_at DESC);
CREATE INDEX idx_sensors_time_desc ON mobility.sensor_readings USING btree(reading_time DESC);

-- =============================================================================
-- HASH INDEXES (for equality only, faster than B-tree for =)
-- =============================================================================

-- Hash indexes for exact lookups (PostgreSQL 10+ supports WAL logging)
CREATE INDEX idx_citizens_email_hash ON civics.citizens USING hash(email);
CREATE INDEX idx_merchants_tax_id_hash ON commerce.merchants USING hash(tax_id);
CREATE INDEX idx_stations_code_hash ON mobility.stations USING hash(station_code);
CREATE INDEX idx_permits_number_hash ON civics.permit_applications USING hash(permit_number);

-- Hash indexes for enum values (frequent equality checks)
CREATE INDEX idx_orders_status_hash ON commerce.orders USING hash(status);
CREATE INDEX idx_complaints_priority_hash ON documents.complaint_records USING hash(priority_level);

-- =============================================================================
-- GIN INDEXES (Generalized Inverted Index - for JSONB, arrays, full-text)
-- =============================================================================

-- JSONB indexes for document content
CREATE INDEX idx_complaints_metadata_gin ON documents.complaint_records USING gin(metadata);
CREATE INDEX idx_policies_content_gin ON documents.policy_documents USING gin(document_content);
CREATE INDEX idx_orders_customer_details_gin ON commerce.orders USING gin((COALESCE(delivery_address, '')||' '||COALESCE(order_notes, '')));

-- Array indexes
CREATE INDEX idx_pois_services_gin ON geo.points_of_interest USING gin(services_offered);
CREATE INDEX idx_pois_accessibility_gin ON geo.points_of_interest USING gin(accessibility_features);
CREATE INDEX idx_policies_tags_gin ON documents.policy_documents USING gin(tags);

-- Full-text search indexes (already created in documents.sql, shown for reference)
-- CREATE INDEX idx_complaints_search_gin ON documents.complaint_records USING gin(search_vector);
-- CREATE INDEX idx_policies_search_gin ON documents.policy_documents USING gin(search_vector);

-- JSONB path-specific indexes for common queries
CREATE INDEX idx_complaints_metadata_category_gin ON documents.complaint_records USING gin((metadata->'category'));
CREATE INDEX idx_pois_hours_gin ON geo.points_of_interest USING gin(business_hours);

-- =============================================================================
-- GiST INDEXES (Generalized Search Tree - for geometric data, ranges)
-- =============================================================================

-- Geometric indexes (PostGIS spatial indexes already created in geo.sql)
-- CREATE INDEX idx_neighborhoods_geom_gist ON geo.neighborhood_boundaries USING gist(boundary_geom);
-- CREATE INDEX idx_roads_geom_gist ON geo.road_segments USING gist(segment_geom);
-- CREATE INDEX idx_pois_location_gist ON geo.points_of_interest USING gist(location_geom);

-- Range indexes using GiST
CREATE INDEX idx_permits_date_range_gist ON civics.permit_applications
    USING gist(tstzrange(application_date, expiration_date));

CREATE INDEX idx_licenses_validity_range_gist ON commerce.business_licenses
    USING gist(daterange(issue_date, expiration_date));

-- Text similarity using GiST (for fuzzy matching)
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_citizens_name_similarity_gist ON civics.citizens
    USING gist((first_name || ' ' || last_name) gist_trgm_ops);
CREATE INDEX idx_merchants_name_similarity_gist ON commerce.merchants
    USING gist(business_name gist_trgm_ops);

-- =============================================================================
-- BRIN INDEXES (Block Range Index - for large sequential data)
-- =============================================================================

-- BRIN indexes for large time-series tables (very space efficient)
CREATE INDEX idx_sensors_time_brin ON mobility.sensor_readings USING brin(reading_time);
CREATE INDEX idx_inventory_time_brin ON mobility.station_inventory USING brin(recorded_at);
CREATE INDEX idx_complaints_submitted_brin ON documents.complaint_records USING brin(submitted_at);

-- BRIN for naturally ordered data
CREATE INDEX idx_citizens_id_brin ON civics.citizens USING brin(citizen_id);
CREATE INDEX idx_orders_id_brin ON commerce.orders USING brin(order_id);

-- BRIN with custom pages per range (default is 128 pages)
CREATE INDEX idx_trips_time_brin_256 ON mobility.trip_segments
    USING brin(start_time) WITH (pages_per_range = 256);

-- =============================================================================
-- SPECIALIZED INDEX PATTERNS
-- =============================================================================

-- Covering indexes (INCLUDE clause) - PostgreSQL 11+
CREATE INDEX idx_citizens_email_covering ON civics.citizens(email)
    INCLUDE (first_name, last_name, phone);

CREATE INDEX idx_orders_merchant_covering ON commerce.orders(merchant_id, order_date)
    INCLUDE (status, total_amount, customer_citizen_id);

-- Partial indexes (conditional indexes)
CREATE INDEX idx_permits_pending ON civics.permit_applications(application_date)
    WHERE status = 'pending';

CREATE INDEX idx_orders_incomplete ON commerce.orders(merchant_id, order_date)
    WHERE status IN ('pending', 'processing');

CREATE INDEX idx_complaints_unresolved ON documents.complaint_records(priority_level, submitted_at)
    WHERE status NOT IN ('resolved', 'archived');

CREATE INDEX idx_pois_active ON geo.points_of_interest(category, neighborhood_id)
    WHERE is_active = true;

-- Expression indexes (functional indexes)
CREATE INDEX idx_citizens_name_lower ON civics.citizens(lower(last_name), lower(first_name));
CREATE INDEX idx_merchants_name_lower ON commerce.merchants(lower(business_name));
CREATE INDEX idx_complaints_age_days ON documents.complaint_records(
    (EXTRACT(EPOCH FROM (CURRENT_TIMESTAMP - submitted_at))/86400)::INTEGER
) WHERE status != 'resolved';

-- =============================================================================
-- INDEX MONITORING QUERIES
-- =============================================================================

-- View index usage statistics
CREATE VIEW analytics.index_usage_stats AS
SELECT
    schemaname,
    tablename,
    indexname,
    idx_scan as scans,
    idx_tup_read as tuples_read,
    idx_tup_fetch as tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
ORDER BY idx_scan DESC;

-- Find unused indexes
CREATE VIEW analytics.unused_indexes AS
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    AND idx_scan = 0
    AND indexname NOT LIKE '%_pkey'
ORDER BY pg_relation_size(indexrelid) DESC;

-- Index bloat estimation
CREATE VIEW analytics.index_bloat_estimate AS
SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as current_size,
    ROUND(100 * (pg_relation_size(indexrelid)::NUMERIC /
          NULLIF(pg_stat_get_tuples_inserted(indexrelid) +
                 pg_stat_get_tuples_updated(indexrelid), 0)), 2) as bloat_ratio
FROM pg_stat_user_indexes
WHERE schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
ORDER BY pg_relation_size(indexrelid) DESC;

-- =============================================================================
-- INDEX MAINTENANCE FUNCTIONS
-- =============================================================================

-- Function to reindex all tables in a schema
CREATE OR REPLACE FUNCTION analytics.reindex_schema(schema_name TEXT)
RETURNS TEXT AS $$
DECLARE
    table_rec RECORD;
    result_text TEXT := '';
BEGIN
    FOR table_rec IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = schema_name
    LOOP
        EXECUTE 'REINDEX TABLE ' || quote_ident(schema_name) || '.' || quote_ident(table_rec.tablename);
        result_text := result_text || 'Reindexed ' || schema_name || '.' || table_rec.tablename || E'\n';
    END LOOP;

    RETURN result_text;
END;
$$ LANGUAGE plpgsql;

-- Function to analyze index effectiveness
CREATE OR REPLACE FUNCTION analytics.analyze_index_effectiveness()
RETURNS TABLE(
    schema_table TEXT,
    index_name TEXT,
    scans_per_mb NUMERIC,
    effectiveness_score TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        (pui.schemaname || '.' || pui.tablename)::TEXT as schema_table,
        pui.indexname::TEXT as index_name,
        CASE
            WHEN pg_relation_size(pui.indexrelid) > 0
            THEN ROUND(pui.idx_scan::NUMERIC / (pg_relation_size(pui.indexrelid) / 1024.0 / 1024.0), 2)
            ELSE 0
        END as scans_per_mb,
        CASE
            WHEN pui.idx_scan = 0 THEN 'UNUSED'
            WHEN pui.idx_scan::NUMERIC / (pg_relation_size(pui.indexrelid) / 1024.0 / 1024.0) > 100 THEN 'EXCELLENT'
            WHEN pui.idx_scan::NUMERIC / (pg_relation_size(pui.indexrelid) / 1024.0 / 1024.0) > 10 THEN 'GOOD'
            WHEN pui.idx_scan::NUMERIC / (pg_relation_size(pui.indexrelid) / 1024.0 / 1024.0) > 1 THEN 'FAIR'
            ELSE 'POOR'
        END::TEXT as effectiveness_score
    FROM pg_stat_user_indexes pui
    WHERE pui.schemaname IN ('civics', 'commerce', 'mobility', 'geo', 'documents')
    ORDER BY scans_per_mb DESC NULLS LAST;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.analyze_index_effectiveness() IS
'Analyze index usage patterns and provide effectiveness scoring';
