-- File: sql/06_jsonb_fulltext/fulltext_search_ranking.sql
-- Purpose: Full-text search: parsing and query syntaxes, custom configurations,
--          weighting and ranking (ts_rank vs ts_rank_cd), highlighting with
--          ts_headline, searching JSONB, and typo tolerance with pg_trgm.
--
-- Standalone and idempotent. Uses the base columns
--   documents.complaint_records.search_vector
--   documents.policy_documents.search_vector
-- which base triggers maintain with to_tsvector('english', ...). A query must
-- use the SAME configuration as the stored vector ('english' here), or stems
-- will not match. Base tables are only read; this file adds IF NOT EXISTS
-- indexes plus module-owned objects (a materialized view, a lexicon table,
-- a text search configuration, functions).

\echo '== 06 fulltext: tsvector / tsquery basics =='

-- =============================================================================
-- 1. HOW TEXT BECOMES LEXEMES
-- =============================================================================
-- to_tsvector: parse -> normalise via dictionaries (stop words removed,
-- words stemmed) -> sorted lexemes with positions. 'simple' only lowercases.
SELECT to_tsvector('english', 'Streetlights are OUT near the schools; walking is unsafe') AS english,
       to_tsvector('simple',  'Streetlights are OUT near the schools; walking is unsafe') AS simple;

-- Four ways to build a tsquery from user input:
--   to_tsquery           strict operator syntax (& | ! <->), errors on bad input
--   plainto_tsquery      all words ANDed, punctuation ignored
--   phraseto_tsquery     words must be adjacent, in order (<->)
--   websearch_to_tsquery Google-like: "quoted phrase", OR, -exclude; never errors
SELECT 'to_tsquery'           AS parser, to_tsquery('english', 'power & (outage | failure)')       AS tsquery
UNION ALL SELECT 'plainto_tsquery',      plainto_tsquery('english', 'power outages, Spring Valley')
UNION ALL SELECT 'phraseto_tsquery',     phraseto_tsquery('english', 'power outage')
UNION ALL SELECT 'websearch_to_tsquery', websearch_to_tsquery('english', '"power outage" or streetlight -valley')
UNION ALL SELECT 'websearch (garbage)',  websearch_to_tsquery('english', 'pothole & ) ( !!');

-- Most frequent lexemes in the stored complaint vectors (ts_stat).
SELECT word, ndoc, nentry
FROM ts_stat('SELECT search_vector FROM documents.complaint_records')
ORDER BY ndoc DESC, word
LIMIT 10;

\echo '== 06 fulltext: custom configuration (unaccent) =='

-- =============================================================================
-- 2. CUSTOM TEXT SEARCH CONFIGURATION
-- =============================================================================
-- documents.city_english = english + unaccent, so "Café"/"cafe" and
-- "Résumé"/"resume" match. There is no CREATE TEXT SEARCH CONFIGURATION
-- IF NOT EXISTS, so guard with a catalog check.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_ts_config c JOIN pg_namespace n ON n.oid = c.cfgnamespace
                   WHERE n.nspname = 'documents' AND c.cfgname = 'city_english') THEN
        CREATE TEXT SEARCH CONFIGURATION documents.city_english (COPY = pg_catalog.english);
        ALTER TEXT SEARCH CONFIGURATION documents.city_english
            ALTER MAPPING FOR hword, hword_part, word
            WITH public.unaccent, pg_catalog.english_stem;
    END IF;
END;
$$;

SELECT to_tsvector('english', 'Café on Résumé Street')                     AS english,
       to_tsvector('documents.city_english', 'Café on Résumé Street')      AS city_english,
       to_tsvector('documents.city_english', 'Café on Résumé Street')
           @@ to_tsquery('documents.city_english', 'cafe & resume')        AS unaccented_match;

\echo '== 06 fulltext: searching the stored search_vector =='

