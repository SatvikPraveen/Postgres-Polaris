-- File: sql/06_jsonb_fulltext/fulltext_search_ranking.sql
-- Purpose: Full-text search, dictionaries, ranking, highlighting + JSONB FTS

-- =============================================================================
-- TEXT SEARCH CONFIGURATION
-- =============================================================================

-- Create custom text search configuration for city documents
CREATE TEXT SEARCH CONFIGURATION city_english (COPY = english);

-- =============================================================================
-- ENHANCED FULL-TEXT SEARCH FUNCTIONS
-- =============================================================================

-- Advanced complaint search with ranking and highlighting
CREATE OR REPLACE FUNCTION documents.search_complaints_advanced(
    search_query TEXT,
    category_filter TEXT DEFAULT NULL,
    priority_filter documents.priority_level DEFAULT NULL,
    limit_count INTEGER DEFAULT 20,
    highlight_fragments BOOLEAN DEFAULT true
)
RETURNS TABLE(
    complaint_id BIGINT,
    complaint_number VARCHAR(50),
    subject VARCHAR(500),
    category VARCHAR(100),
    priority_level documents.priority_level,
    status documents.document_status,
    rank_score REAL,
    highlighted_subject TEXT,
    highlighted_description TEXT,
    submitted_at TIMESTAMPTZ
) AS $
DECLARE
    query_tsquery TSQUERY;
BEGIN
    -- Convert search query to tsquery
    query_tsquery := plainto_tsquery('city_english', search_query);

    RETURN QUERY
    SELECT
        cr.complaint_id,
        cr.complaint_number,
        cr.subject,
        cr.category,
        cr.priority_level,
        cr.status,
        ts_rank(cr.search_vector, query_tsquery) as rank_score,
        CASE
            WHEN highlight_fragments THEN
                ts_headline('city_english', cr.subject, query_tsquery, 'MaxWords=20, MinWords=5')
            ELSE cr.subject
        END as highlighted_subject,
        CASE
            WHEN highlight_fragments THEN
                ts_headline('city_english', cr.description, query_tsquery, 'MaxWords=35, MinWords=10')
            ELSE SUBSTRING(cr.description FROM 1 FOR 200) || '...'
        END as highlighted_description,
        cr.submitted_at
    FROM documents.complaint_records cr
    WHERE cr.search_vector @@ query_tsquery
        AND (category_filter IS NULL OR cr.category = category_filter)
        AND (priority_filter IS NULL OR cr.priority_level = priority_filter)
    ORDER BY ts_rank(cr.search_vector, query_tsquery) DESC, cr.submitted_at DESC
    LIMIT limit_count;
END;
$ LANGUAGE plpgsql;

-- Policy document search with content ranking
CREATE OR REPLACE FUNCTION documents.search_policies_advanced(
    search_query TEXT,
    department_filter TEXT DEFAULT NULL,
    status_filter documents.document_status DEFAULT 'published'
)
RETURNS TABLE(
    policy_id BIGINT,
    policy_number VARCHAR(50),
    title VARCHAR(500),
    department VARCHAR(100),
    rank_score REAL,
    content_snippet TEXT,
    effective_date DATE,
    tags TEXT[]
) AS $
DECLARE
    query_tsquery TSQUERY;
BEGIN
    query_tsquery := plainto_tsquery('city_english', search_query);

    RETURN QUERY
    SELECT
        pd.policy_id,
        pd.policy_number,
        pd.title,
        pd.department,
        ts_rank(pd.search_vector, query_tsquery) as rank_score,
        ts_headline('city_english', pd.document_content::text, query_tsquery, 'MaxWords=40') as content_snippet,
        pd.effective_date,
        pd.tags
    FROM documents.policy_documents pd
    WHERE pd.search_vector @@ query_tsquery
        AND (department_filter IS NULL OR pd.department = department_filter)
        AND pd.status = COALESCE(status_filter, pd.status)
    ORDER BY ts_rank(pd.search_vector, query_tsquery) DESC
    LIMIT 50;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- JSONB FULL-TEXT SEARCH
-- =============================================================================

