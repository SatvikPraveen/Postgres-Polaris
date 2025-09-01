-- File: sql/01_schema_design/civics.sql
-- Purpose: Normalized OLTP schema for citizens, permits, taxes, and voting

-- =============================================================================
-- ENUMS AND TYPES
-- =============================================================================

CREATE TYPE civics.civic_status AS ENUM ('active', 'inactive', 'suspended', 'deceased');
CREATE TYPE civics.permit_type AS ENUM ('building', 'business', 'event', 'parking', 'street');
CREATE TYPE civics.permit_status AS ENUM ('pending', 'approved', 'denied', 'expired', 'revoked');
CREATE TYPE civics.tax_type AS ENUM ('property', 'income', 'business', 'vehicle', 'utility');
CREATE TYPE civics.payment_status AS ENUM ('pending', 'paid', 'overdue', 'refunded');
CREATE TYPE civics.vote_type AS ENUM ('municipal', 'school_board', 'referendum', 'special');

-- =============================================================================
-- CORE CITIZENS TABLE
-- =============================================================================

CREATE TABLE civics.citizens (
    citizen_id BIGSERIAL PRIMARY KEY,

    -- Personal Information
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100) NOT NULL,
    date_of_birth DATE NOT NULL,
    ssn_hash VARCHAR(64) UNIQUE, -- Hashed for privacy

    -- Contact Information
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),

    -- Address
    street_address VARCHAR(500) NOT NULL,
    city VARCHAR(100) NOT NULL DEFAULT 'Polaris City',
    state VARCHAR(2) NOT NULL DEFAULT 'TX',
    zip_code VARCHAR(10) NOT NULL,

    -- System fields
    status civics.civic_status DEFAULT 'active' NOT NULL,
    registered_date TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE civics.citizens IS
'Master registry of city residents with core demographics and contact information.
Business Rules: Email must be unique, age must be >= 0, all citizens are Polaris City residents by default';

COMMENT ON COLUMN civics.citizens.ssn_hash IS 'SHA-256 hash of SSN for unique identification without storing actual SSN';
COMMENT ON COLUMN civics.citizens.status IS 'Current civic status affecting service eligibility';

-- =============================================================================
-- PERMIT APPLICATIONS
-- =============================================================================

CREATE TABLE civics.permit_applications (
    permit_id BIGSERIAL PRIMARY KEY,
    citizen_id BIGINT NOT NULL REFERENCES civics.citizens(citizen_id),

    -- Permit details
    permit_type civics.permit_type NOT NULL,
    permit_number VARCHAR(50) UNIQUE NOT NULL,
    description TEXT NOT NULL,

    -- Location for permit
    property_address VARCHAR(500),
    parcel_id VARCHAR(50), -- GIS parcel identifier

    -- Status tracking
    status civics.permit_status DEFAULT 'pending' NOT NULL,
    application_date TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    approval_date TIMESTAMPTZ,
    expiration_date TIMESTAMPTZ,

    -- Financial
    fee_amount NUMERIC(10,2) NOT NULL DEFAULT 0.00,
    fee_paid NUMERIC(10,2) NOT NULL DEFAULT 0.00,

    -- Audit
    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    processed_by INTEGER REFERENCES civics.citizens(citizen_id) -- Staff member
);

COMMENT ON TABLE civics.permit_applications IS
'All permit applications with status tracking and fee management.
Business Rules: permit_number must be unique, fee_paid cannot exceed fee_amount';

-- =============================================================================
-- TAX RECORDS
-- =============================================================================

