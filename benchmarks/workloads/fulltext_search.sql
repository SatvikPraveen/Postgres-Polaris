-- Search path: ranked full-text search over complaints with a random term
-- from a fixed vocabulary, GIN index on the stored tsvector.
\set t random(1, 8)
SELECT complaint_id, subject, ts_rank_cd(search_vector, q) AS rank
FROM documents.complaint_records,
     websearch_to_tsquery('english',
        (ARRAY['pothole','noise','streetlight','dumping','graffiti','parking','water leak','stray dog'])[:t]) q
WHERE search_vector @@ q
ORDER BY rank DESC, complaint_id
LIMIT 10;
