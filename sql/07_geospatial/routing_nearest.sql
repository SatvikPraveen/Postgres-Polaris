-- File: sql/07_geospatial/routing_nearest.sql
-- Purpose: Nearest-neighbour (KNN) analysis, reachability, and network routing in
--          plain SQL + PL/pgSQL (no pgRouting required).
--
-- What this module builds (all owned here, rebuilt idempotently):
--   geo.route_nodes            one row per street intersection (558 on the base grid)
--   geo.route_edges            one row per road segment, with source/target node ids,
--                              length in metres (geography) and travel time in seconds
--   geo.dijkstra(...)          single-source shortest paths (optionally A*, early stop)
--   geo.shortest_path(...)     source -> target route, one row per edge
--   geo.nearest_node(...)      snap an arbitrary point to the network with KNN (<->)
--   geo.find_nearest_services, geo.analyze_service_gaps, geo.calculate_walkable_area,
--   geo.analyze_multimodal_access, geo.calculate_straight_line_route,
--   geo.find_station_connections, geo.calculate_accessibility_score
--
-- pgRouting (pgr_dijkstra, pgr_drivingDistance, pgr_createTopology) is the production
-- answer for large networks; the hand-written versions here show what it does inside.
-- Distances are always measured as ::geography (metres).

\echo '== 0. Helper index: stations as geography points =='
-- Stations keep numeric latitude/longitude. An expression GiST index lets KNN
-- (ORDER BY ... <-> ...) and ST_DWithin on that expression use an index.
CREATE INDEX IF NOT EXISTS idx_stations_geog
    ON mobility.stations USING gist ((ST_SetSRID(ST_MakePoint(longitude::float8, latitude::float8), 4326)::geography));
CREATE INDEX IF NOT EXISTS idx_pois_geog
    ON geo.points_of_interest USING gist ((location_geom::geography));
CREATE INDEX IF NOT EXISTS idx_citizens_home_geom
    ON civics.citizens USING gist (home_geom);

-- =============================================================================
-- 1. NEAREST-NEIGHBOUR (KNN) WITH <-> AND LATERAL
-- =============================================================================
\echo '== 1. KNN: nearest POIs per station with LATERAL =='
-- What teaches: CROSS JOIN LATERAL (... ORDER BY a <-> b LIMIT k) runs one index-ordered
-- probe per outer row: the classic "k nearest X for every Y" pattern.
SELECT
    s.station_name,
    nn.rank_no,
    nn.name                     AS nearby_poi,
    nn.category,
    round(nn.distance_m::numeric) AS distance_m
FROM mobility.stations s
CROSS JOIN LATERAL (
    SELECT poi.name, poi.category,
           poi.location_geom::geography <-> ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography AS distance_m,
           row_number() OVER () AS rank_no
    FROM geo.points_of_interest poi
    WHERE poi.is_active
    ORDER BY poi.location_geom::geography
             <-> ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography,
             poi.poi_id
    LIMIT 3
) nn
WHERE s.station_type = 'rail'
ORDER BY s.station_name, nn.rank_no
LIMIT 12;

-- Nearest essential service of each requested type for an arbitrary location.
DROP FUNCTION IF EXISTS geo.find_nearest_services(numeric, numeric, text[]);
CREATE OR REPLACE FUNCTION geo.find_nearest_services(
    citizen_lat   numeric,
    citizen_lng   numeric,
    service_types text[] DEFAULT ARRAY['hospital', 'school', 'library', 'government']
)
RETURNS TABLE(service_type text, poi_name text, distance_meters integer,
              street_address text, phone text, coordinates text)