-- =============================================================================
-- 3. SEARCH + RANK + HIGHLIGHT ON THE BASE COLUMNS
-- =============================================================================
-- ts_rank     : frequency of matching lexemes.
-- ts_rank_cd  : "cover density" - also rewards matches that are CLOSE to each
--               other, so it is better for multi-word queries. Needs positions
--               (the stored vectors have them).
-- Normalization flag 32 maps rank to 0..1 (rank/(rank+1)); 1 divides by
-- 1 + log(document length) so long documents do not win just by being long.
WITH q AS (SELECT websearch_to_tsquery('english', 'power outage crew') AS query)
SELECT c.complaint_id,
       c.subject,
       round(ts_rank(c.search_vector, q.query)::numeric, 4)        AS ts_rank,
       round(ts_rank_cd(c.search_vector, q.query)::numeric, 4)     AS ts_rank_cd,
       round(ts_rank_cd(c.search_vector, q.query, 1|32)::numeric, 4) AS rank_cd_norm
FROM documents.complaint_records c, q
WHERE c.search_vector @@ q.query
ORDER BY ts_rank_cd DESC, c.complaint_id
LIMIT 5;

-- websearch syntax: phrase + exclusion + OR, against the GIN index idx_complaints_search.
SELECT c.category, count(*) AS matches
FROM documents.complaint_records c
WHERE c.search_vector @@ websearch_to_tsquery('english', '"water main" or "low water pressure" -valley')
GROUP BY c.category
ORDER BY matches DESC, c.category;

-- ts_headline re-parses the ORIGINAL text, so it is expensive: rank and LIMIT
-- first in a subquery, then highlight only the rows you will display.
SELECT top.complaint_id,
       round(top.rank::numeric, 4) AS rank,
       ts_headline('english', top.description, top.query,
                   'StartSel=[, StopSel=], MaxWords=18, MinWords=6, MaxFragments=2, FragmentDelimiter=" ... "') AS snippet
FROM (
    SELECT c.complaint_id, c.description, q.query, ts_rank_cd(c.search_vector, q.query) AS rank
    FROM documents.complaint_records c,
         websearch_to_tsquery('english', 'pedestrian safety hazard pothole') AS q(query)
    WHERE c.search_vector @@ q.query
    ORDER BY rank DESC, c.complaint_id
    LIMIT 5
) AS top
ORDER BY top.rank DESC, top.complaint_id;

-- The index at work (small table, so force the choice just to show the plan).
BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN (COSTS OFF)
SELECT complaint_id FROM documents.complaint_records
WHERE search_vector @@ websearch_to_tsquery('english', 'graffiti');
ROLLBACK;

\echo '== 06 fulltext: weighted vectors (materialized view) =='

-- =============================================================================
-- 4. FIELD WEIGHTS: subject (A) > description (B) > category (C) > notes (D)
-- =============================================================================
-- The base search_vector is unweighted. Rather than altering the shared base
-- table, keep a weighted copy in a module-owned materialized view with its own
-- GIN index. (In your own schema a STORED generated column is the usual
-- choice: search_tsv tsvector GENERATED ALWAYS AS (setweight(...) || ...) STORED.)
CREATE MATERIALIZED VIEW IF NOT EXISTS documents.complaint_search_mv AS
SELECT c.complaint_id,
       c.complaint_number,
       c.category,
       c.priority_level,
       c.status,
       c.submitted_at,
       setweight(to_tsvector('documents.city_english', COALESCE(c.subject, '')), 'A') ||
       setweight(to_tsvector('documents.city_english', COALESCE(c.description, '')), 'B') ||
       setweight(to_tsvector('documents.city_english', COALESCE(c.category, '')), 'C') ||
       setweight(to_tsvector('documents.city_english', COALESCE(c.resolution_notes, '')), 'D') AS weighted_tsv
FROM documents.complaint_records c
WITH DATA;

CREATE UNIQUE INDEX IF NOT EXISTS uq_complaint_search_mv_id ON documents.complaint_search_mv (complaint_id);
CREATE INDEX IF NOT EXISTS idx_complaint_search_mv_tsv ON documents.complaint_search_mv USING gin (weighted_tsv);

-- CONCURRENTLY keeps the MV readable during refresh (needs the unique index).
REFRESH MATERIALIZED VIEW CONCURRENTLY documents.complaint_search_mv;

