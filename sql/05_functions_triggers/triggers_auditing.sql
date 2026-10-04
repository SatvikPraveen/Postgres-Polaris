-- File: sql/05_functions_triggers/triggers_auditing.sql
-- Purpose: Row and statement triggers, trigger WHEN clauses, transition
--          tables, business-rule enforcement, LISTEN/NOTIFY, and a generic
--          JSONB audit trail.
--
-- Standalone and idempotent. Design rule for this lesson:
--   * The audit TABLE and all trigger FUNCTIONS are created permanently
--     (other modules may reuse audit.table_changes / audit.audit_table_changes()).
--   * Triggers on the shared base tables are created INSIDE A TRANSACTION
--     THAT IS ROLLED BACK. PostgreSQL DDL is transactional, so CREATE TRIGGER,
--     the demo DML and the audit rows all disappear at ROLLBACK: later modules
--     see untouched base tables with no extra per-row trigger overhead.
--   * To keep auditing permanently in your own environment, run the
--     "attach" block and replace the final ROLLBACK with COMMIT.

\echo '== 05 triggers_auditing: audit infrastructure =='

-- =============================================================================
-- 1. AUDIT INFRASTRUCTURE (module-owned)
-- =============================================================================

CREATE TABLE IF NOT EXISTS audit.table_changes (
    audit_id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_name       TEXT        NOT NULL,
    table_name        TEXT        NOT NULL,
    operation_type    TEXT        NOT NULL,   -- INSERT / UPDATE / DELETE / BULK_<op>
    record_pk         TEXT,                   -- primary-key value of the audited row
    row_data          JSONB,                  -- full row (NEW for INSERT/UPDATE, OLD for DELETE)
    changed_fields    JSONB,                  -- UPDATE only: {"col": {"old": .., "new": ..}}
    old_values        JSONB,
    new_values        JSONB,
    changed_by        TEXT,                   -- application user (SET app.current_user_id)
    changed_at        TIMESTAMPTZ NOT NULL DEFAULT now(),        -- transaction start time
    statement_at      TIMESTAMPTZ NOT NULL DEFAULT statement_timestamp(),
    transaction_id    XID8        NOT NULL DEFAULT pg_current_xact_id(),
    session_user_name TEXT        NOT NULL DEFAULT session_user,
    client_addr       INET                 DEFAULT inet_client_addr(),
    application_name  TEXT                 DEFAULT current_setting('application_name', true)
);

-- Upgrade path for databases created by an older version of this lesson.
ALTER TABLE audit.table_changes
    ADD COLUMN IF NOT EXISTS record_pk      TEXT,
    ADD COLUMN IF NOT EXISTS statement_at   TIMESTAMPTZ NOT NULL DEFAULT statement_timestamp(),
    ADD COLUMN IF NOT EXISTS transaction_id XID8        NOT NULL DEFAULT pg_current_xact_id();

COMMENT ON TABLE audit.table_changes IS
'Generic row-change audit log written by audit.audit_table_changes() and audit.log_bulk_operation().';

CREATE INDEX IF NOT EXISTS idx_audit_table_time ON audit.table_changes (schema_name, table_name, changed_at);
CREATE INDEX IF NOT EXISTS idx_audit_record     ON audit.table_changes (schema_name, table_name, record_pk);
CREATE INDEX IF NOT EXISTS idx_audit_user       ON audit.table_changes (changed_by) WHERE changed_by IS NOT NULL;
-- An append-only log ordered by time is the textbook BRIN use case.
CREATE INDEX IF NOT EXISTS idx_audit_changed_brin ON audit.table_changes USING brin (changed_at);