LANGUAGE sql
STABLE
AS $$
    WITH origin AS (
        SELECT ST_SetSRID(ST_MakePoint(citizen_lng::float8, citizen_lat::float8), 4326)::geography AS g
    )
    SELECT st::text,
           n.name::text,
           round(n.d)::integer,
           n.street_address::text,
           n.phone::text,
           round(ST_Y(n.location_geom)::numeric, 6) || ',' || round(ST_X(n.location_geom)::numeric, 6)
    FROM origin o
    CROSS JOIN unnest(service_types) AS st
    CROSS JOIN LATERAL (
        SELECT poi.name, poi.street_address, poi.phone, poi.location_geom,
               poi.location_geom::geography <-> o.g AS d
        FROM geo.points_of_interest poi
        WHERE poi.category = st::geo.poi_category      -- text -> enum, must be explicit
          AND poi.is_active
        ORDER BY poi.location_geom::geography <-> o.g, poi.poi_id
        LIMIT 1
    ) n
    ORDER BY n.d, st;
$$;

SELECT * FROM geo.find_nearest_services(32.9855, -96.8040);

\echo '== 2. Service gaps per neighbourhood (real citizen homes) =='
-- What teaches: KNN per citizen (10k LATERAL probes) + point-in-polygon to assign
-- each home to a neighbourhood, then aggregate. Uses civics.citizens.home_geom.
DROP FUNCTION IF EXISTS geo.analyze_service_gaps(integer);
CREATE OR REPLACE FUNCTION geo.analyze_service_gaps(
    max_acceptable_distance_meters integer DEFAULT 1000
)
RETURNS TABLE(neighborhood_name text, service_type text, citizens bigint,
              avg_distance_to_nearest numeric, max_distance_to_nearest numeric,
              citizens_underserved bigint)
LANGUAGE sql
STABLE
AS $$
    WITH services AS (
        SELECT unnest(ARRAY['hospital', 'school', 'library', 'government']::geo.poi_category[]) AS category
    ),
    citizen_service_distances AS (
        SELECT c.citizen_id, nb.neighborhood_name, s.category, nn.d AS distance_to_nearest
        FROM civics.citizens c
        JOIN geo.neighborhood_boundaries nb ON ST_Contains(nb.boundary_geom, c.home_geom)
        CROSS JOIN services s
        CROSS JOIN LATERAL (
            SELECT ST_Distance(poi.location_geom::geography, c.home_geom::geography) AS d
            FROM geo.points_of_interest poi
            WHERE poi.category = s.category AND poi.is_active
            ORDER BY poi.location_geom <-> c.home_geom   -- geometry KNN is fine for ranking here
            LIMIT 1
        ) nn
        WHERE c.status = 'active' AND c.home_geom IS NOT NULL
    )
    SELECT neighborhood_name::text,
           category::text,
           count(*),
           round(avg(distance_to_nearest)::numeric, 0),
           round(max(distance_to_nearest)::numeric, 0),
           count(*) FILTER (WHERE distance_to_nearest > max_acceptable_distance_meters)
    FROM citizen_service_distances
    GROUP BY neighborhood_name, category
    HAVING count(*) FILTER (WHERE distance_to_nearest > max_acceptable_distance_meters) > 0
    ORDER BY 6 DESC, 5 DESC, 1, 2;
$$;

SELECT * FROM geo.analyze_service_gaps(1000) LIMIT 10;

-- =============================================================================
-- 3. BUILD A ROUTABLE GRAPH FROM geo.road_segments
-- =============================================================================
\echo '== 3. Build node/edge topology from road_segments =='
-- What teaches: a road network becomes a graph by (a) snapping segment endpoints to
-- shared nodes and (b) giving each segment a source and target node. This is what
-- pgr_createTopology / pgr_extractVertices do. Snapping to a 1e-7 degree grid (~1 cm)
-- merges endpoints that should coincide but differ by floating-point noise.
DROP VIEW IF EXISTS geo.route_arcs;
DROP TABLE IF EXISTS geo.route_edges;
DROP TABLE IF EXISTS geo.route_nodes;

CREATE TABLE geo.route_nodes (
    node_id bigint PRIMARY KEY,
    geom    geometry(Point, 4326) NOT NULL UNIQUE
);