-- Search within JSONB complaint metadata
CREATE OR REPLACE FUNCTION documents.search_complaint_metadata(
    search_terms TEXT,
    metadata_path TEXT DEFAULT NULL
)
RETURNS TABLE(
    complaint_id BIGINT,
    complaint_number VARCHAR(50),
    category VARCHAR(100),
    metadata_match JSONB,
    rank_score REAL
) AS $
DECLARE
    query_tsquery TSQUERY;
    search_path TEXT[];
BEGIN
    query_tsquery := plainto_tsquery('english', search_terms);

    -- Convert path to array if provided
    IF metadata_path IS NOT NULL THEN
        search_path := string_to_array(metadata_path, '.');
    END IF;

    RETURN QUERY
    SELECT
        cr.complaint_id,
        cr.complaint_number,
        cr.category,
        CASE
            WHEN search_path IS NOT NULL THEN cr.metadata #> search_path
            ELSE cr.metadata
        END as metadata_match,
        ts_rank(to_tsvector('english', cr.metadata::text), query_tsquery) as rank_score
    FROM documents.complaint_records cr
    WHERE to_tsvector('english', cr.metadata::text) @@ query_tsquery
        AND cr.metadata IS NOT NULL
    ORDER BY rank_score DESC
    LIMIT 25;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- ADVANCED RANKING AND WEIGHTING
-- =============================================================================

-- Multi-field search with custom weights
CREATE OR REPLACE FUNCTION analytics.search_city_content(
    search_query TEXT,
    content_types TEXT[] DEFAULT ARRAY['complaints', 'policies', 'citizens']
)
RETURNS TABLE(
    content_type TEXT,
    content_id BIGINT,
    title TEXT,
    snippet TEXT,
    weighted_rank REAL,
    last_updated TIMESTAMPTZ
) AS $
DECLARE
    query_tsquery TSQUERY;
BEGIN
    query_tsquery := plainto_tsquery('city_english', search_query);

    RETURN QUERY
    -- Search complaints (weight: 0.8)
    SELECT
        'complaint'::TEXT as content_type,
        cr.complaint_id::BIGINT,
        cr.subject as title,
        SUBSTRING(cr.description FROM 1 FOR 200) as snippet,
        ts_rank(cr.search_vector, query_tsquery) * 0.8 as weighted_rank,
        cr.updated_at as last_updated
    FROM documents.complaint_records cr
    WHERE 'complaints' = ANY(content_types)
        AND cr.search_vector @@ query_tsquery

    UNION ALL

    -- Search policies (weight: 1.0)
    SELECT
        'policy'::TEXT,
        pd.policy_id::BIGINT,
        pd.title,
        ts_headline('city_english', pd.document_content::text, query_tsquery, 'MaxWords=25') as snippet,
        ts_rank(pd.search_vector, query_tsquery) * 1.0 as weighted_rank,
        pd.updated_at
    FROM documents.policy_documents pd
    WHERE 'policies' = ANY(content_types)
        AND pd.search_vector @@ query_tsquery
        AND pd.status = 'published'

    UNION ALL

    -- Search citizens (weight: 0.3, name searches only)
    SELECT
        'citizen'::TEXT,
        c.citizen_id::BIGINT,
        c.first_name || ' ' || c.last_name as title,
        c.email || ' - ' || c.street_address as snippet,
        ts_rank(to_tsvector('city_english', c.first_name || ' ' || c.last_name), query_tsquery) * 0.3 as weighted_rank,
        c.updated_at
    FROM civics.citizens c
    WHERE 'citizens' = ANY(content_types)
        AND to_tsvector('city_english', c.first_name || ' ' || c.last_name) @@ query_tsquery
        AND c.status = 'active'

    ORDER BY weighted_rank DESC
    LIMIT 50;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- SEARCH ANALYTICS AND OPTIMIZATION
-- =============================================================================

