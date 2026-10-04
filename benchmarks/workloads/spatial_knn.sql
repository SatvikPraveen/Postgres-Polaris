-- Spatial read path: five nearest active points of interest to a random
-- location inside the city, ordered by the GiST KNN operator and reported
-- with geodesic distance.
\set xi random(0, 120000)
\set yi random(0, 64000)
SELECT poi_id, name, category,
       round(ST_Distance(location_geom::geography,
             ST_SetSRID(ST_MakePoint(-96.86 + :xi / 1000000.0, 32.948 + :yi / 1000000.0), 4326)::geography)) AS metres
FROM geo.points_of_interest
WHERE is_active
ORDER BY location_geom <-> ST_SetSRID(ST_MakePoint(-96.86 + :xi / 1000000.0, 32.948 + :yi / 1000000.0), 4326)
LIMIT 5;