INSERT INTO geo.route_nodes (node_id, geom)
SELECT row_number() OVER (ORDER BY ST_Y(p), ST_X(p)), p      -- deterministic ids: south->north, west->east
FROM (
    SELECT DISTINCT ST_SnapToGrid(ST_StartPoint(segment_geom), 1e-7) AS p FROM geo.road_segments
    UNION
    SELECT ST_SnapToGrid(ST_EndPoint(segment_geom), 1e-7) FROM geo.road_segments
) pts;
CREATE INDEX route_nodes_geom_gix ON geo.route_nodes USING gist (geom);

CREATE TABLE geo.route_edges (
    edge_id     bigint PRIMARY KEY,                -- = road_segments.segment_id
    source      bigint NOT NULL REFERENCES geo.route_nodes,
    target      bigint NOT NULL REFERENCES geo.route_nodes,
    road_name   text,
    road_type   geo.road_type,
    one_way     boolean NOT NULL DEFAULT false,
    length_m    double precision NOT NULL,         -- geodesic metres
    cost_s      double precision NOT NULL,         -- travel time at the posted limit
    geom        geometry(LineString, 4326) NOT NULL
);

INSERT INTO geo.route_edges
SELECT rs.segment_id,
       ns.node_id,
       nt.node_id,
       rs.road_name,
       rs.road_type,
       coalesce(rs.one_way, false),
       ST_Length(rs.segment_geom::geography),
       -- speed_limit is mph; 1 mph = 0.44704 m/s. Missing limit -> 25 mph.
       ST_Length(rs.segment_geom::geography) / (coalesce(rs.speed_limit, 25) * 0.44704),
       rs.segment_geom
FROM geo.road_segments rs
JOIN geo.route_nodes ns ON ns.geom = ST_SnapToGrid(ST_StartPoint(rs.segment_geom), 1e-7)
JOIN geo.route_nodes nt ON nt.geom = ST_SnapToGrid(ST_EndPoint(rs.segment_geom), 1e-7);

-- Directed adjacency: every two-way edge is usable in both directions.
CREATE OR REPLACE VIEW geo.route_arcs AS
SELECT edge_id, source AS from_node, target AS to_node, length_m, cost_s FROM geo.route_edges
UNION ALL
SELECT edge_id, target, source, length_m, cost_s FROM geo.route_edges WHERE NOT one_way;

CREATE INDEX route_edges_source_idx ON geo.route_edges (source);
CREATE INDEX route_edges_target_idx ON geo.route_edges (target);
ANALYZE geo.route_nodes;
ANALYZE geo.route_edges;

-- Topology sanity checks: node degree distribution (grid => corners 2, sides 3, interior 4)
SELECT degree, count(*) AS nodes
FROM (
    SELECT n.node_id, count(a.edge_id) AS degree
    FROM geo.route_nodes n
    LEFT JOIN geo.route_arcs a ON a.from_node = n.node_id
    GROUP BY n.node_id
) d
GROUP BY degree
ORDER BY degree;

SELECT (SELECT count(*) FROM geo.route_nodes)                 AS nodes,
       (SELECT count(*) FROM geo.route_edges)                 AS edges,
       (SELECT round(sum(length_m)::numeric / 1000, 1) FROM geo.route_edges) AS network_km;

-- Connectivity check with a recursive CTE (breadth-first reachability from node 1).
-- UNION (not UNION ALL) de-duplicates, so the recursion terminates on cycles.
WITH RECURSIVE reach(node_id) AS (
    SELECT 1::bigint
    UNION
    SELECT a.to_node
    FROM reach r
    JOIN geo.route_edges e ON e.source = r.node_id OR e.target = r.node_id
    CROSS JOIN LATERAL (SELECT CASE WHEN e.source = r.node_id THEN e.target ELSE e.source END AS to_node) a
)
SELECT count(*) AS reachable_from_node_1,
       (SELECT count(*) FROM geo.route_nodes) AS total_nodes
FROM reach;

-- =============================================================================
-- 4. SNAPPING POINTS TO THE NETWORK
-- =============================================================================
\echo '== 4. Snap arbitrary points to the nearest network node (KNN) =='
CREATE OR REPLACE FUNCTION geo.nearest_node(p geometry)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
    SELECT node_id
    FROM geo.route_nodes
    ORDER BY geom <-> ST_SetSRID(p, 4326), node_id
    LIMIT 1;
