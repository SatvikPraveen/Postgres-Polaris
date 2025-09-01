-- File: sql/06_jsonb_fulltext/jsonb_modeling_validation.sql
-- Purpose: JSONB patterns, validation checks, and GIN indexes

-- =============================================================================
-- JSONB MODELING PATTERNS
-- =============================================================================

-- Add JSONB columns to existing tables for flexible data
ALTER TABLE civics.citizens ADD COLUMN IF NOT EXISTS preferences JSONB DEFAULT '{}'::jsonb;
ALTER TABLE commerce.merchants ADD COLUMN IF NOT EXISTS business_metadata JSONB DEFAULT '{}'::jsonb;
ALTER TABLE mobility.stations ADD COLUMN IF NOT EXISTS sensor_data JSONB DEFAULT '{}'::jsonb;

-- Update with sample JSONB data
UPDATE civics.citizens SET preferences = jsonb_build_object(
    'communication', jsonb_build_object(
        'email_notifications', true,
        'sms_alerts', false,
        'preferred_language', 'en'
    ),
    'services', jsonb_build_object(
        'auto_pay_taxes', true,
        'paperless_billing', true
    ),
    'accessibility', jsonb_build_object(
        'large_text', false,
        'high_contrast', false
    )
) WHERE preferences = '{}'::jsonb;

UPDATE commerce.merchants SET business_metadata = jsonb_build_object(
    'operating_hours', jsonb_build_object(
        'monday', jsonb_build_object('open', '09:00', 'close', '18:00'),
        'tuesday', jsonb_build_object('open', '09:00', 'close', '18:00'),
        'sunday', jsonb_build_object('open', '10:00', 'close', '16:00')
    ),
    'features', jsonb_build_array('parking', 'wifi', 'wheelchair_accessible'),
    'payment_methods', jsonb_build_array('cash', 'credit', 'contactless'),
    'social_media', jsonb_build_object(
        'website', 'https://example.com',
        'facebook', '@businesspage'
    )
) WHERE business_metadata = '{}'::jsonb;

-- =============================================================================
-- JSONB VALIDATION FUNCTIONS
-- =============================================================================

-- Validate citizen preferences structure
CREATE OR REPLACE FUNCTION civics.validate_citizen_preferences(prefs JSONB)
RETURNS BOOLEAN AS $$
BEGIN
    -- Check for required top-level keys
    IF NOT (prefs ? 'communication' AND prefs ? 'services') THEN
        RETURN false;
    END IF;

    -- Validate communication preferences
    IF NOT (prefs->'communication' ? 'email_notifications') THEN
        RETURN false;
    END IF;

    -- Validate boolean values
    IF jsonb_typeof(prefs->'communication'->'email_notifications') != 'boolean' THEN
        RETURN false;
    END IF;

    -- Validate language code
    IF prefs->'communication'->>'preferred_language' NOT IN ('en', 'es', 'fr') THEN
        RETURN false;
    END IF;

    RETURN true;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Validate business metadata
CREATE OR REPLACE FUNCTION commerce.validate_business_metadata(metadata JSONB)
RETURNS BOOLEAN AS $$
DECLARE
    day_name TEXT;
    hours_obj JSONB;
BEGIN
    -- Validate operating hours structure
    IF metadata ? 'operating_hours' THEN
        FOR day_name IN SELECT * FROM jsonb_object_keys(metadata->'operating_hours') LOOP
            hours_obj := metadata->'operating_hours'->day_name;

            -- Check for open/close times
            IF NOT (hours_obj ? 'open' AND hours_obj ? 'close') THEN
                RETURN false;
            END IF;

            -- Validate time format (basic check)
            IF NOT (hours_obj->>'open' ~ '^\d{2}:\d{2}$' AND hours_obj->>'close' ~ '^\d{2}:\d{2}$') THEN
                RETURN false;
            END IF;
        END LOOP;
    END IF;

    -- Validate features array
    IF metadata ? 'features' THEN
        IF jsonb_typeof(metadata->'features') != 'array' THEN
            RETURN false;
        END IF;
    END IF;

    RETURN true;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- CHECK CONSTRAINTS FOR JSONB VALIDATION
