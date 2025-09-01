-- File: sql/12_security_rls/rls_policies.sql
-- Purpose: Row-level security for multi-tenant data isolation

-- =============================================================================
-- RLS SETUP FOR CITIZENS TABLE
-- =============================================================================

-- Enable RLS on citizens table
ALTER TABLE civics.citizens ENABLE ROW LEVEL SECURITY;

-- Policy: Citizens can only see their own records
CREATE POLICY citizen_self_access ON civics.citizens
    FOR ALL TO PUBLIC
    USING (citizen_id = current_setting('app.current_citizen_id', true)::BIGINT);

-- Policy: Staff can see all active citizens
CREATE POLICY staff_full_access ON civics.citizens
    FOR ALL TO PUBLIC
    USING (
        current_setting('app.user_role', true) IN ('staff', 'admin', 'supervisor') OR
        current_setting('app.current_citizen_id', true)::BIGINT = citizen_id
    );

-- =============================================================================
-- RLS FOR PERMITS BY NEIGHBORHOOD
-- =============================================================================

ALTER TABLE civics.permit_applications ENABLE ROW LEVEL SECURITY;

-- Citizens see only their own permits
CREATE POLICY permit_citizen_access ON civics.permit_applications
    FOR ALL TO PUBLIC
    USING (citizen_id = current_setting('app.current_citizen_id', true)::BIGINT);

-- Staff see permits in their jurisdiction
CREATE POLICY permit_jurisdiction_access ON civics.permit_applications
    FOR ALL TO PUBLIC
    USING (
        current_setting('app.user_role', true) = 'admin' OR
        (current_setting('app.user_role', true) = 'staff' AND
         current_setting('app.staff_jurisdiction', true) = 'all') OR
        citizen_id = current_setting('app.current_citizen_id', true)::BIGINT
    );

-- =============================================================================
-- RLS FOR BUSINESS DATA
-- =============================================================================

ALTER TABLE commerce.merchants ENABLE ROW LEVEL SECURITY;
ALTER TABLE commerce.orders ENABLE ROW LEVEL SECURITY;

-- Merchants see only their own data
CREATE POLICY merchant_self_access ON commerce.merchants
    FOR ALL TO PUBLIC
    USING (
        owner_citizen_id = current_setting('app.current_citizen_id', true)::BIGINT OR
        merchant_id = current_setting('app.current_merchant_id', true)::BIGINT OR
        current_setting('app.user_role', true) IN ('admin', 'business_inspector')
    );

-- Orders accessible by merchant and customer
CREATE POLICY order_participant_access ON commerce.orders
    FOR ALL TO PUBLIC
    USING (
        merchant_id = current_setting('app.current_merchant_id', true)::BIGINT OR
        customer_citizen_id = current_setting('app.current_citizen_id', true)::BIGINT OR
        current_setting('app.user_role', true) IN ('admin', 'finance_staff')
    );

-- =============================================================================
-- COMPLAINT RLS BY REPORTER
-- =============================================================================

ALTER TABLE documents.complaint_records ENABLE ROW LEVEL SECURITY;

-- Citizens see their own complaints + public ones
CREATE POLICY complaint_access ON documents.complaint_records
    FOR SELECT TO PUBLIC
    USING (
        reporter_citizen_id = current_setting('app.current_citizen_id', true)::BIGINT OR
        current_setting('app.user_role', true) IN ('admin', 'staff', 'complaint_handler') OR
        status IN ('resolved', 'archived')  -- Public visibility for resolved complaints
    );

-- Only reporters can insert/update their complaints
CREATE POLICY complaint_modify ON documents.complaint_records
    FOR INSERT TO PUBLIC
    WITH CHECK (
        reporter_citizen_id = current_setting('app.current_citizen_id', true)::BIGINT OR
        current_setting('app.user_role', true) IN ('admin', 'staff')
    );

-- =============================================================================
-- HELPER FUNCTIONS FOR RLS
-- =============================================================================

-- Function to set user context for RLS
CREATE OR REPLACE FUNCTION auth.set_user_context(
    citizen_id BIGINT DEFAULT NULL,
    merchant_id BIGINT DEFAULT NULL,
    user_role TEXT DEFAULT 'citizen',
    staff_jurisdiction TEXT DEFAULT NULL
)
RETURNS VOID AS $
BEGIN
    -- Set session variables for RLS policies
    PERFORM set_config('app.current_citizen_id', citizen_id::TEXT, false);
    PERFORM set_config('app.current_merchant_id', merchant_id::TEXT, false);
    PERFORM set_config('app.user_role', user_role, false);
    PERFORM set_config('app.staff_jurisdiction', staff_jurisdiction, false);
END;
$ LANGUAGE plpgsql;

-- Function to clear user context
CREATE OR REPLACE FUNCTION auth.clear_user_context()
RETURNS VOID AS $
BEGIN
    PERFORM set_config('app.current_citizen_id', '', false);
    PERFORM set_config('app.current_merchant_id', '', false);
    PERFORM set_config('app.user_role', '', false);
    PERFORM set_config('app.staff_jurisdiction', '', false);
END;
$ LANGUAGE plpgsql;

-- Function to get current user context
CREATE OR REPLACE FUNCTION auth.get_user_context()
RETURNS TABLE(
    citizen_id BIGINT,
    merchant_id BIGINT,
    user_role TEXT,
    staff_jurisdiction TEXT
) AS $
BEGIN
    RETURN QUERY SELECT
        current_setting('app.current_citizen_id', true)::BIGINT,
        current_setting('app.current_merchant_id', true)::BIGINT,
        current_setting('app.user_role', true)::TEXT,
        current_setting('app.staff_jurisdiction', true)::TEXT;
END;
$ LANGUAGE plpgsql;

-- =============================================================================
-- RLS DEMONSTRATION FUNCTIONS
-- =============================================================================

-- Demo RLS in action
CREATE OR REPLACE FUNCTION auth.demo_rls_citizen_access()
RETURNS TABLE(
    scenario TEXT,
    visible_records BIGINT,
    sample_record TEXT
) AS $
BEGIN
    -- Clear any existing context
    PERFORM auth.clear_user_context();

    -- Scenario 1: No user context (admin/public view)
    PERFORM auth.set_user_context(user_role => 'admin');

    RETURN QUERY
    SELECT
        'Admin view (all records)'::TEXT as scenario,
        COUNT(*) as visible_records,
        STRING_AGG(first_name || ' ' || last_name, ', ' ORDER BY citizen_id LIMIT 3) as sample_record
    FROM civics.citizens;

    -- Scenario 2: Citizen view (own record only)
    PERFORM auth.set_user_context(citizen_id => 1, user_role => 'citizen');

    RETURN QUERY
    SELECT
        'Citizen #1 view (own record)'::TEXT as scenario,
        COUNT(*) as visible_records,
        STRING_AGG(first_name || ' ' || last_name, ', ') as sample_record
    FROM civics.citizens;

    -- Scenario 3: Staff view
    PERFORM auth.set_user_context(user_role => 'staff', staff_jurisdiction => 'all');

    RETURN QUERY
    SELECT
        'Staff view (all active)'::TEXT as scenario,
        COUNT(*) as visible_records,
        'Staff can see all active citizens' as sample_record
    FROM civics.citizens
    WHERE status = 'active';

    -- Cleanup
    PERFORM auth.clear_user_context();
END;
$ LANGUAGE plpgsql;