$$;

SELECT s.station_name,
       geo.nearest_node(ST_MakePoint(s.longitude::float8, s.latitude::float8)) AS node_id,
       round(ST_Distance(
           ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography,
           n.geom::geography)::numeric, 1) AS snap_distance_m
FROM mobility.stations s
JOIN geo.route_nodes n
  ON n.node_id = geo.nearest_node(ST_MakePoint(s.longitude::float8, s.latitude::float8))
ORDER BY s.station_id
LIMIT 5;

-- =============================================================================
-- 5. DIJKSTRA / A* IN PL/pgSQL
-- =============================================================================
\echo '== 5. Dijkstra and A* shortest paths =='
-- What teaches: the textbook algorithm with arrays indexed by node_id (dense 1..N):
--   dist[]  best known cost from the source
--   prev_node[] / prev_edge[]  back-pointers to reconstruct the path
--   done[]  settled nodes
-- Each iteration settles the unsettled node with the smallest dist (+ heuristic for A*)
-- and relaxes its outgoing arcs. O(N^2) selection is fine for a few thousand nodes.
-- metric: 'distance' (metres) or 'time' (seconds). A* heuristic = straight-line
-- geodesic distance (divided by the max speed for 'time'), which never overestimates,
-- so A* still returns an optimal path while settling fewer nodes.
DROP FUNCTION IF EXISTS geo.shortest_path(bigint, bigint, text, boolean);
DROP FUNCTION IF EXISTS geo.dijkstra(bigint, bigint, text, double precision, boolean);
CREATE OR REPLACE FUNCTION geo.dijkstra(
    p_source   bigint,
    p_target   bigint DEFAULT NULL,             -- stop early when settled
    p_metric   text   DEFAULT 'distance',
    p_max_cost double precision DEFAULT 'Infinity',  -- for isochrones / driving distance
    p_astar    boolean DEFAULT false
)
RETURNS TABLE(node_id bigint, agg_cost double precision, prev_node bigint, prev_edge bigint, settled_order integer)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    n          integer;
    dist       double precision[];
    h          double precision[];
    prev_node  bigint[];
    prev_edge  bigint[];
    done       boolean[];
    ord        integer[];
    u          integer;
    best       double precision;
    i          integer;
    k          integer := 0;
    arc        record;
    nd         double precision;
    max_speed  double precision;
BEGIN
    IF p_metric NOT IN ('distance', 'time') THEN
        RAISE EXCEPTION 'metric must be distance or time, got %', p_metric;
    END IF;
    SELECT max(r.node_id) INTO n FROM geo.route_nodes r;
    IF p_source IS NULL OR p_source < 1 OR p_source > n THEN
        RAISE EXCEPTION 'unknown source node %', p_source;
    END IF;

    dist      := array_fill('Infinity'::double precision, ARRAY[n]);
    h         := array_fill(0::double precision, ARRAY[n]);
    prev_node := array_fill(NULL::bigint, ARRAY[n]);
    prev_edge := array_fill(NULL::bigint, ARRAY[n]);
    done      := array_fill(false, ARRAY[n]);
    ord       := array_fill(NULL::integer, ARRAY[n]);
    dist[p_source] := 0;

    IF p_astar AND p_target IS NOT NULL THEN
        SELECT max(e.length_m / e.cost_s) INTO max_speed FROM geo.route_edges e;   -- m/s
        SELECT array_agg(ST_Distance(r.geom::geography, t.geom::geography)
                         / CASE WHEN p_metric = 'time' THEN max_speed ELSE 1 END
                         ORDER BY r.node_id)
          INTO h
          FROM geo.route_nodes r, geo.route_nodes t
         WHERE t.node_id = p_target;
    END IF;

    LOOP
        -- pick the unsettled node with the smallest dist + heuristic
        u := NULL; best := 'Infinity';
        FOR i IN 1..n LOOP
            IF NOT done[i] AND dist[i] + h[i] < best THEN
                best := dist[i] + h[i]; u := i;
            END IF;
        END LOOP;
        EXIT WHEN u IS NULL OR dist[u] > p_max_cost;

        done[u] := true;
        k := k + 1;
        ord[u] := k;
        EXIT WHEN u = p_target;

        FOR arc IN
            SELECT a.to_node, a.edge_id,
                   CASE WHEN p_metric = 'time' THEN a.cost_s ELSE a.length_m END AS w
            FROM geo.route_arcs a
            WHERE a.from_node = u
        LOOP
            nd := dist[u] + arc.w;
            IF nd < dist[arc.to_node] THEN
                dist[arc.to_node]      := nd;
                prev_node[arc.to_node] := u;
                prev_edge[arc.to_node] := arc.edge_id;
            END IF;
        END LOOP;
    END LOOP;

    RETURN QUERY
    SELECT g.idx::bigint, dist[g.idx], prev_node[g.idx], prev_edge[g.idx], ord[g.idx]
    FROM generate_series(1, n) AS g(idx)
    WHERE done[g.idx];