CREATE TABLE civics.tax_payments (
    tax_id BIGSERIAL PRIMARY KEY,
    citizen_id BIGINT NOT NULL REFERENCES civics.citizens(citizen_id),

    -- Tax details
    tax_type civics.tax_type NOT NULL,
    tax_year INTEGER NOT NULL,
    assessment_amount NUMERIC(12,2) NOT NULL,

    -- Payment tracking
    amount_due NUMERIC(12,2) NOT NULL,
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0.00,
    payment_status civics.payment_status DEFAULT 'pending' NOT NULL,

    -- Important dates
    due_date DATE NOT NULL,
    payment_date TIMESTAMPTZ,

    -- Property tax specifics (nullable for other tax types)
    property_address VARCHAR(500),
    assessed_value NUMERIC(12,2),
    mill_rate NUMERIC(8,4), -- Tax rate per $1000 of assessed value

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE civics.tax_payments IS
'Citizen tax obligations and payment history across all tax types.
Business Rules: amount_paid cannot exceed amount_due, mill_rate applies to property taxes only';

-- =============================================================================
-- VOTING RECORDS
-- =============================================================================

CREATE TABLE civics.voting_records (
    vote_id BIGSERIAL PRIMARY KEY,
    citizen_id BIGINT NOT NULL REFERENCES civics.citizens(citizen_id),

    -- Election details
    election_name VARCHAR(200) NOT NULL,
    election_date DATE NOT NULL,
    vote_type civics.vote_type NOT NULL,

    -- Voting information
    precinct VARCHAR(50) NOT NULL,
    ballot_style VARCHAR(50),
    voted_at TIMESTAMPTZ NOT NULL,

    -- Method tracking
    voting_method VARCHAR(50) DEFAULT 'in_person', -- in_person, mail, early, absentee

    created_at TIMESTAMPTZ DEFAULT NOW() NOT NULL
);

COMMENT ON TABLE civics.voting_records IS
'Anonymized voting participation records (not vote choices).
Business Rules: Only tracks participation, not actual votes for privacy';

-- =============================================================================
-- INDEXES FOR PERFORMANCE
-- =============================================================================

-- Citizens indexes
CREATE INDEX idx_citizens_email ON civics.citizens(email);
CREATE INDEX idx_citizens_name ON civics.citizens(last_name, first_name);
CREATE INDEX idx_citizens_zip ON civics.citizens(zip_code);
CREATE INDEX idx_citizens_status ON civics.citizens(status) WHERE status != 'active';

-- Permits indexes
CREATE INDEX idx_permits_citizen ON civics.permit_applications(citizen_id);
CREATE INDEX idx_permits_status ON civics.permit_applications(status);
CREATE INDEX idx_permits_type ON civics.permit_applications(permit_type);
CREATE INDEX idx_permits_dates ON civics.permit_applications(application_date, expiration_date);
CREATE INDEX idx_permits_parcel ON civics.permit_applications(parcel_id) WHERE parcel_id IS NOT NULL;

-- Tax indexes
CREATE INDEX idx_taxes_citizen_year ON civics.tax_payments(citizen_id, tax_year);
CREATE INDEX idx_taxes_status ON civics.tax_payments(payment_status);
CREATE INDEX idx_taxes_due_date ON civics.tax_payments(due_date) WHERE payment_status != 'paid';
CREATE INDEX idx_taxes_type_year ON civics.tax_payments(tax_type, tax_year);

-- Voting indexes
CREATE INDEX idx_votes_citizen ON civics.voting_records(citizen_id);
CREATE INDEX idx_votes_election ON civics.voting_records(election_date, election_name);
CREATE INDEX idx_votes_precinct ON civics.voting_records(precinct, election_date);

-- =============================================================================
-- SAMPLE DATA QUERIES (for reference)
-- =============================================================================

/*
-- Find active citizens with outstanding tax obligations
SELECT c.first_name, c.last_name, c.email,
       COUNT(t.tax_id) as outstanding_taxes,
       SUM(t.amount_due - t.amount_paid) as total_owed
FROM civics.citizens c
JOIN civics.tax_payments t ON c.citizen_id = t.citizen_id
WHERE c.status = 'active'
    AND t.payment_status != 'paid'
    AND t.due_date < CURRENT_DATE
GROUP BY c.citizen_id, c.first_name, c.last_name, c.email
ORDER BY total_owed DESC;

-- Permit approval rates by type
SELECT permit_type,
       COUNT(*) as total_applications,
       COUNT(*) FILTER (WHERE status = 'approved') as approved,
       ROUND(COUNT(*) FILTER (WHERE status = 'approved') * 100.0 / COUNT(*), 1) as approval_rate_pct
FROM civics.permit_applications
WHERE application_date >= CURRENT_DATE - INTERVAL '1 year'
GROUP BY permit_type
ORDER BY approval_rate_pct DESC;

-- Voter turnout by election
SELECT election_name, election_date,
       COUNT(DISTINCT citizen_id) as voters,
       (SELECT COUNT(*) FROM civics.citizens WHERE status = 'active') as eligible_citizens,
       ROUND(COUNT(DISTINCT citizen_id) * 100.0 /
             (SELECT COUNT(*) FROM civics.citizens WHERE status = 'active'), 1) as turnout_pct
FROM civics.voting_records
GROUP BY election_name, election_date
ORDER BY election_date DESC;
*/
