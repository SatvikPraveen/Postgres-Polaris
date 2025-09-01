-- File: sql/01_schema_design/documents.sql
-- Purpose: JSONB document storage for complaints, notes, policies, and flexible content

-- =============================================================================
-- ENUMS AND TYPES
-- =============================================================================

CREATE TYPE documents.document_type AS ENUM (
    'complaint', 'policy', 'notice', 'report', 'form', 'meeting_minutes',
    'correspondence', 'application', 'permit_docs', 'other'
);

CREATE TYPE documents.document_status AS ENUM (
    'draft', 'submitted', 'under_review', 'approved', 'published',
    'archived', 'rejected', 'expired'
);

CREATE TYPE documents.priority_level AS ENUM ('low', 'normal', 'high', 'urgent');

CREATE TYPE documents.access_level AS ENUM ('public', 'internal', 'restricted', 'confidential');

-- =============================================================================
-- COMPLAINT RECORDS
-- =============================================================================

CREATE TABLE documents.complaint_records (
    complaint_id BIGSERIAL PRIMARY KEY,

    -- Reporter information
    reporter_citizen_id BIGINT REFERENCES civics.citizens(citizen_id),
    reporter_name VARCHAR(200), -- For anonymous or non-citizen complaints
    reporter_email VARCHAR(255),
    reporter_phone VARCHAR(20),

    -- Complaint details
    complaint_number VARCHAR(50) UNIQUE NOT NULL,
    subject VARCHAR(500) NOT NULL,
    description TEXT NOT NULL,

    -- Classification
    category VARCHAR(100) NOT NULL, -- Noise, trash, roads, utilities, etc.
    subcategory VARCHAR(100),
    priority_level documents.priority_level DEFAULT 'normal',

    -- Location
    incident_address VARCHAR(500),
    incident_latitude DECIMAL(10,8),
    incident_longitude DECIMAL(11,8),
    neighborhood_id BIGINT REFERENCES geo.neighborhood_boundaries(neighborhood_id),

    -- Status tracking
    status documents.document_status DEFAULT 'submitted' NOT NULL,
    assigned_to VARCHAR(200), -- Department or staff member

    -- Dates
    incident_date TIMESTAMPTZ,
    submitted_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    acknowledged_at TIMESTAMPTZ,
    resolved_at TIMESTAMPTZ,

    -- Resolution
    resolution_notes TEXT,
    resolution_actions JSONB, -- Array of actions taken

    -- Additional data (flexible JSONB storage)
    metadata JSONB,

    -- Attachments reference (could link to file storage system)
    attachments JSONB, -- [{"name": "photo1.jpg", "url": "...", "type": "image"}]

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE documents.complaint_records IS
'Citizen complaints with flexible JSONB storage for category-specific data and attachments.
Business Rules: complaint_number unique, resolution required when status is resolved';

-- =============================================================================
-- POLICY DOCUMENTS
-- =============================================================================

CREATE TABLE documents.policy_documents (
    policy_id BIGSERIAL PRIMARY KEY,

    -- Document identification
    policy_number VARCHAR(50) UNIQUE NOT NULL,
    title VARCHAR(500) NOT NULL,
    version VARCHAR(20) DEFAULT '1.0' NOT NULL,

    -- Document structure (stored as JSONB)
    document_content JSONB NOT NULL,

    -- Classification
    document_type documents.document_type DEFAULT 'policy' NOT NULL,
    department VARCHAR(100) NOT NULL,
    policy_area VARCHAR(100), -- Planning, Public Safety, Finance, etc.

    -- Access control
    access_level documents.access_level DEFAULT 'public' NOT NULL,

    -- Status and lifecycle
    status documents.document_status DEFAULT 'draft' NOT NULL,
    effective_date DATE,
    expiration_date DATE,
    review_date DATE,

    -- Authorship
    created_by INTEGER REFERENCES civics.citizens(citizen_id),
    approved_by INTEGER REFERENCES civics.citizens(citizen_id),

    -- Document history
    supersedes_policy_id BIGINT REFERENCES documents.policy_documents(policy_id),
    change_log JSONB, -- Track version changes

    -- Search and tagging
    tags TEXT[],
    keywords TEXT[],

    -- Additional metadata
    metadata JSONB,

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE documents.policy_documents IS
'Policy documents stored as structured JSONB with version control and access management.
Business Rules: policy_number unique per version, effective_date required for published status';

-- =============================================================================
-- PERFORMANCE INDEXES
-- =============================================================================

-- Complaints indexes
CREATE INDEX idx_complaints_reporter ON documents.complaint_records(reporter_citizen_id);
CREATE INDEX idx_complaints_status ON documents.complaint_records(status);
CREATE INDEX idx_complaints_category ON documents.complaint_records(category);
CREATE INDEX idx_complaints_neighborhood ON documents.complaint_records(neighborhood_id);
CREATE INDEX idx_complaints_submitted ON documents.complaint_records(submitted_at DESC);
CREATE INDEX idx_complaints_location ON documents.complaint_records(incident_latitude, incident_longitude)
    WHERE incident_latitude IS NOT NULL;
CREATE INDEX idx_complaints_metadata ON documents.complaint_records USING GIN(metadata);

-- Policies indexes
CREATE INDEX idx_policies_number ON documents.policy_documents(policy_number);
CREATE INDEX idx_policies_status ON documents.policy_documents(status);
CREATE INDEX idx_policies_department ON documents.policy_documents(department);
CREATE INDEX idx_policies_access ON documents.policy_documents(access_level);
CREATE INDEX idx_policies_effective ON documents.policy_documents(effective_date)
    WHERE status = 'published';
CREATE INDEX idx_policies_content ON documents.policy_documents USING GIN(document_content);
CREATE INDEX idx_policies_tags ON documents.policy_documents USING GIN(tags);

-- =============================================================================
-- JSONB VALIDATION FUNCTIONS
-- =============================================================================

-- Validate complaint metadata structure
CREATE OR REPLACE FUNCTION documents.validate_complaint_metadata(metadata_json JSONB)
RETURNS BOOLEAN AS $
BEGIN
    -- Check for required fields based on category
    IF metadata_json ? 'category' THEN
        CASE metadata_json->>'category'
            WHEN 'noise' THEN
                RETURN metadata_json ? 'decibel_level' OR metadata_json ? 'time_of_day';
            WHEN 'utilities' THEN
                RETURN metadata_json ? 'utility_type' OR metadata_json ? 'outage_duration';
            WHEN 'roads' THEN
                RETURN metadata_json ? 'road_condition' OR metadata_json ? 'hazard_type';
            ELSE
                RETURN true; -- No specific validation for other categories
        END CASE;
    END IF;

    RETURN true;
END;
$ LANGUAGE plpgsql;

-- Validate policy document content structure
CREATE OR REPLACE FUNCTION documents.validate_policy_content(content_json JSONB)
RETURNS BOOLEAN AS $
BEGIN
    -- Ensure basic required structure
    RETURN (
        content_json ? 'title' AND
        content_json ? 'sections' AND
        jsonb_typeof(content_json->'sections') = 'array'
    );
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- FULL-TEXT SEARCH SETUP
-- =============================================================================

-- Add text search vector columns for complaints
ALTER TABLE documents.complaint_records
ADD COLUMN search_vector tsvector;

-- Update search vector on insert/update
CREATE OR REPLACE FUNCTION documents.update_complaint_search_vector()
RETURNS TRIGGER AS $
BEGIN
    NEW.search_vector := to_tsvector('english',
        COALESCE(NEW.subject, '') || ' ' ||
        COALESCE(NEW.description, '') || ' ' ||
        COALESCE(NEW.category, '') || ' ' ||
        COALESCE(NEW.resolution_notes, '')
    );
    RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER trg_complaint_search_vector
    BEFORE INSERT OR UPDATE ON documents.complaint_records
    FOR EACH ROW EXECUTE FUNCTION documents.update_complaint_search_vector();

-- GIN index for full-text search
CREATE INDEX idx_complaints_search ON documents.complaint_records USING GIN(search_vector);

-- Add text search for policies
ALTER TABLE documents.policy_documents
ADD COLUMN search_vector tsvector;

CREATE OR REPLACE FUNCTION documents.update_policy_search_vector()
RETURNS TRIGGER AS $
BEGIN
    NEW.search_vector := to_tsvector('english',
        COALESCE(NEW.title, '') || ' ' ||
        COALESCE(NEW.document_content::text, '') || ' ' ||
        COALESCE(array_to_string(NEW.tags, ' '), '') || ' ' ||
        COALESCE(array_to_string(NEW.keywords, ' '), '')
    );
    RETURN NEW;
END;
$ LANGUAGE plpgsql;

CREATE TRIGGER trg_policy_search_vector
    BEFORE INSERT OR UPDATE ON documents.policy_documents
    FOR EACH ROW EXECUTE FUNCTION documents.update_policy_search_vector();

CREATE INDEX idx_policies_search ON documents.policy_documents USING GIN(search_vector);

-- =============================================================================
-- HELPER FUNCTIONS
-- =============================================================================

-- Search complaints with ranking
CREATE OR REPLACE FUNCTION documents.search_complaints(
    search_query TEXT,
    limit_count INTEGER DEFAULT 20
)
RETURNS TABLE(
    complaint_id BIGINT,
    complaint_number VARCHAR(50),
    subject VARCHAR(500),
    category VARCHAR(100),
    status documents.document_status,
    rank_score REAL
) AS $
BEGIN
    RETURN QUERY
    SELECT
        c.complaint_id,
        c.complaint_number,
        c.subject,
        c.category,
        c.status,
        ts_rank(c.search_vector, plainto_tsquery('english', search_query)) as rank_score
    FROM documents.complaint_records c
    WHERE c.search_vector @@ plainto_tsquery('english', search_query)
    ORDER BY rank_score DESC, c.submitted_at DESC
    LIMIT limit_count;
END;
$ LANGUAGE plpgsql;

-- Get complaint statistics by category
CREATE OR REPLACE FUNCTION documents.complaint_stats_by_category()
RETURNS TABLE(
    category VARCHAR(100),
    total_complaints BIGINT,
    resolved_complaints BIGINT,
    avg_resolution_days NUMERIC,
    resolution_rate_pct NUMERIC
) AS $
BEGIN
    RETURN QUERY
    SELECT
        c.category,
        COUNT(*) as total_complaints,
        COUNT(*) FILTER (WHERE c.status = 'resolved') as resolved_complaints,
        ROUND(AVG(EXTRACT(EPOCH FROM (c.resolved_at - c.submitted_at))/86400), 1) as avg_resolution_days,
        ROUND(COUNT(*) FILTER (WHERE c.status = 'resolved') * 100.0 / COUNT(*), 1) as resolution_rate_pct
    FROM documents.complaint_records c
    GROUP BY c.category
    ORDER BY total_complaints DESC;
END;
$ LANGUAGE plpgsql;