END;
$$;

-- Path reconstruction: walk the back-pointers from target to source.
CREATE OR REPLACE FUNCTION geo.shortest_path(
    p_source bigint,
    p_target bigint,
    p_metric text    DEFAULT 'distance',
    p_astar  boolean DEFAULT false
)
RETURNS TABLE(seq integer, node_id bigint, edge_id bigint, road_name text,
              edge_length_m double precision, agg_cost double precision)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE sp AS (
        SELECT * FROM geo.dijkstra(p_source, p_target, p_metric, 'Infinity', p_astar)
    ),
    walk AS (
        SELECT sp.node_id, sp.prev_node, sp.prev_edge, sp.agg_cost, 0 AS depth
        FROM sp WHERE sp.node_id = p_target
        UNION ALL
        SELECT sp.node_id, sp.prev_node, sp.prev_edge, sp.agg_cost, w.depth + 1
        FROM walk w JOIN sp ON sp.node_id = w.prev_node
    )
    SELECT (row_number() OVER (ORDER BY w.depth DESC))::integer,
           w.node_id,
           w.prev_edge,                          -- edge used to ARRIVE at this node
           e.road_name,
           e.length_m,
           w.agg_cost
    FROM walk w
    LEFT JOIN geo.route_edges e ON e.edge_id = w.prev_edge
    ORDER BY w.depth DESC;
$$;

-- Route from the south-west corner (node 1) to the north-east corner (last node).
-- On a perfect grid the shortest distance equals the Manhattan distance, which
-- gives us a built-in correctness check.
WITH ends AS (
    SELECT min(node_id) AS s, max(node_id) AS t FROM geo.route_nodes
),
route AS (
    SELECT p.* FROM ends, LATERAL geo.shortest_path(ends.s, ends.t, 'distance') p
)
SELECT count(*) - 1                                        AS edges_used,
       round(max(agg_cost)::numeric, 1)                    AS network_m,
       round((SELECT ST_Distance(a.geom::geography, ST_MakePoint(ST_X(b.geom), ST_Y(a.geom))::geography)
                   + ST_Distance(b.geom::geography, ST_MakePoint(ST_X(b.geom), ST_Y(a.geom))::geography)
              FROM ends, geo.route_nodes a, geo.route_nodes b
              WHERE a.node_id = ends.s AND b.node_id = ends.t)::numeric, 1) AS manhattan_m,
       round((SELECT ST_Distance(a.geom::geography, b.geom::geography)
              FROM ends, geo.route_nodes a, geo.route_nodes b
              WHERE a.node_id = ends.s AND b.node_id = ends.t)::numeric, 1) AS straight_line_m
FROM route;

-- Shortest vs fastest: residential streets are 25 mph, arterials 45 mph, so the
-- time-optimal route detours onto arterials. Show the first legs of each.
SELECT 'shortest (distance)' AS objective, seq, node_id, road_name,
       round(edge_length_m::numeric) AS edge_m, round(agg_cost::numeric, 1) AS agg_cost