-- =============================================================================
-- 2. GENERIC ROW-LEVEL AUDIT TRIGGER FUNCTION
-- =============================================================================
-- Usage: CREATE TRIGGER ... AFTER INSERT OR UPDATE OR DELETE ON t
--        FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes('<pk column>');
--
-- Notes:
--  * AFTER trigger: sees the final row (after BEFORE triggers/defaults) and
--    only fires for rows that were really written.
--  * Fixed bug from the earlier version: it built a %ROWTYPE record and did
--    INSERT ... VALUES (rec.*), which inserts NULL into audit_id instead of
--    using the default, and then silently swallowed the error with
--    WHEN OTHERS -> RAISE WARNING. Always list the target columns.
--  * No blanket exception handler: if the audit insert fails the business
--    change fails too. For compliance auditing that is what you want.
--  * SECURITY DEFINER lets ordinary users write the audit log without INSERT
--    privilege on it; always pin search_path on SECURITY DEFINER functions.
CREATE OR REPLACE FUNCTION audit.audit_table_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_old     JSONB;
    v_new     JSONB;
    v_changed JSONB;
    v_pk_col  TEXT := TG_ARGV[0];
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP IN ('UPDATE', 'INSERT') THEN v_new := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(n.key, jsonb_build_object('old', v_old -> n.key, 'new', n.value))
        INTO v_changed
        FROM jsonb_each(v_new) AS n
        WHERE (v_old -> n.key) IS DISTINCT FROM n.value
          AND n.key NOT IN ('updated_at', 'search_vector');   -- noise columns

        IF v_changed IS NULL THEN
            RETURN NULL;   -- no-op UPDATE: nothing worth logging
        END IF;
    END IF;

    INSERT INTO audit.table_changes
        (schema_name, table_name, operation_type, record_pk,
         row_data, changed_fields, old_values, new_values, changed_by)
    VALUES
        (TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP,
         COALESCE(v_new, v_old) ->> v_pk_col,
         COALESCE(v_new, v_old), v_changed, v_old, v_new,
         NULLIF(current_setting('app.current_user_id', true), ''));

    RETURN NULL;   -- return value of an AFTER ROW trigger is ignored
END;
$$;

COMMENT ON FUNCTION audit.audit_table_changes() IS
'Generic AFTER ROW audit trigger. TG_ARGV[0] = primary-key column name. Logs to audit.table_changes.';

-- =============================================================================
-- 3. STATEMENT-LEVEL TRIGGER WITH TRANSITION TABLES
-- =============================================================================
-- A FOR EACH STATEMENT trigger fires once per statement, even for 0 rows.
-- With REFERENCING NEW TABLE / OLD TABLE (PostgreSQL 10+) it can see every
-- affected row as a relation: one summary row instead of N audit rows.
-- (A trigger with transition tables may only list ONE event, so we create
-- one trigger per operation.) The old version passed TG_ARGV[0] as the row
-- count, which was always NULL.
--
-- Real-world example in the base schema: commerce.order_items keeps
-- commerce.orders totals in sync with three statement-level triggers
-- (trg_order_items_totals_ins / _upd / _del). Each uses REFERENCING
-- NEW TABLE AS new_items and/or OLD TABLE AS old_items, and calls
-- commerce.update_order_totals(). That function collects the DISTINCT
-- order_ids touched by the statement and calls
-- commerce.recompute_order_totals(bigint[]) once. A 10,000-row INSERT
-- therefore recomputes each affected order once, not 10,000 times as a row
-- trigger would. The query below lists those triggers.
SELECT tgname, pg_get_triggerdef(oid) AS definition
FROM pg_trigger
WHERE tgrelid = 'commerce.order_items'::regclass AND NOT tgisinternal
ORDER BY tgname;

CREATE OR REPLACE FUNCTION audit.log_bulk_operation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_rows BIGINT;
BEGIN
    IF TG_OP = 'DELETE' THEN
        SELECT count(*) INTO v_rows FROM old_rows;
    ELSE
        SELECT count(*) INTO v_rows FROM new_rows;
    END IF;

    INSERT INTO audit.table_changes (schema_name, table_name, operation_type, row_data, changed_by)
    VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, 'BULK_' || TG_OP,
            jsonb_build_object('rows_affected', v_rows, 'trigger', TG_NAME),
            NULLIF(current_setting('app.current_user_id', true), ''));
    RETURN NULL;
