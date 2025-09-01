-- File: sql/05_functions_triggers/triggers_auditing.sql
-- Purpose: Row/statement triggers and comprehensive audit trails

-- =============================================================================
-- AUDIT INFRASTRUCTURE
-- =============================================================================

-- Generic audit table for all table changes
CREATE TABLE IF NOT EXISTS audit.table_changes (
    audit_id BIGSERIAL PRIMARY KEY,
    schema_name TEXT NOT NULL,
    table_name TEXT NOT NULL,
    operation_type TEXT NOT NULL, -- INSERT, UPDATE, DELETE
    row_data JSONB,
    changed_fields JSONB,
    old_values JSONB,
    new_values JSONB,
    changed_by TEXT,
    changed_at TIMESTAMPTZ DEFAULT NOW(),
    session_user_name TEXT DEFAULT SESSION_USER,
    client_addr INET DEFAULT INET_CLIENT_ADDR(),
    application_name TEXT DEFAULT current_setting('application_name', true)
);

CREATE INDEX idx_audit_table_time ON audit.table_changes(schema_name, table_name, changed_at);
CREATE INDEX idx_audit_operation ON audit.table_changes(operation_type);
CREATE INDEX idx_audit_user ON audit.table_changes(changed_by);

-- =============================================================================
-- GENERIC AUDIT TRIGGER FUNCTION
-- =============================================================================

CREATE OR REPLACE FUNCTION audit.audit_table_changes()
RETURNS TRIGGER AS $$
DECLARE
    audit_row audit.table_changes%ROWTYPE;
    include_values BOOLEAN = true;
    old_data JSONB;
    new_data JSONB;
    changed_data JSONB = '{}'::JSONB;
BEGIN
    -- Determine operation type and data
    IF TG_OP = 'DELETE' THEN
        old_data = to_jsonb(OLD);
        audit_row.operation_type = 'DELETE';
        audit_row.row_data = old_data;
    ELSIF TG_OP = 'INSERT' THEN
        new_data = to_jsonb(NEW);
        audit_row.operation_type = 'INSERT';
        audit_row.row_data = new_data;
    ELSIF TG_OP = 'UPDATE' THEN
        old_data = to_jsonb(OLD);
        new_data = to_jsonb(NEW);
        audit_row.operation_type = 'UPDATE';
        audit_row.row_data = new_data;

        -- Calculate changed fields
        SELECT jsonb_object_agg(key, jsonb_build_object('old', old_data->key, 'new', new_data->key))
        INTO changed_data
        FROM jsonb_each(new_data)
        WHERE old_data->key IS DISTINCT FROM new_data->key;

        audit_row.changed_fields = changed_data;
        audit_row.old_values = old_data;
    END IF;

    audit_row.schema_name = TG_TABLE_SCHEMA;
    audit_row.table_name = TG_TABLE_NAME;
    audit_row.new_values = new_data;
    audit_row.changed_by = current_setting('app.current_user_id', true);

    INSERT INTO audit.table_changes VALUES (audit_row.*);

    RETURN COALESCE(NEW, OLD);
EXCEPTION
    WHEN OTHERS THEN
        -- Don't fail the original operation due to audit issues
        RAISE WARNING 'Audit trigger failed: %', SQLERRM;
        RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION audit.audit_table_changes() IS
'Generic audit trigger function that logs all table changes to audit.table_changes';

-- =============================================================================
-- BUSINESS-SPECIFIC TRIGGERS
-- =============================================================================

-- Update timestamps trigger
CREATE OR REPLACE FUNCTION analytics.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all tables with updated_at column
CREATE TRIGGER trg_citizens_updated_at
    BEFORE UPDATE ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION analytics.update_updated_at();

CREATE TRIGGER trg_merchants_updated_at
    BEFORE UPDATE ON commerce.merchants
    FOR EACH ROW EXECUTE FUNCTION analytics.update_updated_at();

CREATE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON commerce.orders
    FOR EACH ROW EXECUTE FUNCTION analytics.update_updated_at();

CREATE TRIGGER trg_permits_updated_at
    BEFORE UPDATE ON civics.permit_applications
    FOR EACH ROW EXECUTE FUNCTION analytics.update_updated_at();