FROM geo.shortest_path(40, 520, 'distance')
WHERE seq <= 6
UNION ALL
SELECT 'fastest (time, s)', seq, node_id, road_name,
       round(edge_length_m::numeric), round(agg_cost::numeric, 1)
FROM geo.shortest_path(40, 520, 'time')
WHERE seq <= 6
ORDER BY objective, seq;

-- Route summary + geometry: ST_LineMerge stitches the edges into one LineString.
SELECT objective,
       count(p.edge_id)                                              AS edges,
       round(sum(e.length_m)::numeric)                               AS length_m,
       round((sum(e.cost_s) / 60)::numeric, 1)                       AS drive_minutes,
       string_agg(DISTINCT e.road_type::text, ', ')                  AS road_types,
       ST_GeometryType(ST_LineMerge(ST_Collect(e.geom ORDER BY p.seq))) AS merged_type
FROM (VALUES ('distance'), ('time')) AS o(objective)
CROSS JOIN LATERAL geo.shortest_path(40, 520, o.objective) p
JOIN geo.route_edges e ON e.edge_id = p.edge_id
GROUP BY objective
ORDER BY objective;

-- A* settles fewer nodes than Dijkstra yet finds the same optimal cost.
SELECT algo,
       count(*)                                        AS nodes_settled,
       round(max(agg_cost) FILTER (WHERE node_id = 520)::numeric, 1) AS cost_to_target
FROM (
    SELECT 'dijkstra' AS algo, d.* FROM geo.dijkstra(40, 520, 'distance', 'Infinity', false) d
    UNION ALL
    SELECT 'a_star', d.* FROM geo.dijkstra(40, 520, 'distance', 'Infinity', true) d
) x
GROUP BY algo
ORDER BY algo;

-- =============================================================================
-- 6. REACHABILITY / ISOCHRONES
-- =============================================================================
\echo '== 6. Network isochrone vs straight-line buffer =='
-- What teaches: "what can I reach in 800 m of walking" along streets (network
-- distance, like pgr_drivingDistance) is smaller than an 800 m radius circle.
DROP FUNCTION IF EXISTS geo.calculate_walkable_area(numeric, numeric, integer);
CREATE OR REPLACE FUNCTION geo.calculate_walkable_area(
    station_lat          numeric,
    station_lng          numeric,
    walk_distance_meters integer DEFAULT 800
)
RETURNS TABLE(method text, reachable_pois integer, reachable_area_sq_km numeric, poi_categories text)
LANGUAGE sql
STABLE
AS $$
    WITH origin AS (
        SELECT ST_SetSRID(ST_MakePoint(station_lng::float8, station_lat::float8), 4326) AS g
    ),
    reached AS (
        SELECT d.node_id
        FROM origin o, LATERAL geo.dijkstra(geo.nearest_node(o.g), NULL, 'distance', walk_distance_meters) d
    ),
    shapes AS (
        SELECT 'straight-line buffer' AS method,
               ST_Buffer(o.g::geography, walk_distance_meters)::geometry AS shape
        FROM origin o
        UNION ALL
        -- network isochrone: concave hull of reached nodes, widened by 50 m of frontage
        SELECT 'network isochrone',
               ST_Buffer(ST_ConcaveHull(ST_Collect(n.geom), 0.3)::geography, 50)::geometry
        FROM reached r JOIN geo.route_nodes n USING (node_id)
    )
    SELECT s.method,
           (SELECT count(*)::integer FROM geo.points_of_interest p
             WHERE p.is_active AND ST_Contains(s.shape, p.location_geom)),
           round((ST_Area(s.shape::geography) / 1e6)::numeric, 3),
           (SELECT string_agg(DISTINCT p.category::text, ', ') FROM geo.points_of_interest p
             WHERE p.is_active AND ST_Contains(s.shape, p.location_geom))
    FROM shapes s
    ORDER BY s.method;
$$;

SELECT method, reachable_pois, reachable_area_sq_km, left(poi_categories, 60) AS categories
FROM geo.calculate_walkable_area(32.9800, -96.8000, 800);

