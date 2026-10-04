-- File: sql/06_jsonb_fulltext/jsonb_modeling_validation.sql
-- Purpose: JSONB modeling, validation (CHECK, jsonpath, IS JSON), GIN and
--          expression indexes, SQL/JSON query functions and JSON_TABLE (PG17),
--          and safe update patterns.
--
-- Standalone and idempotent. Base tables are only READ (plus IF NOT EXISTS
-- indexes). Data that this lesson writes lives in module-owned side tables:
--   civics.citizen_preferences    (1:1 with civics.citizens)
--   commerce.merchant_profiles    (1:1 with commerce.merchants)
-- The original version added JSONB columns to civics.citizens and
-- commerce.merchants and rewrote every row; that changes shared base tables
-- for every later module, so it was moved into side tables.

\echo '== 06 jsonb: modeling =='

-- =============================================================================
-- 1. MODELING: WHEN TO USE JSONB
-- =============================================================================
-- Keep attributes you filter, join, or constrain on as real columns. Use JSONB
-- for sparse, optional, or per-category attributes (the base data does this:
-- complaint_records.metadata keys depend on category, policy_documents.
-- document_content is a nested document). jsonb (binary, de-duplicated keys,
-- indexable) is almost always preferable to json (verbatim text).
--
-- Side tables keep the hot base row narrow and let the JSON evolve
-- independently. Both are populated deterministically from the base data.

CREATE TABLE IF NOT EXISTS civics.citizen_preferences (
    citizen_id  BIGINT PRIMARY KEY REFERENCES civics.citizens (citizen_id) ON DELETE CASCADE,
    preferences JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS commerce.merchant_profiles (
    merchant_id       BIGINT PRIMARY KEY REFERENCES commerce.merchants (merchant_id) ON DELETE CASCADE,
    business_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Deterministic sample preferences (varied by citizen_id so aggregates are interesting).
INSERT INTO civics.citizen_preferences (citizen_id, preferences)
SELECT c.citizen_id,
       jsonb_build_object(
           'communication', jsonb_build_object(
               'email_notifications', c.citizen_id % 4 <> 0,
               'sms_alerts',          c.citizen_id % 3 = 0,
               'preferred_language',  (ARRAY['en','en','en','es','es','fr'])[1 + c.citizen_id % 6]),
           'services', jsonb_build_object(
               'auto_pay_taxes',     c.citizen_id % 5 < 2,
               'paperless_billing',  c.citizen_id % 2 = 0),
           'accessibility', jsonb_build_object(
               'large_text',    c.citizen_id % 17 = 0,
               'high_contrast', c.citizen_id % 23 = 0),
           'interests', CASE WHEN c.citizen_id % 7 = 0 THEN '["parks","transit"]'::jsonb
                             WHEN c.citizen_id % 7 = 1 THEN '["libraries"]'::jsonb
                             ELSE '[]'::jsonb END)
FROM civics.citizens c
ON CONFLICT (citizen_id) DO NOTHING;

INSERT INTO commerce.merchant_profiles (merchant_id, business_metadata)
SELECT m.merchant_id,
       jsonb_build_object(
           'operating_hours', CASE m.business_type
               WHEN 'restaurant' THEN '{"monday":{"open":"11:00","close":"22:00"},"saturday":{"open":"10:00","close":"23:00"},"sunday":{"open":"10:00","close":"21:00"}}'::jsonb
               ELSE '{"monday":{"open":"09:00","close":"18:00"},"saturday":{"open":"10:00","close":"16:00"}}'::jsonb
           END,
           'features', (SELECT COALESCE(jsonb_agg(f ORDER BY f), '[]'::jsonb)
                        FROM unnest(ARRAY['parking','wifi','wheelchair_accessible','outdoor_seating']) WITH ORDINALITY AS t(f, i)
                        WHERE (m.merchant_id + i) % 3 <> 0),
           'payment_methods', CASE WHEN m.merchant_id % 4 = 0 THEN '["cash","credit"]'::jsonb
                                   ELSE '["cash","credit","contactless"]'::jsonb END,
           'social_media', jsonb_strip_nulls(jsonb_build_object(
               'website',  m.website,
               'facebook', CASE WHEN m.merchant_id % 2 = 0 THEN '@merchant' || m.merchant_id END)))
FROM commerce.merchants m
ON CONFLICT (merchant_id) DO NOTHING;

SELECT jsonb_pretty(preferences) AS sample_preferences
FROM civics.citizen_preferences WHERE citizen_id = 7;

\echo '== 06 jsonb: validation =='

-- =============================================================================
-- 2. VALIDATION
-- =============================================================================
-- Layered approach, cheapest first:
--   a) simple CHECKs with jsonb_typeof / ? (key exists)
--   b) jsonpath predicates (@?, @@) for value rules
--   c) an IMMUTABLE validation function for structural rules
-- (PostgreSQL has no built-in JSON Schema; pg_jsonschema is an extension.)