CREATE TRIGGER trg_complaints_updated_at
    BEFORE UPDATE ON documents.complaint_records
    FOR EACH ROW EXECUTE FUNCTION analytics.update_updated_at();

-- =============================================================================
-- AUDIT TRIGGERS FOR SENSITIVE TABLES
-- =============================================================================

-- Audit citizen changes
CREATE TRIGGER trg_audit_citizens
    AFTER INSERT OR UPDATE OR DELETE ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes();

-- Audit tax payment changes
CREATE TRIGGER trg_audit_tax_payments
    AFTER INSERT OR UPDATE OR DELETE ON civics.tax_payments
    FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes();

-- Audit business license changes
CREATE TRIGGER trg_audit_business_licenses
    AFTER INSERT OR UPDATE OR DELETE ON commerce.business_licenses
    FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes();

-- Audit policy document changes
CREATE TRIGGER trg_audit_policy_documents
    AFTER INSERT OR UPDATE OR DELETE ON documents.policy_documents
    FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes();

-- =============================================================================
-- BUSINESS RULE ENFORCEMENT TRIGGERS
-- =============================================================================

-- Prevent deletion of citizens with active permits or outstanding taxes
CREATE OR REPLACE FUNCTION civics.prevent_citizen_deletion()
RETURNS TRIGGER AS $$
DECLARE
    permit_count INTEGER;
    tax_balance NUMERIC;
BEGIN
    -- Check for active permits
    SELECT COUNT(*) INTO permit_count
    FROM civics.permit_applications
    WHERE citizen_id = OLD.citizen_id
        AND status IN ('pending', 'approved');

    IF permit_count > 0 THEN
        RAISE EXCEPTION 'Cannot delete citizen with % active permits', permit_count;
    END IF;

    -- Check for outstanding tax balance
    SELECT COALESCE(SUM(amount_due - amount_paid), 0) INTO tax_balance
    FROM civics.tax_payments
    WHERE citizen_id = OLD.citizen_id
        AND payment_status != 'paid';

    IF tax_balance > 0 THEN
        RAISE EXCEPTION 'Cannot delete citizen with outstanding tax balance of $%', tax_balance;
    END IF;

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_citizen_deletion
    BEFORE DELETE ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION civics.prevent_citizen_deletion();

-- Order total validation trigger
CREATE OR REPLACE FUNCTION commerce.validate_order_total()
RETURNS TRIGGER AS $$
DECLARE
    calculated_total NUMERIC;
BEGIN
    calculated_total := NEW.subtotal + NEW.tax_amount + NEW.tip_amount;

    IF ABS(NEW.total_amount - calculated_total) > 0.01 THEN
        RAISE EXCEPTION 'Order total (%) does not match subtotal + tax + tip (%)',
            NEW.total_amount, calculated_total;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_order_total
    BEFORE INSERT OR UPDATE ON commerce.orders
    FOR EACH ROW EXECUTE FUNCTION commerce.validate_order_total();

-- =============================================================================
-- NOTIFICATION TRIGGERS
-- =============================================================================

-- High priority complaint notification
CREATE OR REPLACE FUNCTION documents.notify_urgent_complaint()
RETURNS TRIGGER AS $$
DECLARE
    notification_payload JSONB;
BEGIN
    IF NEW.priority_level = 'urgent' THEN
        notification_payload := jsonb_build_object(
            'complaint_id', NEW.complaint_id,
            'complaint_number', NEW.complaint_number,
            'category', NEW.category,
            'subject', NEW.subject,
            'reporter_email', NEW.reporter_email,
            'submitted_at', NEW.submitted_at
        );

        PERFORM pg_notify('urgent_complaint', notification_payload::TEXT);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_notify_urgent_complaint
    AFTER INSERT ON documents.complaint_records
    FOR EACH ROW EXECUTE FUNCTION documents.notify_urgent_complaint();

-- Tax payment notification
CREATE OR REPLACE FUNCTION civics.notify_tax_payment()
RETURNS TRIGGER AS $$
DECLARE
    payment_info JSONB;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.payment_status != 'paid' AND NEW.payment_status = 'paid' THEN
        payment_info := jsonb_build_object(
            'tax_id', NEW.tax_id,
            'citizen_id', NEW.citizen_id,
            'tax_type', NEW.tax_type,
            'amount_paid', NEW.amount_paid,
            'payment_date', NEW.payment_date
        );

        PERFORM pg_notify('tax_payment_received', payment_info::TEXT);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_notify_tax_payment
    AFTER UPDATE ON civics.tax_payments
    FOR EACH ROW EXECUTE FUNCTION civics.notify_tax_payment();