-- =============================================================================

-- Add validation constraints
ALTER TABLE civics.citizens
    ADD CONSTRAINT chk_citizen_preferences_valid
    CHECK (preferences IS NULL OR civics.validate_citizen_preferences(preferences));

ALTER TABLE commerce.merchants
    ADD CONSTRAINT chk_business_metadata_valid
    CHECK (business_metadata IS NULL OR commerce.validate_business_metadata(business_metadata));

-- =============================================================================
-- GIN INDEXES FOR JSONB QUERIES
-- =============================================================================

-- General JSONB indexes for containment queries
CREATE INDEX idx_citizens_preferences_gin ON civics.citizens USING gin(preferences);
CREATE INDEX idx_merchants_metadata_gin ON commerce.merchants USING gin(business_metadata);
CREATE INDEX idx_complaints_metadata_gin ON documents.complaint_records USING gin(metadata);
CREATE INDEX idx_policies_content_gin ON documents.policy_documents USING gin(document_content);

-- Path-specific indexes for common queries
CREATE INDEX idx_citizens_email_notifications ON civics.citizens
    USING gin((preferences->'communication'->'email_notifications'));

CREATE INDEX idx_merchants_features ON commerce.merchants
    USING gin((business_metadata->'features'));

CREATE INDEX idx_complaints_category_severity ON documents.complaint_records
    USING gin((metadata->'category'), (metadata->'severity'));

-- =============================================================================
-- JSONB QUERY PATTERNS AND EXAMPLES
-- =============================================================================

-- Containment queries (@> operator)
-- Find citizens who prefer email notifications
/*
SELECT citizen_id, first_name, last_name
FROM civics.citizens
WHERE preferences @> '{"communication": {"email_notifications": true}}';
*/

-- Existence queries (? operator)
-- Find merchants with parking feature
/*
SELECT business_name, business_metadata->'features' as features
FROM commerce.merchants
WHERE business_metadata->'features' ? 'parking';
*/

-- Path queries (->, ->> operators)
-- Get preferred languages of all citizens
/*
SELECT
    first_name || ' ' || last_name as name,
    preferences->'communication'->>'preferred_language' as language
FROM civics.citizens
WHERE preferences->'communication' ? 'preferred_language';
*/

-- Array operations
-- Find merchants accepting contactless payments
/*
SELECT business_name
FROM commerce.merchants
WHERE business_metadata->'payment_methods' ? 'contactless';
*/

-- =============================================================================
-- JSONB UPDATE PATTERNS
-- =============================================================================

-- Function to update nested JSONB values safely
CREATE OR REPLACE FUNCTION analytics.jsonb_update_path(
    target JSONB,
    path TEXT[],
    new_value JSONB
)
RETURNS JSONB AS $$
DECLARE
    result JSONB := target;
BEGIN
    IF array_length(path, 1) IS NULL OR array_length(path, 1) = 0 THEN
        RETURN new_value;
    END IF;

    -- Use jsonb_set for path updates
    result := jsonb_set(result, path, new_value, true);

    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function to merge JSONB objects
CREATE OR REPLACE FUNCTION analytics.jsonb_merge_deep(
    original JSONB,
    updates JSONB
)
RETURNS JSONB AS $$
DECLARE
    result JSONB := original;
    key TEXT;
    value JSONB;
BEGIN
    FOR key, value IN SELECT * FROM jsonb_each(updates) LOOP
        IF jsonb_typeof(original->key) = 'object' AND jsonb_typeof(value) = 'object' THEN
            -- Recursively merge nested objects
            result := jsonb_set(result, ARRAY[key], analytics.jsonb_merge_deep(original->key, value));
        ELSE
            -- Direct replacement for non-objects
            result := jsonb_set(result, ARRAY[key], value);
        END IF;
    END LOOP;

    RETURN result;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- =============================================================================