-- Same query, unweighted vs weighted ranking: a hit in the SUBJECT now counts
-- more than the same word in the boilerplate description ("crew" appears in
-- both subject-less descriptions and resolution notes).
-- The weights array is {D, C, B, A}; the default is {0.1, 0.2, 0.4, 1.0}.
WITH q AS (SELECT websearch_to_tsquery('documents.city_english', 'streetlight crew') AS query)
SELECT m.complaint_id,
       c.subject,
       round(ts_rank_cd(c.search_vector, websearch_to_tsquery('english', 'streetlight crew'))::numeric, 4) AS unweighted,
       round(ts_rank_cd(m.weighted_tsv, q.query)::numeric, 4)                                          AS weighted,
       round(ts_rank_cd('{0.05, 0.1, 0.3, 1.0}', m.weighted_tsv, q.query)::numeric, 4)                AS custom_weights
FROM documents.complaint_search_mv m
JOIN documents.complaint_records c USING (complaint_id), q
WHERE m.weighted_tsv @@ q.query
ORDER BY weighted DESC, m.complaint_id
LIMIT 5;

-- Restrict matching to a field: the :A label means "only in the subject".
SELECT count(*) FILTER (WHERE weighted_tsv @@ to_tsquery('documents.city_english', 'crew'))   AS crew_anywhere,
       count(*) FILTER (WHERE weighted_tsv @@ to_tsquery('documents.city_english', 'crew:A')) AS crew_in_subject,
       count(*) FILTER (WHERE weighted_tsv @@ to_tsquery('documents.city_english', 'leak:AB')) AS leak_subject_or_body
FROM documents.complaint_search_mv;

\echo '== 06 fulltext: search functions =='

-- =============================================================================
-- 5. SEARCH FUNCTIONS
-- =============================================================================

-- Earlier versions of this file defined some of these with different
-- signatures or result columns; drop them so CREATE OR REPLACE cannot fail
-- or leave ambiguous overloads behind.
DROP FUNCTION IF EXISTS documents.search_policies_advanced(TEXT, TEXT, documents.document_status);
DROP FUNCTION IF EXISTS documents.search_complaint_metadata(TEXT, TEXT);
DROP FUNCTION IF EXISTS analytics.search_city_content(TEXT, TEXT[]);
DROP FUNCTION IF EXISTS analytics.get_popular_search_terms(INTEGER, INTEGER);
DROP FUNCTION IF EXISTS analytics.generate_search_suggestions(TEXT, INTEGER);

-- Complaint search over the base search_vector with websearch syntax,
-- cover-density ranking and highlighting of the top-N only.
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
)
LANGUAGE sql
STABLE
AS $$
    WITH q AS (SELECT websearch_to_tsquery('english', search_query) AS query),
    hits AS (
        SELECT cr.*, ts_rank_cd(cr.search_vector, q.query, 32) AS rank, q.query
        FROM documents.complaint_records cr, q
        WHERE cr.search_vector @@ q.query
          AND (category_filter IS NULL OR cr.category = category_filter)
          AND (priority_filter IS NULL OR cr.priority_level = priority_filter)
        ORDER BY rank DESC, cr.submitted_at DESC, cr.complaint_id
        LIMIT limit_count
    )
    SELECT h.complaint_id, h.complaint_number, h.subject, h.category, h.priority_level, h.status,
           h.rank,
           CASE WHEN highlight_fragments
                THEN ts_headline('english', h.subject, h.query, 'HighlightAll=true')
                ELSE h.subject END,
           CASE WHEN highlight_fragments
                THEN ts_headline('english', h.description, h.query, 'MaxWords=35, MinWords=10')
                ELSE left(h.description, 200) END,
           h.submitted_at
    FROM hits h
    ORDER BY h.rank DESC, h.submitted_at DESC, h.complaint_id;
$$;

COMMENT ON FUNCTION documents.search_complaints_advanced(TEXT, TEXT, documents.priority_level, INTEGER, BOOLEAN) IS
'Websearch-syntax complaint search over search_vector, ranked by ts_rank_cd, highlighted with ts_headline.';

SELECT complaint_number, category, priority_level, round(rank_score::numeric, 3) AS rank, highlighted_subject
FROM documents.search_complaints_advanced('"water main" leak', priority_filter => 'urgent', limit_count => 5);