-- Multi-modal access: how many stations are within walking / cycling range and
-- which is nearest (KNN), all measured in metres.
DROP FUNCTION IF EXISTS geo.analyze_multimodal_access(numeric, numeric);
CREATE OR REPLACE FUNCTION geo.analyze_multimodal_access(origin_lat numeric, origin_lng numeric)
RETURNS TABLE(access_mode text, reachable_stations integer, nearest_station_name text,
              nearest_station_distance_m integer, total_pois_reachable integer)
LANGUAGE sql
STABLE
AS $$
    WITH origin AS (
        SELECT ST_SetSRID(ST_MakePoint(origin_lng::float8, origin_lat::float8), 4326)::geography AS g
    ),
    modes(access_mode, radius_m, station_filter) AS (
        VALUES ('Walking (800m)', 800, NULL::mobility.station_type),
               ('Cycling (2000m)', 2000, 'bike_share'::mobility.station_type)
    )
    SELECT m.access_mode,
           (SELECT count(*)::integer FROM mobility.stations s
             WHERE s.status = 'active'
               AND ST_DWithin(ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography, o.g, m.radius_m)),
           nearest.station_name::text,
           round(nearest.d)::integer,
           (SELECT count(*)::integer FROM geo.points_of_interest p
             WHERE p.is_active AND ST_DWithin(p.location_geom::geography, o.g, m.radius_m))
    FROM modes m
    CROSS JOIN origin o
    CROSS JOIN LATERAL (
        SELECT s.station_name,
               ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography <-> o.g AS d
        FROM mobility.stations s
        WHERE s.status = 'active'
          AND (m.station_filter IS NULL OR s.station_type = m.station_filter)
        ORDER BY ST_SetSRID(ST_MakePoint(s.longitude::float8, s.latitude::float8), 4326)::geography <-> o.g, s.station_id
        LIMIT 1
    ) nearest
    ORDER BY m.radius_m;
$$;

SELECT * FROM geo.analyze_multimodal_access(32.9855, -96.8040);

-- =============================================================================
-- 7. STRAIGHT-LINE VS NETWORK ROUTES
-- =============================================================================
\echo '== 7. Straight-line vs network route =='
DROP FUNCTION IF EXISTS geo.calculate_straight_line_route(numeric, numeric, numeric, numeric);
CREATE OR REPLACE FUNCTION geo.calculate_straight_line_route(
    start_lat numeric, start_lng numeric, end_lat numeric, end_lng numeric
)
RETURNS TABLE(straight_line_m integer, network_m integer, detour_ratio numeric,
              bearing_degrees numeric, estimated_walk_minutes integer,
              estimated_bike_minutes integer, pois_within_50m_of_line integer)
LANGUAGE sql
STABLE
AS $$
    WITH pts AS (
        SELECT ST_SetSRID(ST_MakePoint(start_lng::float8, start_lat::float8), 4326) AS a,
               ST_SetSRID(ST_MakePoint(end_lng::float8,   end_lat::float8),   4326) AS b
    ),
    net AS (
        SELECT max(p.agg_cost) AS network_m
        FROM pts, LATERAL geo.shortest_path(geo.nearest_node(pts.a), geo.nearest_node(pts.b), 'distance', true) p
    )
    SELECT round(ST_Distance(a::geography, b::geography))::integer,
           round(net.network_m)::integer,
           round((net.network_m / NULLIF(ST_Distance(a::geography, b::geography), 0))::numeric, 2),
           round(degrees(ST_Azimuth(a::geography, b::geography))::numeric, 1),
           round(net.network_m / 80)::integer,     -- walking 4.8 km/h = 80 m/min
           round(net.network_m / 250)::integer,    -- cycling 15 km/h = 250 m/min
           (SELECT count(*)::integer FROM geo.points_of_interest poi
             WHERE ST_DWithin(poi.location_geom::geography, ST_MakeLine(a, b)::geography, 50))
    FROM pts, net;
$$;

SELECT * FROM geo.calculate_straight_line_route(32.9500, -96.8500, 33.0050, -96.7500);