-- Function to track search queries and performance
CREATE TABLE IF NOT EXISTS analytics.search_analytics (
    search_id BIGSERIAL PRIMARY KEY,
    search_query TEXT NOT NULL,
    search_type TEXT,
    results_count INTEGER,
    execution_time_ms NUMERIC(10,3),
    user_id TEXT,
    search_timestamp TIMESTAMPTZ DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION analytics.log_search_query(
    query_text TEXT,
    search_type TEXT,
    result_count INTEGER,
    exec_time NUMERIC DEFAULT NULL
)
RETURNS VOID AS $
BEGIN
    INSERT INTO analytics.search_analytics (
        search_query, search_type, results_count,
        execution_time_ms, user_id
    ) VALUES (
        query_text, search_type, result_count,
        exec_time, current_setting('app.current_user_id', true)
    );
END;
$ LANGUAGE plpgsql;

-- Popular search terms analysis
CREATE OR REPLACE FUNCTION analytics.get_popular_search_terms(
    days_back INTEGER DEFAULT 30,
    min_frequency INTEGER DEFAULT 2
)
RETURNS TABLE(
    search_term TEXT,
    frequency BIGINT,
    avg_results INTEGER,
    avg_execution_ms NUMERIC
) AS $
BEGIN
    RETURN QUERY
    SELECT
        sa.search_query,
        COUNT(*) as frequency,
        AVG(sa.results_count)::INTEGER as avg_results,
        ROUND(AVG(sa.execution_time_ms), 2) as avg_execution_ms
    FROM analytics.search_analytics sa
    WHERE sa.search_timestamp >= CURRENT_DATE - (days_back || ' days')::INTERVAL
        AND length(trim(sa.search_query)) >= 3
    GROUP BY sa.search_query
    HAVING COUNT(*) >= min_frequency
    ORDER BY frequency DESC, avg_results DESC
    LIMIT 25;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- SEARCH SUGGESTION AND AUTOCOMPLETE
-- =============================================================================

-- Generate search suggestions based on content
CREATE OR REPLACE FUNCTION analytics.generate_search_suggestions(
    partial_query TEXT,
    suggestion_limit INTEGER DEFAULT 10
)
RETURNS TABLE(
    suggestion TEXT,
    suggestion_type TEXT,
    frequency_score INTEGER
) AS $
BEGIN
    RETURN QUERY
    -- Subject line suggestions from complaints
    SELECT DISTINCT
        SUBSTRING(cr.subject FROM 1 FOR 100) as suggestion,
        'complaint_subject'::TEXT as suggestion_type,
        1 as frequency_score
    FROM documents.complaint_records cr
    WHERE cr.subject ILIKE '%' || partial_query || '%'
        AND length(partial_query) >= 3

    UNION ALL

    -- Policy title suggestions
    SELECT DISTINCT
        SUBSTRING(pd.title FROM 1 FOR 100) as suggestion,
        'policy_title'::TEXT as suggestion_type,
        2 as frequency_score
    FROM documents.policy_documents pd
    WHERE pd.title ILIKE '%' || partial_query || '%'
        AND pd.status = 'published'
        AND length(partial_query) >= 3

    UNION ALL

    -- Category suggestions
    SELECT DISTINCT
        cr.category as suggestion,
        'category'::TEXT as suggestion_type,
        3 as frequency_score
    FROM documents.complaint_records cr
    WHERE cr.category ILIKE '%' || partial_query || '%'
        AND length(partial_query) >= 2

    ORDER BY frequency_score DESC, suggestion
    LIMIT suggestion_limit;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- TEXT SEARCH MAINTENANCE
-- =============================================================================

-- Update search vectors for all searchable content
CREATE OR REPLACE FUNCTION analytics.refresh_search_vectors()
RETURNS TEXT AS $
DECLARE
    result_summary TEXT := '';
    update_count INTEGER;
BEGIN
    -- Update complaint search vectors
    UPDATE documents.complaint_records
    SET search_vector = to_tsvector('city_english',
        COALESCE(subject, '') || ' ' ||
        COALESCE(description, '') || ' ' ||
        COALESCE(category, '') || ' ' ||
        COALESCE(resolution_notes, '')
    );
    GET DIAGNOSTICS update_count = ROW_COUNT;
    result_summary := result_summary || format('Updated %s complaint records\n', update_count);

    -- Update policy search vectors
    UPDATE documents.policy_documents
    SET search_vector = to_tsvector('city_english',
        COALESCE(title, '') || ' ' ||
        COALESCE(document_content::text, '') || ' ' ||
        COALESCE(array_to_string(tags, ' '), '') || ' ' ||
        COALESCE(array_to_string(keywords, ' '), '')
    );
    GET DIAGNOSTICS update_count = ROW_COUNT;
    result_summary := result_summary || format('Updated %s policy documents\n', update_count);

    RETURN result_summary;
END;
$ LANGUAGE plpgsql;