-- Policy search. The base policy search_vector is built from
-- document_content::text, so JSON KEYS ("heading", "body", "sections") are
-- indexed as words too - a common mistake. jsonb_to_tsvector(..., '["string"]')
-- indexes only string VALUES; we use it for the highlight text.
SELECT count(*) FILTER (WHERE search_vector @@ to_tsquery('english', 'body | heading | sections'))
           AS docs_matching_json_keys_raw,
       count(*) FILTER (WHERE jsonb_to_tsvector('english', document_content, '["string"]')
                              @@ to_tsquery('english', 'body | heading | sections'))
           AS docs_matching_json_keys_values_only
FROM documents.policy_documents;

CREATE OR REPLACE FUNCTION documents.search_policies_advanced(
    search_query TEXT,
    department_filter TEXT DEFAULT NULL,
    status_filter documents.document_status DEFAULT 'published',
    limit_count INTEGER DEFAULT 20
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
)
LANGUAGE sql
STABLE
AS $$
    WITH q AS (SELECT websearch_to_tsquery('english', search_query) AS query),
    hits AS (
        SELECT pd.*, ts_rank_cd(pd.search_vector, q.query, 1|32) AS rank, q.query
        FROM documents.policy_documents pd, q
        WHERE pd.search_vector @@ q.query
          AND (department_filter IS NULL OR pd.department = department_filter)
          AND (status_filter IS NULL OR pd.status = status_filter)
        ORDER BY rank DESC, pd.policy_id
        LIMIT limit_count
    )
    SELECT h.policy_id, h.policy_number, h.title, h.department, h.rank,
           -- Highlight the readable section text, not the JSON with its braces/keys.
           ts_headline('english',
                       (SELECT string_agg(s.value ->> 'heading' || ': ' || (s.value ->> 'body'), ' ' ORDER BY s.ordinality)
                        FROM jsonb_array_elements(h.document_content -> 'sections') WITH ORDINALITY AS s),
                       h.query, 'MaxWords=25, MinWords=8'),
           h.effective_date, h.tags
    FROM hits h
    ORDER BY h.rank DESC, h.policy_id;
$$;

SELECT policy_number, title, department, round(rank_score::numeric, 3) AS rank, content_snippet
FROM documents.search_policies_advanced('food safety fines', limit_count => 3);

-- Search inside JSONB complaint metadata: jsonb_to_tsvector indexes only the
-- chosen value types, never keys. Here: string values (category, channel,
-- hazard_type, utility_type...).
CREATE OR REPLACE FUNCTION documents.search_complaint_metadata(
    search_terms TEXT,
    limit_count INTEGER DEFAULT 25
)
RETURNS TABLE(
    complaint_id BIGINT,
    complaint_number VARCHAR(50),
    category VARCHAR(100),
    metadata JSONB,
    rank_score REAL
)
LANGUAGE sql
STABLE
AS $$
    SELECT cr.complaint_id, cr.complaint_number, cr.category, cr.metadata,
           ts_rank(jsonb_to_tsvector('english', cr.metadata, '["string"]'), q.query)
    FROM documents.complaint_records cr,
         websearch_to_tsquery('english', search_terms) AS q(query)
    WHERE jsonb_to_tsvector('english', cr.metadata, '["string"]') @@ q.query
    ORDER BY 5 DESC, cr.complaint_id
    LIMIT limit_count;
$$;

-- Make the metadata search indexable with an expression GIN index; the
-- query must repeat the exact expression to use it.
CREATE INDEX IF NOT EXISTS idx_complaints_metadata_fts
    ON documents.complaint_records
    USING gin (jsonb_to_tsvector('english', metadata, '["string"]'));

SELECT complaint_number, category, metadata
FROM documents.search_complaint_metadata('power', 3);

