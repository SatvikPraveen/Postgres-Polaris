-- Location: /examples/security_showcase.sql
-- RLS + masking + audit demo - comprehensive security patterns

SELECT '🔒 Security Showcase - RLS, Masking & Audit Patterns' as title;

-- Demo 1: Row Level Security (RLS) Setup
SELECT 'Demo 1: Row Level Security Implementation' as demo;

-- Create a multi-tenant scenario with organizations
CREATE TABLE IF NOT EXISTS organizations (
    org_id SERIAL PRIMARY KEY,
    org_name VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS org_users (
    user_id SERIAL PRIMARY KEY,
    username VARCHAR(50) NOT NULL,
    email VARCHAR(100) NOT NULL,
    org_id INTEGER REFERENCES organizations(org_id),
    role VARCHAR(20) DEFAULT 'user',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS org_documents (
    doc_id SERIAL PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    content TEXT,
    org_id INTEGER REFERENCES organizations(org_id),
    created_by INTEGER REFERENCES org_users(user_id),
    classification VARCHAR(20) DEFAULT 'internal',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Insert sample multi-tenant data
INSERT INTO organizations (org_name) VALUES
    ('Acme Corp'),
    ('Beta Industries'),
    ('Gamma Solutions')
ON CONFLICT DO NOTHING;

INSERT INTO org_users (username, email, org_id, role) VALUES
    ('alice_acme', 'alice@acme.com', 1, 'admin'),
    ('bob_acme', 'bob@acme.com', 1, 'user'),
    ('carol_beta', 'carol@beta.com', 2, 'admin'),
    ('david_beta', 'david@beta.com', 2, 'user'),
    ('eve_gamma', 'eve@gamma.com', 3, 'user')
ON CONFLICT DO NOTHING;

INSERT INTO org_documents (title, content, org_id, created_by, classification) VALUES
    ('Acme Q1 Report', 'Confidential quarterly results...', 1, 1, 'confidential'),
    ('Acme Public Announcement', 'Public press release...', 1, 2, 'public'),
    ('Beta Strategy Doc', 'Internal strategy document...', 2, 3, 'internal'),
    ('Beta HR Policy', 'Employee handbook...', 2, 4, 'internal'),
    ('Gamma Project Plan', 'Project timeline and budget...', 3, 5, 'confidential')
ON CONFLICT DO NOTHING;

-- Enable RLS on documents table
ALTER TABLE org_documents ENABLE ROW LEVEL SECURITY;

-- Create RLS policies
DROP POLICY IF EXISTS org_isolation_policy ON org_documents;
CREATE POLICY org_isolation_policy ON org_documents
    FOR ALL TO PUBLIC
    USING (org_id = current_setting('app.current_org_id', true)::integer);

-- Create classification-based policy
DROP POLICY IF EXISTS classification_policy ON org_documents;
CREATE POLICY classification_policy ON org_documents
    FOR SELECT TO PUBLIC
    USING (
        classification = 'public' OR
        (classification = 'internal' AND current_setting('app.current_user_role', true) IN ('user', 'admin')) OR
        (classification = 'confidential' AND current_setting('app.current_user_role', true) = 'admin')
    );

-- Demo RLS in action
SELECT 'Testing RLS policies...' as test;

-- Set context for Acme Corp admin user
SELECT set_config('app.current_org_id', '1', false);
SELECT set_config('app.current_user_role', 'admin', false);

SELECT 'Documents visible to Acme admin:' as scenario;
SELECT doc_id, title, classification, org_id FROM org_documents;

-- Set context for Beta Industries regular user
SELECT set_config('app.current_org_id', '2', false);
SELECT set_config('app.current_user_role', 'user', false);

SELECT 'Documents visible to Beta user (no confidential):' as scenario;
SELECT doc_id, title, classification, org_id FROM org_documents;

-- Demo 2: Data Masking and Privacy
SELECT 'Demo 2: Data Masking and Privacy Protection' as demo;

-- Create masked view for PII protection
CREATE OR REPLACE VIEW citizens_masked AS
SELECT
    citizen_id,
    CASE
        WHEN current_setting('app.current_user_role', true) = 'admin' THEN name
        ELSE SUBSTRING(name, 1, 1) || '***'
    END as name,
    CASE
        WHEN current_setting('app.current_user_role', true) = 'admin' THEN email
        ELSE REGEXP_REPLACE(email, '(.{2}).*(@.*)', '\1***\2')
    END as email,
    CASE
        WHEN current_setting('app.current_user_role', true) = 'admin' THEN phone
        ELSE REGEXP_REPLACE(phone, '(\d{3})-(\d{3})-.*', '\1-\2-****')
    END as phone,
    city,
    state,
    registration_date
FROM citizens;

-- Test data masking
SELECT 'Data masking for regular user:' as test;
SELECT set_config('app.current_user_role', 'user', false);
SELECT * FROM citizens_masked LIMIT 5;

SELECT 'Full data for admin user:' as test;
SELECT set_config('app.current_user_role', 'admin', false);
SELECT * FROM citizens_masked LIMIT 5;

-- Demo 3: Audit Trail Implementation
SELECT 'Demo 3: Comprehensive Audit Trail System' as demo;

-- Create audit log table
CREATE TABLE IF NOT EXISTS audit_log (
    audit_id SERIAL PRIMARY KEY,
    table_name VARCHAR(50) NOT NULL,
    operation VARCHAR(10) NOT NULL,
    row_id INTEGER,
    old_values JSONB,
    new_values JSONB,
    changed_by VARCHAR(100),
    changed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    session_id TEXT,
    ip_address INET,
    user_agent TEXT
);

-- Create audit trigger function
CREATE OR REPLACE FUNCTION audit_trigger_function()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (
            table_name, operation, row_id, old_values,
            changed_by, session_id, ip_address
        ) VALUES (
            TG_TABLE_NAME, TG_OP, OLD.citizen_id, to_jsonb(OLD),
            current_setting('app.current_username', true),
            current_setting('app.session_id', true),
            current_setting('app.client_ip', true)::inet
        );
        RETURN OLD;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (
            table_name, operation, row_id, old_values, new_values,
            changed_by, session_id, ip_address
        ) VALUES (
            TG_TABLE_NAME, TG_OP, NEW.citizen_id, to_jsonb(OLD), to_jsonb(NEW),
            current_setting('app.current_username', true),
            current_setting('app.session_id', true),
            current_setting('app.client_ip', true)::inet
        );
        RETURN NEW;
    ELSIF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (
            table_name, operation, row_id, new_values,
            changed_by, session_id, ip_address
        ) VALUES (
            TG_TABLE_NAME, TG_OP, NEW.citizen_id, to_jsonb(NEW),
            current_setting('app.current_username', true),
            current_setting('app.session_id', true),
            current_setting('app.client_ip', true)::inet
        );
        RETURN NEW;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Create audit triggers
DROP TRIGGER IF EXISTS citizens_audit_trigger ON citizens;
CREATE TRIGGER citizens_audit_trigger
    AFTER INSERT OR UPDATE OR DELETE ON citizens
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_function();

-- Test audit functionality
SELECT 'Testing audit trail...' as test;

-- Set audit context
SELECT set_config('app.current_username', 'security_admin', false);
SELECT set_config('app.session_id', 'sess_' || extract(epoch from now()), false);
SELECT set_config('app.client_ip', '192.168.1.100', false);

-- Perform audited operations
INSERT INTO citizens (name, email, phone, city, state, registration_date)
VALUES ('Security Test User', 'security@test.com', '555-TEST', 'TestCity', 'TS', CURRENT_DATE);

UPDATE citizens
SET email = 'updated_security@test.com'
WHERE email = 'security@test.com';

-- View audit trail
SELECT 'Recent audit log entries:' as audit_results;
SELECT
    audit_id,
    table_name,
    operation,
    row_id,
    changed_by,
    changed_at,
    CASE
        WHEN old_values IS NOT NULL THEN jsonb_pretty(old_values)
        ELSE 'N/A'
    END as old_values_sample
FROM audit_log
WHERE table_name = 'citizens'
ORDER BY changed_at DESC
LIMIT 5;

-- Demo 4: Role-Based Access Control (RBAC)
SELECT 'Demo 4: Role-Based Access Control Implementation' as demo;

-- Create roles and permissions
DO $$
BEGIN
    -- Create roles if they don't exist (handle errors gracefully)
    BEGIN
        CREATE ROLE security_admin;
    EXCEPTION WHEN duplicate_object THEN
        -- Role already exists
    END;

    BEGIN
        CREATE ROLE data_analyst;
    EXCEPTION WHEN duplicate_object THEN
        -- Role already exists
    END;

    BEGIN
        CREATE ROLE readonly_user;
    EXCEPTION WHEN duplicate_object THEN
        -- Role already exists
    END;
END $$;

-- Grant appropriate permissions
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO security_admin;
GRANT SELECT, INSERT, UPDATE ON citizens, orders TO data_analyst;
GRANT SELECT ON citizens_masked, orders TO readonly_user;

-- Show role permissions
SELECT
    'Role-based permissions configured' as rbac_status,
    'security_admin: Full access' as admin_perms,
    'data_analyst: Read/write on main tables' as analyst_perms,
    'readonly_user: Read-only access to masked data' as user_perms;

-- Demo 5: Encryption and Sensitive Data Protection
SELECT 'Demo 5: Data Encryption and Sensitive Data Protection' as demo;

-- Create table with encrypted fields (using pgcrypto if available)
DO $$
BEGIN
    -- Check if pgcrypto extension exists
    IF NOT EXISTS (SELECT FROM pg_extension WHERE extname = 'pgcrypto') THEN
        RAISE NOTICE 'pgcrypto extension not available - demonstrating concept only';
    ELSE
        -- Create secure customer table with encrypted fields
        CREATE TABLE IF NOT EXISTS secure_customers (
            customer_id SERIAL PRIMARY KEY,
            name_encrypted BYTEA, -- Encrypted name
            email_hash VARCHAR(64), -- Hashed email for searching
            phone_encrypted BYTEA, -- Encrypted phone
            created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
        );

        -- Insert encrypted data
        INSERT INTO secure_customers (name_encrypted, email_hash, phone_encrypted)
        SELECT
            pgp_sym_encrypt(name, 'encryption_key_here'),
            encode(digest(email, 'sha256'), 'hex'),
            pgp_sym_encrypt(phone, 'encryption_key_here')
        FROM citizens LIMIT 3;

        -- Query encrypted data
        RAISE NOTICE 'Encrypted data sample:';
        FOR rec IN
            SELECT
                customer_id,
                pgp_sym_decrypt(name_encrypted, 'encryption_key_here') as decrypted_name,
                email_hash,
                length(phone_encrypted) as encrypted_phone_length
            FROM secure_customers LIMIT 2
        LOOP
            RAISE NOTICE '  ID: %, Name: %, Email Hash: %',
                rec.customer_id, rec.decrypted_name, LEFT(rec.email_hash, 16) || '...';
        END LOOP;
    END IF;
END $$;

-- Demo 6: Security Monitoring and Alerting
SELECT 'Demo 6: Security Monitoring and Threat Detection' as demo;

-- Create security events table
CREATE TABLE IF NOT EXISTS security_events (
    event_id SERIAL PRIMARY KEY,
    event_type VARCHAR(50) NOT NULL,
    severity VARCHAR(20) NOT NULL,
    description TEXT,
    user_info JSONB,
    event_data JSONB,
    detected_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMP WITH TIME ZONE,
    status VARCHAR(20) DEFAULT 'open'
);

-- Create function to detect suspicious activities
CREATE OR REPLACE FUNCTION detect_suspicious_activity()
RETURNS TRIGGER AS $$
DECLARE
    recent_failures INTEGER;
    suspicious_threshold INTEGER := 5;
BEGIN
    -- Count recent failed attempts (simulated)
    IF TG_OP = 'INSERT' AND NEW.table_name = 'citizens' THEN
        -- Simulate detection of bulk insert (potential data breach)
        SELECT COUNT(*) INTO recent_failures
        FROM audit_log
        WHERE table_name = 'citizens'
        AND operation = 'INSERT'
        AND changed_at > NOW() - INTERVAL '5 minutes';

        IF recent_failures > suspicious_threshold THEN
            INSERT INTO security_events (
                event_type, severity, description, user_info, event_data
            ) VALUES (
                'BULK_INSERT_DETECTED',
                'HIGH',
                'Suspicious bulk insert activity detected',
                jsonb_build_object(
                    'username', current_setting('app.current_username', true),
                    'session_id', current_setting('app.session_id', true),
                    'ip_address', current_setting('app.client_ip', true)
                ),
                jsonb_build_object(
                    'table_name', NEW.table_name,
                    'recent_inserts', recent_failures,
                    'threshold', suspicious_threshold
                )
            );
        END IF;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Create security monitoring trigger
DROP TRIGGER IF EXISTS security_monitor_trigger ON audit_log;
CREATE TRIGGER security_monitor_trigger
    AFTER INSERT ON audit_log
    FOR EACH ROW EXECUTE FUNCTION detect_suspicious_activity();

-- Demo 7: Data Retention and Privacy Compliance
SELECT 'Demo 7: Data Retention and Privacy Compliance (GDPR/CCPA)' as demo;

-- Create data retention policy table
CREATE TABLE IF NOT EXISTS data_retention_policies (
    policy_id SERIAL PRIMARY KEY,
    table_name VARCHAR(50) NOT NULL,
    retention_period INTERVAL NOT NULL,
    anonymize_after INTERVAL,
    delete_after INTERVAL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Insert retention policies
INSERT INTO data_retention_policies (table_name, retention_period, anonymize_after, delete_after)
VALUES
    ('audit_log', '7 years', '2 years', '10 years'),
    ('citizens', '5 years', '3 years', NULL), -- NULL means don't auto-delete
    ('orders', '7 years', '5 years', NULL)
ON CONFLICT DO NOTHING;

-- Create function for GDPR compliance (right to be forgotten)
CREATE OR REPLACE FUNCTION anonymize_user_data(user_citizen_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    affected_rows INTEGER := 0;
BEGIN
    -- Log the anonymization request
    INSERT INTO audit_log (
        table_name, operation, row_id, old_values, new_values, changed_by
    ) VALUES (
        'citizens', 'ANONYMIZE', user_citizen_id,
        to_jsonb((SELECT row_to_json(c) FROM citizens c WHERE citizen_id = user_citizen_id)),
        '{"status": "anonymized"}'::jsonb,
        'GDPR_COMPLIANCE_SYSTEM'
    );

    -- Anonymize citizen data
    UPDATE citizens
    SET
        name = 'ANONYMIZED_' || citizen_id,
        email = 'anonymized_' || citizen_id || '@deleted.local',
        phone = 'XXX-XXX-XXXX',
        address_line = 'ANONYMIZED'
    WHERE citizen_id = user_citizen_id;

    GET DIAGNOSTICS affected_rows = ROW_COUNT;

    -- Update related orders (keep for business records but remove PII)
    UPDATE orders
    SET delivery_address = 'ANONYMIZED ADDRESS'
    WHERE customer_id = user_citizen_id;

    RETURN affected_rows > 0;
END;
$$ LANGUAGE plpgsql;

-- Test anonymization function
SELECT 'Testing GDPR anonymization...' as test;

-- Before anonymization
SELECT 'Before anonymization:' as before_state;
SELECT citizen_id, name, email, phone
FROM citizens
WHERE citizen_id = (SELECT MAX(citizen_id) FROM citizens);

-- Perform anonymization
SELECT anonymize_user_data((SELECT MAX(citizen_id) FROM citizens)) as anonymization_result;

-- After anonymization
SELECT 'After anonymization:' as after_state;
SELECT citizen_id, name, email, phone
FROM citizens
WHERE citizen_id = (SELECT MAX(citizen_id) FROM citizens);

-- Demo 8: Security Assessment and Compliance Check
SELECT 'Demo 8: Security Assessment and Compliance Validation' as demo;

-- Security compliance checklist
WITH security_checklist AS (
    SELECT
        'Row Level Security' as security_control,
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_policies WHERE tablename = 'org_documents'
        ) THEN '✓ Enabled' ELSE '✗ Missing' END as status,
        'Multi-tenant data isolation' as purpose

    UNION ALL

    SELECT
        'Audit Trail',
        CASE WHEN EXISTS (
            SELECT 1 FROM information_schema.tables WHERE table_name = 'audit_log'
        ) THEN '✓ Implemented' ELSE '✗ Missing' END,
        'Change tracking and compliance'

    UNION ALL

    SELECT
        'Data Masking',
        CASE WHEN EXISTS (
            SELECT 1 FROM information_schema.views WHERE table_name = 'citizens_masked'
        ) THEN '✓ Active' ELSE '✗ Missing' END,
        'PII protection'

    UNION ALL

    SELECT
        'Encryption Capability',
        CASE WHEN EXISTS (
            SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto'
        ) THEN '✓ Available' ELSE '⚠ Not installed' END,
        'Data at rest protection'

    UNION ALL

    SELECT
        'GDPR Compliance',
        CASE WHEN EXISTS (
            SELECT 1 FROM information_schema.routines WHERE routine_name = 'anonymize_user_data'
        ) THEN '✓ Implemented' ELSE '✗ Missing' END,
        'Right to be forgotten'

    UNION ALL

    SELECT
        'Security Monitoring',
        CASE WHEN EXISTS (
            SELECT 1 FROM information_schema.tables WHERE table_name = 'security_events'
        ) THEN '✓ Active' ELSE '✗ Missing' END,
        'Threat detection'
)
SELECT
    security_control,
    status,
    purpose
FROM security_checklist
ORDER BY
    CASE WHEN status LIKE '✓%' THEN 1
         WHEN status LIKE '⚠%' THEN 2
         ELSE 3 END;

-- Security metrics dashboard
SELECT 'Security Metrics Dashboard:' as metrics;

WITH security_metrics AS (
    SELECT
        'Total Audit Events (24h)' as metric,
        COUNT(*)::text as value
    FROM audit_log
    WHERE changed_at > NOW() - INTERVAL '24 hours'

    UNION ALL

    SELECT
        'Security Events (Open)',
        COUNT(*)::text
    FROM security_events
    WHERE status = 'open'

    UNION ALL

    SELECT
        'Protected Tables',
        COUNT(DISTINCT tablename)::text
    FROM pg_policies

    UNION ALL

    SELECT
        'Active User Sessions',
        COUNT(DISTINCT session_id)::text
    FROM audit_log
    WHERE changed_at > NOW() - INTERVAL '1 hour'
    AND session_id IS NOT NULL
)
SELECT metric, value FROM security_metrics;

-- Final Security Summary
DO $
DECLARE
    rls_tables integer;
    audit_events integer;
    security_violations integer;
    masked_views integer;
BEGIN
    -- Count security implementations
    SELECT COUNT(DISTINCT tablename) INTO rls_tables FROM pg_policies;
    SELECT COUNT(*) INTO audit_events FROM audit_log WHERE changed_at > NOW() - INTERVAL '24 hours';
    SELECT COUNT(*) INTO security_violations FROM security_events WHERE status = 'open';
    SELECT COUNT(*) INTO masked_views FROM information_schema.views WHERE table_name LIKE '%_masked';

    RAISE NOTICE '===========================================';
    RAISE NOTICE 'SECURITY SHOWCASE SUMMARY';
    RAISE NOTICE '===========================================';
    RAISE NOTICE 'Security Controls Implemented:';
    RAISE NOTICE '• Row Level Security (RLS) - % protected tables', rls_tables;
    RAISE NOTICE '• Comprehensive audit trail - % events (24h)', audit_events;
    RAISE NOTICE '• Data masking and privacy protection - % masked views', masked_views;
    RAISE NOTICE '• Role-based access control (RBAC)';
    RAISE NOTICE '• Encryption capabilities (where available)';
    RAISE NOTICE '• Security monitoring and threat detection';
    RAISE NOTICE '• GDPR compliance (right to be forgotten)';
    RAISE NOTICE '• Data retention policies';
    RAISE NOTICE '';
    RAISE NOTICE 'Security Features Demonstrated:';
    RAISE NOTICE '• Multi-tenant data isolation';
    RAISE NOTICE '• Dynamic data masking based on user roles';
    RAISE NOTICE '• Complete audit trail with context tracking';
    RAISE NOTICE '• Automated security event detection';
    RAISE NOTICE '• Data anonymization for privacy compliance';
    RAISE NOTICE '• Encryption for sensitive data protection';
    RAISE NOTICE '• Role-based permission management';
    RAISE NOTICE '• Security compliance validation';
    RAISE NOTICE '';
    RAISE NOTICE 'Current Status:';
    RAISE NOTICE '• Open Security Violations: %', security_violations;
    RAISE NOTICE '• Audit Events (24h): %', audit_events;
    RAISE NOTICE '• RLS Protected Tables: %', rls_tables;
    RAISE NOTICE '';
    RAISE NOTICE 'Security Best Practices Applied:';
    RAISE NOTICE '• Defense in depth with multiple security layers';
    RAISE NOTICE '• Principle of least privilege';
    RAISE NOTICE '• Complete audit trail for compliance';
    RAISE NOTICE '• Automated threat detection and monitoring';
    RAISE NOTICE '• Privacy by design with data masking';
    RAISE NOTICE '• Encryption for data protection';
    RAISE NOTICE '• Compliance with privacy regulations (GDPR/CCPA)';
    RAISE NOTICE '';
    RAISE NOTICE 'Recommended Next Steps:';
    RAISE NOTICE '• Implement SSL/TLS for data in transit';
    RAISE NOTICE '• Set up regular security assessments';
    RAISE NOTICE '• Configure automated backup encryption';
    RAISE NOTICE '• Implement intrusion detection systems';
    RAISE NOTICE '• Regular security training for database users';
    RAISE NOTICE '• Penetration testing and vulnerability assessments';
    RAISE NOTICE '===========================================';
    RAISE NOTICE '🔒 Security showcase completed successfully!';
END $;