-- =============================================================================
-- STATEMENT-LEVEL TRIGGERS
-- =============================================================================

-- Log bulk operations
CREATE OR REPLACE FUNCTION audit.log_bulk_operation()
RETURNS TRIGGER AS $$
DECLARE
    operation_log JSONB;
BEGIN
    operation_log := jsonb_build_object(
        'operation', TG_OP,
        'table', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        'rows_affected', TG_ARGV[0],
        'timestamp', NOW(),
        'user', SESSION_USER
    );

    INSERT INTO audit.table_changes (
        schema_name, table_name, operation_type,
        row_data, changed_by, changed_at
    ) VALUES (
        TG_TABLE_SCHEMA, TG_TABLE_NAME, 'BULK_' || TG_OP,
        operation_log, SESSION_USER, NOW()
    );

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Apply to tables where bulk operations are common
CREATE TRIGGER trg_log_bulk_orders
    AFTER INSERT OR UPDATE OR DELETE ON commerce.orders
    FOR EACH STATEMENT EXECUTE FUNCTION audit.log_bulk_operation();

-- =============================================================================
-- AUDIT MANAGEMENT FUNCTIONS
-- =============================================================================

-- Function to get audit history for a specific record
CREATE OR REPLACE FUNCTION audit.get_record_history(
    p_schema_name TEXT,
    p_table_name TEXT,
    p_record_id TEXT
)
RETURNS TABLE(
    audit_id BIGINT,
    operation_type TEXT,
    changed_at TIMESTAMPTZ,
    changed_by TEXT,
    changes_summary TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ac.audit_id,
        ac.operation_type,
        ac.changed_at,
        COALESCE(ac.changed_by, ac.session_user_name) as changed_by,
        CASE
            WHEN ac.operation_type = 'INSERT' THEN 'Record created'
            WHEN ac.operation_type = 'DELETE' THEN 'Record deleted'
            WHEN ac.operation_type = 'UPDATE' THEN
                'Updated: ' || (
                    SELECT string_agg(key, ', ')
                    FROM jsonb_object_keys(COALESCE(ac.changed_fields, '{}'::jsonb)) AS key
                )
            ELSE ac.operation_type
        END as changes_summary
    FROM audit.table_changes ac
    WHERE ac.schema_name = p_schema_name
        AND ac.table_name = p_table_name
        AND (
            ac.row_data->>p_record_id = p_record_id OR
            ac.old_values->>p_record_id = p_record_id
        )
    ORDER BY ac.changed_at DESC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to clean old audit records
CREATE OR REPLACE FUNCTION audit.cleanup_old_audit_records(
    retention_days INTEGER DEFAULT 2555 -- 7 years default
)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM audit.table_changes
    WHERE changed_at < CURRENT_DATE - (retention_days || ' days')::INTERVAL;

    GET DIAGNOSTICS deleted_count = ROW_COUNT;

    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION audit.cleanup_old_audit_records(INTEGER) IS
'Clean up audit records older than specified retention period';

-- Function to get audit statistics
CREATE OR REPLACE FUNCTION audit.get_audit_statistics()
RETURNS TABLE(
    schema_name TEXT,
    table_name TEXT,
    total_changes BIGINT,
    inserts BIGINT,
    updates BIGINT,
    deletes BIGINT,
    latest_change TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        ac.schema_name,
        ac.table_name,
        COUNT(*) as total_changes,
        COUNT(*) FILTER (WHERE ac.operation_type = 'INSERT') as inserts,
        COUNT(*) FILTER (WHERE ac.operation_type = 'UPDATE') as updates,
        COUNT(*) FILTER (WHERE ac.operation_type = 'DELETE') as deletes,
        MAX(ac.changed_at) as latest_change
    FROM audit.table_changes ac
    GROUP BY ac.schema_name, ac.table_name
    ORDER BY total_changes DESC;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION audit.get_audit_statistics() IS
'Get audit statistics by table showing operation counts and latest activity';
