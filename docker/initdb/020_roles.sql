-- First-boot initialisation, step 3: application roles.
-- Group roles carry privileges; login roles inherit them. Object-level
-- grants are applied by sql/00_init after the schemas exist.
\set ON_ERROR_STOP on

DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY[
        'polaris_app_readonly', 'polaris_app_readwrite',
        'polaris_analyst', 'polaris_developer', 'polaris_auditor']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;

    -- Login role used by the row-level-security and privilege modules.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'polaris_app_user') THEN
        CREATE ROLE polaris_app_user LOGIN PASSWORD 'polaris_dev_only'
            IN ROLE polaris_app_readwrite;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'polaris_readonly_user') THEN
        CREATE ROLE polaris_readonly_user LOGIN PASSWORD 'polaris_dev_only'
            IN ROLE polaris_app_readonly;
    END IF;
END
$$;

GRANT polaris_app_readonly  TO polaris_analyst;
GRANT polaris_app_readwrite TO polaris_developer;
GRANT polaris_analyst       TO polaris_developer;
GRANT pg_read_all_stats     TO polaris_analyst;
GRANT pg_monitor            TO polaris_developer;