CREATE OR REPLACE FUNCTION civics.validate_citizen_preferences(prefs JSONB)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
BEGIN
    IF jsonb_typeof(prefs) <> 'object' THEN
        RETURN false;
    END IF;
    -- required top-level sections (?& = all keys present)
    IF NOT prefs ?& ARRAY['communication', 'services'] THEN
        RETURN false;
    END IF;
    IF jsonb_typeof(prefs #> '{communication,email_notifications}') IS DISTINCT FROM 'boolean' THEN
        RETURN false;
    END IF;
    -- optional key, but if present it must be a supported language.
    -- (NOT IN with a NULL left side is NULL, which a CHECK would accept,
    --  so test presence explicitly.)
    IF prefs -> 'communication' ? 'preferred_language'
       AND (prefs #>> '{communication,preferred_language}') NOT IN ('en', 'es', 'fr') THEN
        RETURN false;
    END IF;
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION commerce.validate_business_metadata(metadata JSONB)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    day_name TEXT;
    hours    JSONB;
BEGIN
    IF metadata ? 'operating_hours' THEN
        IF jsonb_typeof(metadata -> 'operating_hours') <> 'object' THEN
            RETURN false;
        END IF;
        FOR day_name, hours IN SELECT key, value FROM jsonb_each(metadata -> 'operating_hours') LOOP
            IF day_name NOT IN ('monday','tuesday','wednesday','thursday','friday','saturday','sunday') THEN
                RETURN false;
            END IF;
            IF NOT (hours ?& ARRAY['open', 'close']) THEN
                RETURN false;
            END IF;
            -- HH:MM, 00:00-23:59
            IF NOT (hours ->> 'open'  ~ '^([01]\d|2[0-3]):[0-5]\d$'
                AND hours ->> 'close' ~ '^([01]\d|2[0-3]):[0-5]\d$') THEN
                RETURN false;
            END IF;
        END LOOP;
    END IF;

    IF metadata ? 'features' AND jsonb_typeof(metadata -> 'features') <> 'array' THEN
        RETURN false;
    END IF;
    RETURN true;
END;
$$;

-- Attach the rules (drop-then-add keeps the file re-runnable).
ALTER TABLE civics.citizen_preferences
    DROP CONSTRAINT IF EXISTS chk_prefs_is_object,
    DROP CONSTRAINT IF EXISTS chk_prefs_valid,
    DROP CONSTRAINT IF EXISTS chk_prefs_interests_strings;
ALTER TABLE civics.citizen_preferences
    ADD CONSTRAINT chk_prefs_is_object CHECK (jsonb_typeof(preferences) = 'object'),
    ADD CONSTRAINT chk_prefs_valid     CHECK (civics.validate_citizen_preferences(preferences)),
    -- jsonpath: every element of $.interests (if any) must be a string.
    -- `@@` returns the predicate result; `!exists(...)` reads "no element that is not a string".
    ADD CONSTRAINT chk_prefs_interests_strings
        CHECK (preferences @@ '!exists($.interests[*] ? (@.type() != "string"))');

ALTER TABLE commerce.merchant_profiles DROP CONSTRAINT IF EXISTS chk_business_metadata_valid;
ALTER TABLE commerce.merchant_profiles
    ADD CONSTRAINT chk_business_metadata_valid CHECK (commerce.validate_business_metadata(business_metadata));

-- Prove the rules bite: each bad document is rejected (caught per statement).
DO $$
DECLARE
    bad JSONB;
    n   INTEGER := 0;
BEGIN
    FOREACH bad IN ARRAY ARRAY[
        '[]'::jsonb,                                                                         -- not an object
        '{"communication":{"email_notifications":true}}',                                     -- missing services
        '{"communication":{"email_notifications":"yes"},"services":{}}',                      -- wrong type
        '{"communication":{"email_notifications":true,"preferred_language":"de"},"services":{}}', -- bad language
        '{"communication":{"email_notifications":true},"services":{},"interests":[1,2]}'     -- non-string interest
    ] LOOP
        n := n + 1;
        BEGIN
            UPDATE civics.citizen_preferences SET preferences = bad WHERE citizen_id = 1;
            RAISE NOTICE 'case %: unexpectedly accepted %', n, bad;
        EXCEPTION WHEN check_violation THEN
            DECLARE c TEXT;
            BEGIN
                GET STACKED DIAGNOSTICS c = CONSTRAINT_NAME;
                RAISE NOTICE 'case %: rejected by % -> %', n, c, bad;
            END;
        END;
    END LOOP;
END;
$$;

-- Validating text BEFORE casting: the SQL/JSON IS JSON predicate (PG16+)
-- tells you whether a string is JSON, and of what kind, without raising.
SELECT input,
       input IS JSON                      AS is_json,
       input IS JSON OBJECT               AS is_object,
       input IS JSON ARRAY                AS is_array,
       input IS JSON WITH UNIQUE KEYS     AS unique_keys
FROM (VALUES ('{"a":1}'), ('{"a":1,"a":2}'), ('[1,2]'), ('{"a":'), ('42')) AS t(input);

-- Adding a JSONB rule to an existing BIG table: ADD ... NOT VALID is instant
-- (only new rows are checked), VALIDATE CONSTRAINT then scans with a weaker
-- lock. Shown on the base complaints table inside a rolled-back transaction,
-- reusing the base function documents.validate_complaint_metadata().
BEGIN;
ALTER TABLE documents.complaint_records
    ADD CONSTRAINT chk_complaint_metadata_shape
    CHECK (documents.validate_complaint_metadata(metadata)) NOT VALID;
ALTER TABLE documents.complaint_records VALIDATE CONSTRAINT chk_complaint_metadata_shape;
SELECT conname, convalidated FROM pg_constraint WHERE conname = 'chk_complaint_metadata_shape';
ROLLBACK;

\echo '== 06 jsonb: operators and jsonpath on base data =='

-- =============================================================================
-- 3. QUERY OPERATORS ON THE BASE DATA
-- =============================================================================
--   ->  / ->>   field as jsonb / as text       #> / #>>  path as jsonb / text
--   @>          containment                    ?  ?| ?&  key exists / any / all
--   @?          jsonpath returns any item      @@        jsonpath predicate is true

-- Containment: noise complaints received by phone? (keys vary per category)
SELECT metadata ->> 'category' AS category, metadata ->> 'channel' AS channel, count(*) AS complaints
FROM documents.complaint_records
WHERE metadata @> '{"category": "noise"}' OR metadata @> '{"channel": "phone"}'
GROUP BY 1, 2
ORDER BY 1, 2 NULLS FIRST
LIMIT 10;

-- Key existence: which categories carry which optional keys?
SELECT category,
       count(*) FILTER (WHERE metadata ? 'decibel_level')                     AS has_decibels,
       count(*) FILTER (WHERE metadata ?| ARRAY['hazard_type','road_condition']) AS has_road_info,
       count(*) FILTER (WHERE metadata ? 'channel')                           AS has_channel
FROM documents.complaint_records
GROUP BY category
ORDER BY category;

-- jsonpath filter with a typed comparison: loud night-time noise complaints.
SELECT complaint_id, metadata ->> 'time_of_day' AS time_of_day, (metadata -> 'decibel_level')::int AS db
FROM documents.complaint_records
WHERE metadata @? '$ ? (@.category == "noise" && @.decibel_level >= 84 && @.time_of_day < "06:00")'
ORDER BY db DESC, complaint_id
LIMIT 5;

-- jsonb_path_query with variables (parameterise a path like a prepared statement).
SELECT complaint_id, jsonb_path_query_first(metadata, '$.decibel_level ? (@ > $min)', '{"min": 84}') AS loud_db
FROM documents.complaint_records
WHERE jsonb_path_exists(metadata, '$.decibel_level ? (@ > $min)', '{"min": 84}')
ORDER BY complaint_id
LIMIT 3;

-- Sensor firmware/battery from mobility.sensor_readings.raw_data.
SELECT raw_data ->> 'firmware'                          AS firmware,
       count(*)                                         AS readings,
       round(avg((raw_data ->> 'battery_pct')::numeric), 1) AS avg_battery_pct
FROM mobility.sensor_readings
GROUP BY 1
ORDER BY 1;

\echo '== 06 jsonb: SQL/JSON functions and JSON_TABLE (PostgreSQL 17) =='

-- =============================================================================
-- 4. SQL/JSON STANDARD FUNCTIONS (PG16/17)
-- =============================================================================
-- PG16: JSON_OBJECT, JSON_ARRAY, JSON_OBJECTAGG, JSON_ARRAYAGG, IS JSON.
-- PG17: JSON_EXISTS, JSON_VALUE (typed scalar), JSON_QUERY, JSON_TABLE.

SELECT policy_id,
       JSON_VALUE(document_content, '$.title')                          AS title,
       JSON_VALUE(metadata, '$.pages' RETURNING int)                    AS pages,
       JSON_EXISTS(document_content, '$.sections[*] ? (@.heading == "Enforcement")') AS has_enforcement,
       JSON_QUERY(document_content, '$.sections[0]')                    AS first_section,
       JSON_VALUE(metadata, '$.missing' DEFAULT 'n/a' ON EMPTY)         AS with_default
FROM documents.policy_documents
ORDER BY policy_id
LIMIT 3;

-- Build JSON with the standard constructors.
SELECT department,
       JSON_OBJECT('department' VALUE department,
                   'published'  VALUE count(*) FILTER (WHERE status = 'published')) AS summary,
       JSON_ARRAYAGG(policy_number || ' v' || version ORDER BY policy_number, version)
           FILTER (WHERE status IN ('approved', 'under_review'))                     AS in_pipeline
FROM documents.policy_documents
WHERE department IN ('Finance', 'Health')
GROUP BY department
ORDER BY department;

-- JSON_TABLE (PG17): turn nested JSON into a relational row set in FROM.
-- Each policy's sections array becomes one row per section, with ordinality.
SELECT p.policy_number, s.section_no, s.heading, left(s.body, 60) AS body_start
FROM documents.policy_documents p,
     JSON_TABLE(p.document_content, '$.sections[*]'
         COLUMNS (
             section_no FOR ORDINALITY,
             heading    TEXT PATH '$.heading',
             body       TEXT PATH '$.body'
         )) AS s
WHERE p.policy_id = (SELECT min(policy_id) FROM documents.policy_documents)
ORDER BY s.section_no;

-- JSON_TABLE with NESTED PATH and typed columns: the policy row plus its
-- change log entries and section headings, in one pass.
SELECT p.policy_number, jt.*
FROM documents.policy_documents p,
     JSON_TABLE(p.document_content || jsonb_build_object('change_log', p.change_log), '$'
         COLUMNS (
             title TEXT PATH '$.title',
             NESTED PATH '$.change_log[*]' COLUMNS (
                 change_version TEXT PATH '$.version',
                 change_date    DATE PATH '$.date',
                 change_note    TEXT PATH '$.note'),
             NESTED PATH '$.sections[*]' COLUMNS (
                 heading TEXT PATH '$.heading')
         )) AS jt
WHERE p.policy_id = (SELECT min(policy_id) FROM documents.policy_documents)
ORDER BY jt.change_version NULLS LAST, jt.heading;

-- JSON_TABLE for analytics: resolution actions per complaint category.
SELECT c.category, ra.action, count(*) AS times, round(avg(ra.crew_size), 2) AS avg_crew
FROM documents.complaint_records c,
     JSON_TABLE(c.resolution_actions, '$[*]'
         COLUMNS (action TEXT PATH '$.action',
                  crew_size INT PATH '$.crew_size' DEFAULT 0 ON EMPTY)) AS ra
GROUP BY c.category, ra.action
ORDER BY times DESC, c.category
LIMIT 8;

\echo '== 06 jsonb: indexing =='

-- =============================================================================
-- 5. GIN AND EXPRESSION INDEXES
-- =============================================================================
-- jsonb_ops (default GIN): indexes keys AND values; supports @>, ?, ?|, ?&, @?, @@.
-- jsonb_path_ops: indexes hashed paths to values only; smaller and faster
--   for @>/@?/@@, but cannot answer key-existence (?) queries.
-- B-tree on an expression: best for equality/range on ONE known key.

CREATE INDEX IF NOT EXISTS idx_citizen_prefs_gin
    ON civics.citizen_preferences USING gin (preferences);
CREATE INDEX IF NOT EXISTS idx_merchant_profiles_pathops
    ON commerce.merchant_profiles USING gin (business_metadata jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_citizen_prefs_language
    ON civics.citizen_preferences ((preferences #>> '{communication,preferred_language}'));
-- Base table: metadata already has a jsonb_ops GIN (idx_complaints_metadata);
-- add a btree on the numeric decibel value for range queries.
CREATE INDEX IF NOT EXISTS idx_complaints_decibel
    ON documents.complaint_records (((metadata ->> 'decibel_level')::int))
    WHERE metadata ? 'decibel_level';

ANALYZE civics.citizen_preferences;
ANALYZE commerce.merchant_profiles;
ANALYZE documents.complaint_records;

-- The tables are small, so the planner may prefer a seq scan; disable it
-- locally just to SHOW which index can serve each operator.
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT count(*) FROM civics.citizen_preferences
WHERE preferences @> '{"communication": {"sms_alerts": true}}';

EXPLAIN (COSTS OFF)
SELECT count(*) FROM commerce.merchant_profiles
WHERE business_metadata @? '$.features[*] ? (@ == "wifi")';

EXPLAIN (COSTS OFF)
SELECT count(*) FROM civics.citizen_preferences
WHERE preferences #>> '{communication,preferred_language}' = 'fr';

EXPLAIN (COSTS OFF)
SELECT count(*) FROM documents.complaint_records
WHERE metadata ? 'decibel_level' AND (metadata ->> 'decibel_level')::int >= 84;
ROLLBACK;

-- Index sizes: jsonb_path_ops is typically the smallest GIN option.
SELECT indexrelid::regclass AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_index
WHERE indexrelid IN ('civics.idx_citizen_prefs_gin'::regclass,
                     'commerce.idx_merchant_profiles_pathops'::regclass,
                     'civics.idx_citizen_prefs_language'::regclass)
ORDER BY 1::text;

\echo '== 06 jsonb: updates =='

-- =============================================================================
-- 6. UPDATE PATTERNS
-- =============================================================================
-- Every JSONB update rewrites the whole value (and the row version), so very
-- large, frequently-patched documents are a design smell.

-- Deep merge: recursively merge objects, replace everything else.
CREATE OR REPLACE FUNCTION analytics.jsonb_merge_deep(original JSONB, updates JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE
    result JSONB := COALESCE(original, '{}'::jsonb);
    k TEXT;
    v JSONB;
BEGIN
    IF jsonb_typeof(updates) IS DISTINCT FROM 'object' THEN
        RETURN updates;
    END IF;
    FOR k, v IN SELECT key, value FROM jsonb_each(updates) LOOP
        IF jsonb_typeof(result -> k) = 'object' AND jsonb_typeof(v) = 'object' THEN
            result := jsonb_set(result, ARRAY[k], analytics.jsonb_merge_deep(result -> k, v));
        ELSE
            result := jsonb_set(result, ARRAY[k], v, true);
        END IF;
    END LOOP;
    RETURN result;
END;
$$;

-- Compare the built-in operators with the deep merge (pure expressions, no writes).
WITH doc AS (SELECT '{"communication":{"email_notifications":true,"preferred_language":"en"},"services":{"auto_pay_taxes":false},"tmp":1}'::jsonb AS j)
SELECT 'jsonb_set'      AS op, jsonb_set(j, '{communication,preferred_language}', '"es"')                     AS result FROM doc
UNION ALL SELECT 'jsonb_insert (array)', jsonb_insert('{"interests":["parks"]}', '{interests,0}', '"transit"')
UNION ALL SELECT '|| (shallow!)',  j || '{"communication":{"sms_alerts":true}}'                           FROM doc
UNION ALL SELECT 'merge_deep',     analytics.jsonb_merge_deep(j, '{"communication":{"sms_alerts":true}}') FROM doc
UNION ALL SELECT '- key',          j - 'tmp'                                                               FROM doc
UNION ALL SELECT '#- path',        j #- '{services,auto_pay_taxes}'                                        FROM doc
UNION ALL SELECT 'jsonb_set_lax delete', jsonb_set_lax(j, '{tmp}', NULL, true, 'delete_key')               FROM doc;

-- Apply an update on the module-owned table; constraints still validate it.
BEGIN;
UPDATE civics.citizen_preferences
SET preferences = analytics.jsonb_merge_deep(preferences, '{"communication":{"preferred_language":"es","sms_alerts":true}}'),
    updated_at  = now()
WHERE citizen_id BETWEEN 1 AND 5
RETURNING citizen_id, preferences -> 'communication' AS communication;
ROLLBACK;

\echo '== 06 jsonb: aggregation and data-quality checks =='

-- =============================================================================
-- 7. AGGREGATION AND DATA QUALITY
-- =============================================================================

-- Value distribution for chosen paths, as one JSON object per path.
CREATE OR REPLACE FUNCTION analytics.analyze_citizen_preferences()
RETURNS TABLE(preference_path TEXT, value_distribution JSONB)
LANGUAGE sql
STABLE
AS $$
    WITH paths(path) AS (
        VALUES ('{communication,email_notifications}'::text[]),
               ('{communication,preferred_language}'),
               ('{services,auto_pay_taxes}')
    ), vals AS (
        SELECT array_to_string(p.path, '.') AS path, cp.preferences #>> p.path AS value, count(*) AS n
        FROM paths p
        CROSS JOIN civics.citizen_preferences cp
        WHERE cp.preferences #>> p.path IS NOT NULL
        GROUP BY 1, 2
    )
    SELECT path, jsonb_object_agg(value, n ORDER BY value)
    FROM vals
    GROUP BY path
    ORDER BY path;
$$;

SELECT * FROM analytics.analyze_citizen_preferences();

-- Most common merchant features (unnest a JSON array).
SELECT f.feature, count(*) AS merchants
FROM commerce.merchant_profiles mp
CROSS JOIN LATERAL jsonb_array_elements_text(mp.business_metadata -> 'features') AS f(feature)
GROUP BY f.feature
ORDER BY merchants DESC, f.feature;

-- Normalise empty objects to SQL NULL? Only where the column allows it; here
-- the side tables use NOT NULL DEFAULT '{}' so "absent" is just "no row".
CREATE OR REPLACE FUNCTION analytics.validate_all_jsonb_data()
RETURNS TABLE(table_name TEXT, column_name TEXT, checked BIGINT, invalid_count BIGINT, sample_invalid_ids BIGINT[])
LANGUAGE sql
STABLE
AS $$
    SELECT 'civics.citizen_preferences', 'preferences',
           count(*),
           count(*) FILTER (WHERE NOT civics.validate_citizen_preferences(preferences)),
           (array_agg(citizen_id ORDER BY citizen_id)
                FILTER (WHERE NOT civics.validate_citizen_preferences(preferences)))[1:5]
    FROM civics.citizen_preferences
    UNION ALL
    SELECT 'commerce.merchant_profiles', 'business_metadata',
           count(*),
           count(*) FILTER (WHERE NOT commerce.validate_business_metadata(business_metadata)),
           (array_agg(merchant_id ORDER BY merchant_id)
                FILTER (WHERE NOT commerce.validate_business_metadata(business_metadata)))[1:5]
    FROM commerce.merchant_profiles
    UNION ALL
    SELECT 'documents.complaint_records', 'metadata',
           count(*),
           count(*) FILTER (WHERE NOT documents.validate_complaint_metadata(metadata)),
           (array_agg(complaint_id ORDER BY complaint_id)
                FILTER (WHERE NOT documents.validate_complaint_metadata(metadata)))[1:5]
    FROM documents.complaint_records;
$$;

COMMENT ON FUNCTION analytics.validate_all_jsonb_data() IS
'Run every JSONB validator over its table; returns checked/invalid counts and up to 5 sample ids.';

SELECT * FROM analytics.validate_all_jsonb_data();