END;
$$;

COMMENT ON FUNCTION audit.log_bulk_operation() IS
'AFTER STATEMENT trigger using transition tables new_rows/old_rows; logs one BULK_<op> row per statement.';

-- =============================================================================
-- 4. BEFORE ROW TRIGGERS: maintain columns, enforce rules
-- =============================================================================

-- Maintain updated_at. Uses now() deliberately: this stamps a real change.
-- The WHEN clause on the trigger (below) skips no-op updates entirely.
CREATE OR REPLACE FUNCTION analytics.update_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;          -- BEFORE ROW: the returned row is what gets stored
END;
$$;

COMMENT ON FUNCTION analytics.update_updated_at() IS
'BEFORE UPDATE row trigger: sets NEW.updated_at = now().';

-- Derive total_amount when the caller omits it. Note: the CHECK constraint
-- chk_order_total already REJECTS inconsistent totals; a CHECK is cheaper and
-- cannot be bypassed, so use triggers to DERIVE values, constraints to VALIDATE.
CREATE OR REPLACE FUNCTION commerce.validate_order_total()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_expected NUMERIC := NEW.subtotal + NEW.tax_amount + NEW.tip_amount;
BEGIN
    IF NEW.total_amount IS NULL OR NEW.total_amount = 0 THEN
        NEW.total_amount := v_expected;                     -- derive
    ELSIF abs(NEW.total_amount - v_expected) >= 0.01 THEN
        RAISE EXCEPTION 'Order total (%) does not match subtotal + tax + tip (%)',
            NEW.total_amount, v_expected
            USING ERRCODE = 'check_violation', HINT = 'Omit total_amount to have it derived';
    END IF;
    RETURN NEW;
END;
$$;

-- Refuse to delete citizens with open obligations. BEFORE DELETE returning
-- OLD lets the delete proceed; RAISE aborts it (returning NULL would skip it silently).
CREATE OR REPLACE FUNCTION civics.prevent_citizen_deletion()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_permits INTEGER;
    v_balance NUMERIC;
BEGIN
    SELECT count(*) INTO v_permits
    FROM civics.permit_applications
    WHERE citizen_id = OLD.citizen_id AND status IN ('pending', 'approved');

    IF v_permits > 0 THEN
        RAISE EXCEPTION 'Cannot delete citizen % with % active permits', OLD.citizen_id, v_permits
            USING ERRCODE = 'restrict_violation';
    END IF;

    SELECT COALESCE(sum(amount_due - amount_paid), 0) INTO v_balance
    FROM civics.tax_payments
    WHERE citizen_id = OLD.citizen_id AND payment_status <> 'paid';

    IF v_balance > 0 THEN
        RAISE EXCEPTION 'Cannot delete citizen % with outstanding tax balance of $%', OLD.citizen_id, v_balance
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN OLD;
END;
$$;

-- =============================================================================
-- 5. NOTIFICATION TRIGGERS (LISTEN / NOTIFY)
-- =============================================================================
-- pg_notify() is transactional: listeners receive the message only when the
-- sending transaction COMMITS (and duplicates within one transaction are
-- folded). Payload limit is just under 8000 bytes, so send ids, not documents.
--   [Session B]  LISTEN urgent_complaint;   -- then wait; psql prints
--                "Asynchronous notification "urgent_complaint" with payload ..."

