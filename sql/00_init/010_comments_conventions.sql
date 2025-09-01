-- File: sql/00_init/010_comments_conventions.sql
-- Purpose: Establish naming conventions, commenting standards, and lint rules

-- =============================================================================
-- NAMING CONVENTIONS
-- =============================================================================

-- Tables: lowercase, plural nouns (citizens, orders, trip_segments)
-- Columns: lowercase, snake_case (first_name, created_at, is_active)
-- Indexes: {table}_{columns}_idx (citizens_email_idx, orders_created_at_idx)
-- Foreign Keys: fk_{table}_{referenced_table} (fk_orders_citizens)
-- Constraints: {type}_{table}_{column} (chk_citizens_age, uq_citizens_email)
-- Functions: lowercase, verb_noun format (calculate_tax, validate_permit)
-- Views: v_{purpose} (v_active_citizens, v_monthly_revenue)

-- =============================================================================
-- COMMENT TEMPLATES
-- =============================================================================

-- Table comment template
COMMENT ON TABLE civics.citizens IS
'Master registry of city residents and their core demographics.
Updated via citizen services portal and vital records integration.
Business Rules: All citizens must have valid email, age >= 0';

-- Column comment examples
-- COMMENT ON COLUMN table.column IS 'Description [Business Rule] [Data Source]';

-- =============================================================================
-- STANDARD COLUMN PATTERNS
-- =============================================================================

-- Every table should have these audit columns:
-- created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
-- updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
-- created_by INTEGER REFERENCES civics.citizens(citizen_id),
-- updated_by INTEGER REFERENCES civics.citizens(citizen_id)

-- Status columns should use enums:
-- status civic_status DEFAULT 'active' NOT NULL

-- =============================================================================
-- LINT RULES (for reference)
-- =============================================================================

-- 1. All tables must have primary keys
-- 2. All foreign keys must have indexes
-- 3. All tables must have COMMENT
-- 4. Timestamp columns should be TIMESTAMPTZ not TIMESTAMP
-- 5. Use SERIAL/BIGSERIAL for auto-incrementing IDs
-- 6. Boolean columns should start with is_, has_, can_
-- 7. Avoid VARCHAR without length limits - use TEXT instead
-- 8. Money amounts should be NUMERIC(10,2) not FLOAT

-- =============================================================================
-- HELPER FUNCTIONS FOR DOCUMENTATION
-- =============================================================================

-- Function to generate table documentation
CREATE OR REPLACE FUNCTION analytics.document_table(schema_name TEXT, table_name TEXT)
RETURNS TABLE(
    column_name TEXT,
    data_type TEXT,
    is_nullable TEXT,
    column_default TEXT,
    description TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        c.column_name::TEXT,
        c.data_type::TEXT,
        c.is_nullable::TEXT,
        c.column_default::TEXT,
        COALESCE(pgd.description, 'No description')::TEXT as description
    FROM information_schema.columns c
    LEFT JOIN pg_catalog.pg_statio_all_tables st ON st.schemaname = c.table_schema
        AND st.relname = c.table_name
    LEFT JOIN pg_catalog.pg_description pgd ON pgd.objoid = st.relid
        AND pgd.objsubid = c.ordinal_position
    WHERE c.table_schema = schema_name
        AND c.table_name = document_table.table_name
    ORDER BY c.ordinal_position;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.document_table(TEXT, TEXT) IS
'Generate documentation for a specific table including column descriptions';

-- Function to list all undocumented tables
CREATE OR REPLACE FUNCTION analytics.undocumented_tables()
RETURNS TABLE(schema_name TEXT, table_name TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.table_schema::TEXT,
        t.table_name::TEXT
    FROM information_schema.tables t
    LEFT JOIN pg_catalog.pg_statio_all_tables st ON st.schemaname = t.table_schema
        AND st.relname = t.table_name
    LEFT JOIN pg_catalog.pg_description pgd ON pgd.objoid = st.relid
        AND pgd.objsubid = 0
    WHERE t.table_type = 'BASE TABLE'
        AND t.table_schema NOT IN ('information_schema', 'pg_catalog')
        AND pgd.description IS NULL
    ORDER BY t.table_schema, t.table_name;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION analytics.undocumented_tables() IS
'List all tables that lack COMMENT documentation';