-- Station-to-station pairs within a radius (straight line), the nearest first.
DROP FUNCTION IF EXISTS geo.find_station_connections(integer);
CREATE OR REPLACE FUNCTION geo.find_station_connections(max_distance_meters integer DEFAULT 2000)
RETURNS TABLE(from_station text, to_station text, connection_type text,
              distance_meters integer, estimated_time_minutes integer)
LANGUAGE sql
STABLE
AS $$
    WITH st AS (
        SELECT station_id, station_name, station_type,
               ST_SetSRID(ST_MakePoint(longitude::float8, latitude::float8), 4326)::geography AS g
        FROM mobility.stations
        WHERE status = 'active'
    )
    SELECT s1.station_name::text,
           s2.station_name::text,
           CASE
               WHEN s1.station_type = 'bike_share' AND s2.station_type = 'bike_share' THEN 'Bike-to-Bike'
               WHEN s1.station_type = 'bus'  AND s2.station_type = 'rail' THEN 'Bus-to-Rail'
               WHEN s1.station_type = 'rail' AND s2.station_type = 'bus'  THEN 'Rail-to-Bus'
               ELSE 'Multi-Modal'
           END,
           round(ST_Distance(s1.g, s2.g))::integer,
           CASE WHEN 'bike_share' IN (s1.station_type::text, s2.station_type::text)
                THEN round(ST_Distance(s1.g, s2.g) / 250)::integer
                ELSE round(ST_Distance(s1.g, s2.g) / 80)::integer
           END
    FROM st s1
    JOIN st s2 ON s1.station_id < s2.station_id
              AND ST_DWithin(s1.g, s2.g, max_distance_meters)
    ORDER BY 4, 1, 2
    LIMIT 20;
$$;

SELECT * FROM geo.find_station_connections(300) LIMIT 8;

-- =============================================================================
-- 8. ACCESSIBILITY SCORING
-- =============================================================================
\echo '== 8. Accessibility score =='
DROP FUNCTION IF EXISTS geo.calculate_accessibility_score(numeric, numeric);
CREATE OR REPLACE FUNCTION geo.calculate_accessibility_score(location_lat numeric, location_lng numeric)
RETURNS TABLE(overall_score numeric, transit_score numeric, walkability_score numeric,
              service_accessibility_score numeric, score_breakdown jsonb)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    loc                geography := ST_SetSRID(ST_MakePoint(location_lng::float8, location_lat::float8), 4326)::geography;
    transit_count      integer;
    poi_count          integer;
    essential_services integer;
    t numeric; w numeric; s numeric;
BEGIN
    SELECT count(*) INTO transit_count
    FROM mobility.stations st
    WHERE st.status = 'active'
      AND ST_DWithin(ST_SetSRID(ST_MakePoint(st.longitude::float8, st.latitude::float8), 4326)::geography, loc, 800);

    SELECT count(*) INTO poi_count
    FROM geo.points_of_interest poi
    WHERE poi.is_active AND ST_DWithin(poi.location_geom::geography, loc, 1000);

    SELECT count(*) INTO essential_services
    FROM geo.points_of_interest poi
    WHERE poi.is_active
      AND poi.category IN ('hospital', 'school', 'library', 'government')
      AND ST_DWithin(poi.location_geom::geography, loc, 1500);

    t := LEAST(transit_count * 25, 100);
    w := LEAST(poi_count * 5, 100);
    s := LEAST(essential_services * 20, 100);

    RETURN QUERY SELECT
        round((t + w + s) / 3.0, 1), t, w, s,
        jsonb_build_object('transit_stations_800m', transit_count,
                           'pois_1km', poi_count,
                           'essential_services_1500m', essential_services);
END;
$$;

SELECT label, sc.*
FROM (VALUES ('City Hall', 32.9855::numeric, -96.8040::numeric),
             ('NE edge',   33.0090, -96.7410)) AS v(label, lat, lng)
CROSS JOIN LATERAL geo.calculate_accessibility_score(v.lat, v.lng) sc
ORDER BY label;