CREATE OR REPLACE FUNCTION documents.notify_urgent_complaint()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_notify('urgent_complaint', jsonb_build_object(
        'complaint_id',     NEW.complaint_id,
        'complaint_number', NEW.complaint_number,
        'category',         NEW.category,
        'subject',          NEW.subject,
        'submitted_at',     NEW.submitted_at)::text);
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION civics.notify_tax_payment()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_notify('tax_payment_received', jsonb_build_object(
        'tax_id',       NEW.tax_id,
        'citizen_id',   NEW.citizen_id,
        'tax_type',     NEW.tax_type,
        'amount_paid',  NEW.amount_paid,
        'payment_date', NEW.payment_date)::text);
    RETURN NULL;
END;
$$;

-- =============================================================================
-- 6. AUDIT QUERY / MAINTENANCE FUNCTIONS
-- =============================================================================

-- History of one record. Fixed: the old version looked up row_data->>p_record_id,
-- i.e. used the id VALUE as a JSON key, so it never matched anything.
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
)
LANGUAGE sql
STABLE
AS $$
    SELECT ac.audit_id,
           ac.operation_type,
           ac.changed_at,
           COALESCE(ac.changed_by, ac.session_user_name),
           CASE ac.operation_type
               WHEN 'INSERT' THEN 'Record created'
               WHEN 'DELETE' THEN 'Record deleted'
               WHEN 'UPDATE' THEN 'Updated: ' ||
                    (SELECT string_agg(k, ', ' ORDER BY k) FROM jsonb_object_keys(ac.changed_fields) AS k)
               ELSE ac.operation_type
           END
    FROM audit.table_changes ac
    WHERE ac.schema_name = p_schema_name
      AND ac.table_name  = p_table_name
      AND ac.record_pk   = p_record_id
    ORDER BY ac.audit_id;
$$;