-- Unified search across content types with per-type weights.
CREATE OR REPLACE FUNCTION analytics.search_city_content(
    search_query TEXT,
    content_types TEXT[] DEFAULT ARRAY['complaints', 'policies'],
    limit_count INTEGER DEFAULT 20
)
RETURNS TABLE(
    content_type TEXT,
    content_id BIGINT,
    title TEXT,
    weighted_rank REAL,
    last_updated TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    WITH q AS (SELECT websearch_to_tsquery('english', search_query) AS query)
    SELECT * FROM (
        SELECT 'complaint'::TEXT, cr.complaint_id, cr.subject::TEXT,
               (ts_rank_cd(cr.search_vector, q.query, 32) * 0.8)::REAL, cr.updated_at
        FROM documents.complaint_records cr, q
        WHERE 'complaints' = ANY (content_types) AND cr.search_vector @@ q.query
        UNION ALL
        SELECT 'policy'::TEXT, pd.policy_id, pd.title::TEXT,
               (ts_rank_cd(pd.search_vector, q.query, 32) * 1.0)::REAL, pd.updated_at
        FROM documents.policy_documents pd, q
        WHERE 'policies' = ANY (content_types) AND pd.search_vector @@ q.query
          AND pd.status = 'published'
    ) AS r(content_type, content_id, title, weighted_rank, last_updated)
    ORDER BY weighted_rank DESC, content_type, content_id
    LIMIT limit_count;
$$;

SELECT content_type, content_id, title, round(weighted_rank::numeric, 3) AS rank
FROM analytics.search_city_content('transit accessibility', limit_count => 5);

\echo '== 06 fulltext: typo tolerance with pg_trgm =='

-- =============================================================================
-- 6. TYPO TOLERANCE: pg_trgm
-- =============================================================================
-- Full-text search matches whole (stemmed) words, so "grafitti" or "outtage"
-- find nothing. Trigram similarity compares overlapping 3-character chunks:
--   similarity(a, b)        0..1 over whole strings        (operator %)
--   word_similarity(a, b)   best match of a inside b       (operator <%)
--   a <-> b                 distance = 1 - similarity, usable for KNN ORDER BY
-- Thresholds: pg_trgm.similarity_threshold (0.3), word_similarity_threshold (0.6).

SELECT q AS typed, w AS candidate,
       round(similarity(q, w)::numeric, 3)      AS similarity,
       round(word_similarity(q, w)::numeric, 3) AS word_similarity
FROM (VALUES ('grafitti', 'graffiti'), ('outtage', 'outage'), ('pothol', 'pothole'),
             ('streetlite', 'streetlight'), ('pothole', 'pavement')) AS t(q, w)
ORDER BY typed;

-- A lexicon of the distinct words actually used in complaints (module-owned),
-- with a trigram GIN index. Correct each query word to its nearest lexicon
-- word, then run the normal full-text query: "did you mean ...?".
CREATE TABLE IF NOT EXISTS documents.fts_lexicon (
    word TEXT PRIMARY KEY,
    ndoc INTEGER NOT NULL
);

INSERT INTO documents.fts_lexicon (word, ndoc)
SELECT w, count(DISTINCT complaint_id)
FROM documents.complaint_records,
     regexp_split_to_table(lower(subject || ' ' || description), '[^a-z]+') AS w
WHERE length(w) >= 3
GROUP BY w
ON CONFLICT (word) DO UPDATE SET ndoc = EXCLUDED.ndoc;

CREATE INDEX IF NOT EXISTS idx_fts_lexicon_trgm ON documents.fts_lexicon USING gist (word gist_trgm_ops);
ANALYZE documents.fts_lexicon;

-- Correct one word: KNN over the GiST trigram index (ORDER BY word <-> input).
CREATE OR REPLACE FUNCTION documents.correct_word(p_word TEXT, p_min_similarity REAL DEFAULT 0.3)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(
        (SELECT l.word FROM documents.fts_lexicon l
         WHERE l.word = lower(p_word)),                                   -- known word: keep it
        (SELECT l.word FROM documents.fts_lexicon l
         WHERE similarity(l.word, lower(p_word)) >= p_min_similarity
         ORDER BY l.word <-> lower(p_word), l.ndoc DESC, l.word
         LIMIT 1),
        lower(p_word));                                                    -- nothing close: unchanged
$$;

-- Fuzzy search: try the query as typed; if nothing matches, retry with each
-- word corrected via the lexicon. Reports which query was actually used.
CREATE OR REPLACE FUNCTION documents.search_complaints_fuzzy(
    search_query TEXT,
    limit_count INTEGER DEFAULT 10
)
RETURNS TABLE(
    complaint_id BIGINT,
    subject VARCHAR(500),
    rank_score REAL,
    query_used TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_query TEXT := search_query;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM documents.complaint_records cr
                   WHERE cr.search_vector @@ websearch_to_tsquery('english', v_query)) THEN
        SELECT string_agg(documents.correct_word(w), ' ' ORDER BY ord)
        INTO v_query
        FROM regexp_split_to_table(search_query, '\s+') WITH ORDINALITY AS t(w, ord)
        WHERE w <> '';
    END IF;

    RETURN QUERY
    SELECT cr.complaint_id, cr.subject,
           ts_rank_cd(cr.search_vector, websearch_to_tsquery('english', v_query), 32),
           v_query
    FROM documents.complaint_records cr
    WHERE cr.search_vector @@ websearch_to_tsquery('english', v_query)
    ORDER BY 3 DESC, cr.complaint_id
    LIMIT limit_count;
END;
$$;

-- "grafitti" and "outtage" return nothing in plain FTS...
SELECT 'plain FTS' AS method, count(*) AS hits
FROM documents.complaint_records
WHERE search_vector @@ websearch_to_tsquery('english', 'grafitti outtage');

-- ...but the fuzzy search corrects them and finds results.
SELECT query_used, count(*) AS hits
FROM documents.search_complaints_fuzzy('grafitti', 1000)
GROUP BY query_used;

SELECT complaint_id, subject, round(rank_score::numeric, 3) AS rank, query_used
FROM documents.search_complaints_fuzzy('powr outtage', 3);

-- Direct trigram matching on short text (subjects, names, addresses) is the
-- other common use: a GIN trigram index serves %, LIKE/ILIKE '%...%' and regex.
CREATE INDEX IF NOT EXISTS idx_complaints_subject_trgm
    ON documents.complaint_records USING gin (subject gin_trgm_ops);

SELECT DISTINCT ON (subject) subject, round(word_similarity('vandalised shelter', subject)::numeric, 3) AS score
FROM documents.complaint_records
WHERE 'vandalised shelter' <% subject
ORDER BY subject, score DESC
LIMIT 5;

\echo '== 06 fulltext: autocomplete and search analytics =='

-- =============================================================================
-- 7. AUTOCOMPLETE AND SEARCH ANALYTICS
-- =============================================================================

-- Suggestions: prefix matches first, then trigram-similar terms.
CREATE OR REPLACE FUNCTION analytics.generate_search_suggestions(
    partial_query TEXT,
    suggestion_limit INTEGER DEFAULT 10
)
RETURNS TABLE(suggestion TEXT, suggestion_type TEXT, score REAL)
LANGUAGE sql
STABLE
AS $$
    SELECT suggestion, suggestion_type, max(score) AS score
    FROM (
        SELECT l.word, 'word', 1.0 + l.ndoc / 100000.0
        FROM documents.fts_lexicon l
        WHERE length(partial_query) >= 2 AND l.word LIKE lower(partial_query) || '%'
        UNION ALL
        SELECT l.word, 'did_you_mean', similarity(l.word, lower(partial_query))
        FROM documents.fts_lexicon l
        WHERE length(partial_query) >= 3 AND l.word % lower(partial_query)
        UNION ALL
        SELECT DISTINCT pd.title::TEXT, 'policy_title', word_similarity(partial_query, pd.title)
        FROM documents.policy_documents pd
        WHERE length(partial_query) >= 3 AND pd.status = 'published'
          AND partial_query <% pd.title
    ) AS s(suggestion, suggestion_type, score)
    GROUP BY suggestion, suggestion_type
    ORDER BY score DESC, suggestion
    LIMIT suggestion_limit;
$$;

SELECT * FROM analytics.generate_search_suggestions('stre', 5);
SELECT * FROM analytics.generate_search_suggestions('grafiti', 5);

-- Query log (module-owned). Timestamps are real wall-clock events, so now()
-- is the right clock for this table.
CREATE TABLE IF NOT EXISTS analytics.search_analytics (
    search_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    search_query      TEXT NOT NULL,
    search_type       TEXT,
    results_count     INTEGER,
    execution_time_ms NUMERIC(10,3),
    user_id           TEXT,
    search_timestamp  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION analytics.log_search_query(
    query_text TEXT,
    search_type TEXT,
    result_count INTEGER,
    exec_time NUMERIC DEFAULT NULL
)
RETURNS VOID
LANGUAGE sql
AS $$
    INSERT INTO analytics.search_analytics (search_query, search_type, results_count, execution_time_ms, user_id)
    VALUES (query_text, search_type, result_count, exec_time,
            NULLIF(current_setting('app.current_user_id', true), ''));
$$;

CREATE OR REPLACE FUNCTION analytics.get_popular_search_terms(
    days_back INTEGER DEFAULT 30,
    min_frequency INTEGER DEFAULT 2
)
RETURNS TABLE(search_term TEXT, frequency BIGINT, avg_results INTEGER, zero_result_searches BIGINT, avg_execution_ms NUMERIC)
LANGUAGE sql
STABLE
AS $$
    SELECT lower(trim(sa.search_query)),
           count(*),
           avg(sa.results_count)::INTEGER,
           count(*) FILTER (WHERE sa.results_count = 0),   -- candidates for synonyms / typo handling
           round(avg(sa.execution_time_ms), 2)
    FROM analytics.search_analytics sa
    WHERE sa.search_timestamp >= now() - make_interval(days => days_back)
      AND length(trim(sa.search_query)) >= 3
    GROUP BY 1
    HAVING count(*) >= min_frequency
    ORDER BY 2 DESC, 1
    LIMIT 25;
$$;

-- Log a few searches (rolled back so re-runs do not accumulate rows).
BEGIN;
SELECT count(*) AS searches_logged
FROM (SELECT analytics.log_search_query(q, 'complaints',
                 (SELECT count(*)::int FROM documents.complaint_records
                  WHERE search_vector @@ websearch_to_tsquery('english', q)))
      FROM (VALUES ('pothole'), ('Pothole'), ('grafitti'), ('grafitti'), ('power outage')) AS t(q)) AS logged;
SELECT * FROM analytics.get_popular_search_terms(1, 2);
ROLLBACK;

\echo '== 06 fulltext: maintenance =='

-- =============================================================================
-- 8. MAINTENANCE
-- =============================================================================
-- Drift check (read-only): does the stored vector still equal what the base
-- trigger function would compute? Non-zero means rows were loaded with the
-- trigger disabled or the trigger definition changed - fix with a batched
-- UPDATE ... SET subject = subject (fires the trigger) on the affected ids.
CREATE OR REPLACE FUNCTION analytics.check_search_vectors()
RETURNS TABLE(table_name TEXT, total_rows BIGINT, stale_rows BIGINT)
LANGUAGE sql
STABLE
AS $$
    SELECT 'documents.complaint_records', count(*),
           count(*) FILTER (WHERE search_vector IS DISTINCT FROM to_tsvector('english',
               COALESCE(subject, '') || ' ' || COALESCE(description, '') || ' ' ||
               COALESCE(category, '') || ' ' || COALESCE(resolution_notes, '')))
    FROM documents.complaint_records
    UNION ALL
    SELECT 'documents.policy_documents', count(*),
           count(*) FILTER (WHERE search_vector IS DISTINCT FROM to_tsvector('english',
               COALESCE(title, '') || ' ' || COALESCE(document_content::text, '') || ' ' ||
               COALESCE(array_to_string(tags, ' '), '') || ' ' ||
               COALESCE(array_to_string(keywords, ' '), '')))
    FROM documents.policy_documents;
$$;

SELECT * FROM analytics.check_search_vectors();

-- The weighted MV is refreshed explicitly (e.g. from a scheduled job).
CREATE OR REPLACE FUNCTION analytics.refresh_search_vectors()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY documents.complaint_search_mv;
    RETURN format('complaint_search_mv refreshed: %s rows',
                  (SELECT count(*) FROM documents.complaint_search_mv));
END;
$$;

SELECT analytics.refresh_search_vectors();