-- JSONB AGGREGATION FUNCTIONS
-- =============================================================================

-- Aggregate JSONB preferences to find common patterns
CREATE OR REPLACE FUNCTION analytics.analyze_citizen_preferences()
RETURNS TABLE(
    preference_path TEXT,
    value_distribution JSONB
) AS $$
BEGIN
    RETURN QUERY
    WITH preference_paths AS (
        SELECT
            'communication.email_notifications' as path,
            preferences->'communication'->>'email_notifications' as value
        FROM civics.citizens
        WHERE preferences ? 'communication'

        UNION ALL

        SELECT
            'communication.preferred_language' as path,
            preferences->'communication'->>'preferred_language' as value
        FROM civics.citizens
        WHERE preferences->'communication' ? 'preferred_language'

        UNION ALL

        SELECT
            'services.auto_pay_taxes' as path,
            preferences->'services'->>'auto_pay_taxes' as value
        FROM civics.citizens
        WHERE preferences ? 'services'
    )
    SELECT
        pp.path,
        jsonb_object_agg(pp.value, count_val) as value_distribution
    FROM (
        SELECT path, value, COUNT(*) as count_val
        FROM preference_paths
        WHERE value IS NOT NULL
        GROUP BY path, value
    ) pp
    GROUP BY pp.path
    ORDER BY pp.path;
END;
$$ LANGUAGE plpgsql;

-- =============================================================================
-- JSONB MAINTENANCE FUNCTIONS
-- =============================================================================

-- Function to clean up empty JSONB objects
CREATE OR REPLACE FUNCTION analytics.cleanup_empty_jsonb()
RETURNS INTEGER AS $$
DECLARE
    cleanup_count INTEGER := 0;
BEGIN
    -- Update empty preferences to NULL
    UPDATE civics.citizens
    SET preferences = NULL
    WHERE preferences = '{}'::jsonb;

    GET DIAGNOSTICS cleanup_count = ROW_COUNT;

    -- Update empty metadata to NULL
    UPDATE commerce.merchants
    SET business_metadata = NULL
    WHERE business_metadata = '{}'::jsonb;

    GET DIAGNOSTICS cleanup_count = cleanup_count + ROW_COUNT;

    RETURN cleanup_count;
END;
$$ LANGUAGE plpgsql;

-- Function to validate all JSONB data integrity
CREATE OR REPLACE FUNCTION analytics.validate_all_jsonb_data()
RETURNS TABLE(
    table_name TEXT,
    column_name TEXT,
    invalid_count BIGINT,
    sample_invalid_ids BIGINT[]
) AS $$
BEGIN
    -- Check citizen preferences
    RETURN QUERY
    SELECT
        'civics.citizens'::TEXT,
        'preferences'::TEXT,
        COUNT(*) as invalid_count,
        ARRAY_AGG(citizen_id ORDER BY citizen_id LIMIT 5) as sample_invalid_ids
    FROM civics.citizens
    WHERE preferences IS NOT NULL
        AND NOT civics.validate_citizen_preferences(preferences)
    HAVING COUNT(*) > 0;

    -- Check merchant metadata
    RETURN QUERY
    SELECT
        'commerce.merchants'::TEXT,
        'business_metadata'::TEXT,
        COUNT(*) as invalid_count,
        ARRAY_AGG(merchant_id ORDER BY merchant_id LIMIT 5) as sample_invalid_ids
    FROM commerce.merchants
    WHERE business_metadata IS NOT NULL
        AND NOT commerce.validate_business_metadata(business_metadata)
    HAVING COUNT(*) > 0;
END;
$$ LANGUAGE plpgsql;