CREATE OR REPLACE FUNCTION audit.cleanup_old_audit_records(
    retention_days INTEGER DEFAULT 2555   -- ~7 years
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    -- Wall-clock retention is correct here: audit rows are stamped with now().
    -- At scale, partition the log by month and DROP old partitions instead
    -- (see sql/08_partitioning_timeseries).
    DELETE FROM audit.table_changes
    WHERE changed_at < now() - make_interval(days => retention_days);
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$;

COMMENT ON FUNCTION audit.cleanup_old_audit_records(INTEGER) IS
'Delete audit records older than the retention period; returns rows deleted.';

DROP FUNCTION IF EXISTS audit.get_audit_statistics();   -- result columns changed from earlier versions
CREATE OR REPLACE FUNCTION audit.get_audit_statistics()
RETURNS TABLE(
    schema_name TEXT,
    table_name TEXT,
    total_changes BIGINT,
    inserts BIGINT,
    updates BIGINT,
    deletes BIGINT,
    bulk_statements BIGINT,
    latest_change TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    SELECT ac.schema_name,
           ac.table_name,
           count(*),
           count(*) FILTER (WHERE ac.operation_type = 'INSERT'),
           count(*) FILTER (WHERE ac.operation_type = 'UPDATE'),
           count(*) FILTER (WHERE ac.operation_type = 'DELETE'),
           count(*) FILTER (WHERE ac.operation_type LIKE 'BULK\_%'),
           max(ac.changed_at)
    FROM audit.table_changes ac
    GROUP BY ac.schema_name, ac.table_name
    ORDER BY count(*) DESC, ac.schema_name, ac.table_name;
$$;

COMMENT ON FUNCTION audit.get_audit_statistics() IS
'Per-table audit counts by operation and latest activity.';

\echo '== 05 triggers_auditing: attach triggers + demo (rolled back) =='

-- =============================================================================
-- 7. ATTACH TRIGGERS AND EXERCISE THEM -- inside a rolled-back transaction
-- =============================================================================
BEGIN;

SET LOCAL app.current_user_id = 'clerk_042';

-- updated_at maintenance; WHEN (OLD IS DISTINCT FROM NEW) skips no-op updates
-- before the function is even called.
CREATE OR REPLACE TRIGGER trg_citizens_updated_at
    BEFORE UPDATE ON civics.citizens
    FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*)
    EXECUTE FUNCTION analytics.update_updated_at();

CREATE OR REPLACE TRIGGER trg_orders_updated_at
    BEFORE UPDATE ON commerce.orders
    FOR EACH ROW WHEN (OLD.* IS DISTINCT FROM NEW.*)
    EXECUTE FUNCTION analytics.update_updated_at();

-- Row-level audit on sensitive tables (argument = PK column name).
CREATE OR REPLACE TRIGGER trg_audit_citizens
    AFTER INSERT OR UPDATE OR DELETE ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes('citizen_id');

CREATE OR REPLACE TRIGGER trg_audit_tax_payments
    AFTER INSERT OR UPDATE OR DELETE ON civics.tax_payments
    FOR EACH ROW EXECUTE FUNCTION audit.audit_table_changes('tax_id');

-- Business rules.
CREATE OR REPLACE TRIGGER trg_prevent_citizen_deletion
    BEFORE DELETE ON civics.citizens
    FOR EACH ROW EXECUTE FUNCTION civics.prevent_citizen_deletion();

CREATE OR REPLACE TRIGGER trg_validate_order_total
    BEFORE INSERT OR UPDATE OF subtotal, tax_amount, tip_amount, total_amount ON commerce.orders
    FOR EACH ROW EXECUTE FUNCTION commerce.validate_order_total();

-- Notifications: the WHEN clause filters in C before calling PL/pgSQL.
CREATE OR REPLACE TRIGGER trg_notify_urgent_complaint
    AFTER INSERT ON documents.complaint_records
    FOR EACH ROW WHEN (NEW.priority_level = 'urgent')
    EXECUTE FUNCTION documents.notify_urgent_complaint();

CREATE OR REPLACE TRIGGER trg_notify_tax_payment
    AFTER UPDATE OF payment_status ON civics.tax_payments
    FOR EACH ROW WHEN (OLD.payment_status IS DISTINCT FROM NEW.payment_status
                       AND NEW.payment_status = 'paid')
    EXECUTE FUNCTION civics.notify_tax_payment();

-- Statement-level bulk logging with transition tables.
CREATE OR REPLACE TRIGGER trg_log_bulk_orders_upd
    AFTER UPDATE ON commerce.orders
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION audit.log_bulk_operation();

CREATE OR REPLACE TRIGGER trg_log_bulk_orders_ins
    AFTER INSERT ON commerce.orders
    REFERENCING NEW TABLE AS new_rows
    FOR EACH STATEMENT EXECUTE FUNCTION audit.log_bulk_operation();

-- What is attached now (row vs statement, timing, events). Triggers of the
-- same timing fire in alphabetical order of name.
SELECT tgrelid::regclass AS table_name,
       tgname,
       CASE WHEN tgtype & 1 = 1 THEN 'ROW' ELSE 'STATEMENT' END AS level,
       CASE WHEN tgtype & 2 = 2 THEN 'BEFORE' WHEN tgtype & 64 = 64 THEN 'INSTEAD OF' ELSE 'AFTER' END AS timing,
       concat_ws(' OR ',
                 CASE WHEN tgtype & 4  = 4  THEN 'INSERT' END,
                 CASE WHEN tgtype & 8  = 8  THEN 'DELETE' END,
                 CASE WHEN tgtype & 16 = 16 THEN 'UPDATE' END) AS events
FROM pg_trigger
WHERE NOT tgisinternal
  AND tgrelid IN ('civics.citizens'::regclass, 'civics.tax_payments'::regclass,
                  'commerce.orders'::regclass, 'documents.complaint_records'::regclass)
ORDER BY 1::text, 2;

-- (a) UPDATE: audit captures only the changed fields; updated_at is bumped.
UPDATE civics.citizens
SET email = 'audit.demo.1@example.org', phone = '(972) 555-9999'
WHERE citizen_id = 1;

-- (b) no-op UPDATE: WHEN clause skips updated_at, audit function logs nothing.
UPDATE civics.citizens SET email = email WHERE citizen_id = 2;

-- (c) Tax payment marked paid -> audit row + NOTIFY (delivered only on commit).
UPDATE civics.tax_payments
SET payment_status = 'paid', amount_paid = amount_due, payment_date = meta.as_of()
WHERE tax_id = (SELECT min(tax_id) FROM civics.tax_payments WHERE payment_status = 'overdue');

-- (d) Business rule: try to delete a citizen with obligations; catch the error
--     (the DO block's exception handler rolls back just that sub-transaction).
DO $$
DECLARE
    v_id BIGINT;
BEGIN
    SELECT t.citizen_id INTO v_id
    FROM civics.tax_payments t
    WHERE t.payment_status = 'overdue'
    ORDER BY t.citizen_id LIMIT 1;

    DELETE FROM civics.citizens WHERE citizen_id = v_id;
    RAISE NOTICE 'unexpected: citizen % deleted', v_id;
EXCEPTION WHEN restrict_violation THEN
    RAISE NOTICE 'Blocked by trigger: %', SQLERRM;
END;
$$;

-- (e) Bulk statement: one BULK_UPDATE row summarises many updated orders.
UPDATE commerce.orders
SET order_notes = COALESCE(order_notes || ' ', '') || '[reviewed]'
WHERE merchant_id = 1;

-- (f) BEFORE trigger derives total_amount when omitted (0 = default).
INSERT INTO commerce.orders (merchant_id, customer_citizen_id, order_number, order_date,
                             status, subtotal, tax_amount, tip_amount)
VALUES (1, 1, 'ORD-TRIGGER-DEMO-1', meta.as_of(), 'pending', 40.00, 3.30, 5.00)
RETURNING order_id, subtotal, tax_amount, tip_amount, total_amount;

-- (g) Urgent complaint -> NOTIFY queued (pending until commit; we roll back).
INSERT INTO documents.complaint_records (complaint_number, subject, description, category, priority_level)
VALUES ('CMP-TRIGGER-DEMO-1', 'Downed power line near school',
        'Power line down across sidewalk; children walk past this location.', 'utilities', 'urgent');

-- Inspect the audit trail written by the triggers.
SELECT audit_id, table_name, operation_type, record_pk, changed_by,
       COALESCE(changed_fields, row_data -> 'rows_affected') AS detail
FROM audit.table_changes
ORDER BY audit_id DESC
LIMIT 6;

SELECT * FROM audit.get_record_history('civics', 'citizens', '1');

SELECT schema_name, table_name, total_changes, inserts, updates, deletes, bulk_statements
FROM audit.get_audit_statistics();

-- Bulk loads: skip user triggers for a session (superuser / replication role).
-- Constraint triggers for FKs are also skipped, so only do this for trusted data.
SET LOCAL session_replication_role = replica;
UPDATE civics.citizens SET phone = '(972) 555-0000' WHERE citizen_id = 3;   -- not audited
SET LOCAL session_replication_role = origin;
SELECT count(*) AS audit_rows_for_citizen_3
FROM audit.table_changes WHERE table_name = 'citizens' AND record_pk = '3';

-- Undo EVERYTHING above: triggers, data changes, audit rows, queued NOTIFYs.
ROLLBACK;

-- Verify nothing from the demo leaked onto the base tables.
SELECT count(*) AS demo_triggers_left_on_base_tables
FROM pg_trigger
WHERE NOT tgisinternal
  AND tgname IN ('trg_citizens_updated_at', 'trg_orders_updated_at', 'trg_audit_citizens',
                 'trg_audit_tax_payments', 'trg_prevent_citizen_deletion', 'trg_validate_order_total',
                 'trg_notify_urgent_complaint', 'trg_notify_tax_payment',
                 'trg_log_bulk_orders_upd', 'trg_log_bulk_orders_ins');
