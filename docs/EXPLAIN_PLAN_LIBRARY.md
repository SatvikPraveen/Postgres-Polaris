# EXPLAIN Plan Library

A reference of PostgreSQL plan node types, illustrated only with plans captured from the
Polaris base dataset (scale 1, seed 42) on PostgreSQL 17 with the repository's Docker
configuration (`shared_buffers = 256MB`, `work_mem = 16MB`,
`max_parallel_workers_per_gather = 4`, `track_io_timing = on`, JIT off).

Each entry gives the query, the real plan (the `Planning:` buffer lines are trimmed; nothing
else is edited) and what to look for. Timings and buffer counts are machine-specific and
change between runs; costs, row counts and plan shapes are what to compare. If your plan
differs, check that the table statistics are fresh (`ANALYZE`) and that your settings match.

Module 11 (`sql/11_perf_tuning/explain_analyze_playbook.sql`) has the runnable lesson that
goes with this page.

## Reading EXPLAIN (ANALYZE, BUFFERS)

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT m.business_name, count(*) AS orders
FROM commerce.orders o
JOIN commerce.merchants m USING (merchant_id)
WHERE o.order_date >= meta.as_of() - interval '7 days'
GROUP BY m.business_name
ORDER BY orders DESC
LIMIT 3;
```

```text
Limit  (cost=715.28..715.29 rows=3 width=28) (actual time=0.775..0.776 rows=3 loops=1)
  Buffers: shared hit=740
  ->  Sort  (cost=715.28..716.53 rows=500 width=28) (actual time=0.775..0.776 rows=3 loops=1)
        Sort Key: (count(*)) DESC
        Sort Method: top-N heapsort  Memory: 25kB
        Buffers: shared hit=740
        ->  HashAggregate  (cost=703.82..708.82 rows=500 width=28) (actual time=0.729..0.743 rows=218 loops=1)
              Group Key: m.business_name
              Batches: 1  Memory Usage: 73kB
              Buffers: shared hit=737
              ->  Hash Join  (cost=32.79..700.31 rows=701 width=20) (actual time=0.106..0.650 rows=708 loops=1)
                    Hash Cond: (o.merchant_id = m.merchant_id)
                    Buffers: shared hit=737
                    ->  Index Scan using idx_orders_date on orders o  (cost=0.54..666.21 rows=701 width=8) (actual time=0.034..0.508 rows=708 loops=1)
                          Index Cond: (order_date >= (meta.as_of() - '7 days'::interval))
                          Buffers: shared hit=716
                    ->  Hash  (cost=26.00..26.00 rows=500 width=28) (actual time=0.067..0.067 rows=500 loops=1)
                          Buckets: 1024  Batches: 1  Memory Usage: 40kB
                          Buffers: shared hit=21
                          ->  Seq Scan on merchants m  (cost=0.00..26.00 rows=500 width=28) (actual time=0.005..0.039 rows=500 loops=1)
                                Buffers: shared hit=21
Planning Time: 1.726 ms
Execution Time: 0.868 ms
```

How to read it:

- **Tree order.** Each `->` is a child of the node above it. Execution is demand-driven
  from the top, but data flows from the most-indented nodes upwards. Read inside-out.
- **`cost=startup..total`** is in planner units (`seq_page_cost = 1`). Startup cost is spent
  before the first row comes out (a Sort must read all its input first). Costs of a node
  include its children.
- **`rows`** in the cost part is the estimate per loop; **`actual ... rows`** is the measured
  average per loop. Multiply by **`loops`** to get the total a node produced. A large gap
  between the two is the most common root cause of a bad plan (see
  [Estimates vs actuals](#estimates-vs-actuals-and-extended-statistics)).
- **`actual time=first..last`** is in milliseconds per loop and also includes children.
- **`Buffers: shared hit=H read=R`** counts 8 kB pages found in shared buffers (`hit`) and
  pages requested from the OS (`read`, which may still come from the OS page cache).
  `dirtied`/`written` appear for writes; `temp read/written` means a spill to disk.
- **`I/O Timings`** (only with `track_io_timing = on`) is the time spent waiting for those
  reads and writes.
- **`Rows Removed by Filter`** is work the access path did not avoid; an index or a better
  predicate can often remove it.
- `meta.as_of()` is `STABLE`, so its value is computed at executor start: the index
  condition above uses the parameter, and the same plan works on any machine date.

## Setup used by some entries

Some entries need objects that the base dataset does not have. They live in a scratch
schema `lab` so the base tables stay untouched:

```sql
CREATE SCHEMA IF NOT EXISTS lab;

-- a heap copy of the sensor readings in time order, with only a BRIN index
DROP TABLE IF EXISTS lab.sensor_brin;
CREATE TABLE lab.sensor_brin AS
SELECT * FROM mobility.sensor_readings ORDER BY reading_time;
CREATE INDEX sensor_brin_time_brin ON lab.sensor_brin USING brin (reading_time);

-- a monthly range-partitioned copy for partition pruning
DROP TABLE IF EXISTS lab.sensor_part;
CREATE TABLE lab.sensor_part (LIKE mobility.sensor_readings INCLUDING DEFAULTS)
    PARTITION BY RANGE (reading_time);
CREATE TABLE lab.sensor_part_2025_10 PARTITION OF lab.sensor_part
    FOR VALUES FROM ('2025-10-01 00:00:00+00') TO ('2025-11-01 00:00:00+00');
CREATE TABLE lab.sensor_part_2025_11 PARTITION OF lab.sensor_part
    FOR VALUES FROM ('2025-11-01 00:00:00+00') TO ('2025-12-01 00:00:00+00');
CREATE TABLE lab.sensor_part_2025_12 PARTITION OF lab.sensor_part
    FOR VALUES FROM ('2025-12-01 00:00:00+00') TO ('2026-01-01 00:00:00+00');
INSERT INTO lab.sensor_part SELECT * FROM mobility.sensor_readings;
CREATE INDEX ON lab.sensor_part (sensor_code, reading_time);

-- a copy for the statistics experiment
DROP TABLE IF EXISTS lab.sensor_stats;
CREATE TABLE lab.sensor_stats AS SELECT * FROM mobility.sensor_readings;

VACUUM ANALYZE lab.sensor_brin, lab.sensor_part, lab.sensor_stats;
```

## Scan nodes

### Seq Scan

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, tip_amount
FROM commerce.orders
WHERE tip_amount > 40;
```

```text
Seq Scan on orders  (cost=0.00..2453.00 rows=105 width=12) (actual time=12.894..23.712 rows=37 loops=1)
  Filter: (tip_amount > '40'::numeric)
  Rows Removed by Filter: 49963
  Buffers: shared hit=461 read=1367 written=941
  I/O Timings: shared read=4.976 write=11.649
Planning Time: 0.263 ms
Execution Time: 23.743 ms
```

- No index on `tip_amount`, so every page of the table is read and each row is tested.
- `Rows Removed by Filter` against the rows returned shows how selective the predicate is.
  A Seq Scan is the right plan when a large fraction of the table qualifies.

### Index Scan

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT citizen_id, first_name, last_name
FROM civics.citizens
WHERE email = 'kevin.chen.4242@mail.polaris.example';
```

```text
Index Scan using idx_citizens_email on citizens  (cost=0.29..2.50 rows=1 width=20) (actual time=0.060..0.061 rows=1 loops=1)
  Index Cond: ((email)::text = 'kevin.chen.4242@mail.polaris.example'::text)
  Buffers: shared read=3
  I/O Timings: shared read=0.025
Planning Time: 0.766 ms
Execution Time: 0.127 ms
```

- `Index Cond` is the part of the predicate answered by the index; there is no
  `Filter` because the index fully answers it.
- An Index Scan visits the heap for every match, in index order. It wins for a handful of
  rows, loses to a Bitmap Heap Scan or Seq Scan as the match count grows.

### Index Only Scan

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM commerce.orders
WHERE order_date >= '2025-12-01 00:00:00+00';
```

```text
Aggregate  (cost=121.21..121.22 rows=1 width=8) (actual time=0.943..0.943 rows=1 loops=1)
  Buffers: shared hit=9 read=23
  I/O Timings: shared read=0.232
  ->  Index Only Scan using idx_orders_date on orders  (cost=0.29..109.81 rows=4561 width=0) (actual time=0.051..0.718 rows=4516 loops=1)
        Index Cond: (order_date >= '2025-12-01 00:00:00+00'::timestamp with time zone)
        Heap Fetches: 0
        Buffers: shared hit=9 read=23
        I/O Timings: shared read=0.232
Planning Time: 0.434 ms
Execution Time: 0.997 ms
```

- Every column the query needs is in the index (`order_date`), so the heap is not read.
- `Heap Fetches: 0` means every page was marked all-visible in the visibility map. After
  heavy updates the count rises until `VACUUM` sets the bits again.

### Bitmap Index Scan and Bitmap Heap Scan

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, total_amount
FROM commerce.orders
WHERE status = 'cancelled'
   OR customer_citizen_id = 3301;
```

```text
Bitmap Heap Scan on orders  (cost=22.37..1382.05 rows=2036 width=14) (actual time=0.408..2.718 rows=2007 loops=1)
  Recheck Cond: ((status = 'cancelled'::commerce.order_status) OR (customer_citizen_id = 3301))
  Heap Blocks: exact=866
  Buffers: shared hit=869 read=6
  I/O Timings: shared read=0.074
  ->  BitmapOr  (cost=22.37..22.37 rows=2037 width=0) (actual time=0.235..0.236 rows=0 loops=1)
        Buffers: shared hit=3 read=6
        I/O Timings: shared read=0.074
        ->  Bitmap Index Scan on idx_orders_status  (cost=0.00..19.86 rows=2023 width=0) (actual time=0.175..0.176 rows=1991 loops=1)
              Index Cond: (status = 'cancelled'::commerce.order_status)
              Buffers: shared read=4
              I/O Timings: shared read=0.049
        ->  Bitmap Index Scan on idx_orders_customer  (cost=0.00..1.49 rows=13 width=0) (actual time=0.059..0.060 rows=17 loops=1)
              Index Cond: (customer_citizen_id = 3301)
              Buffers: shared hit=3 read=2
              I/O Timings: shared read=0.025
Planning Time: 0.458 ms
Execution Time: 2.972 ms
```

- Each Bitmap Index Scan builds a bitmap of matching row locations; `BitmapOr` combines two
  indexes for an `OR` that no single index can answer.
- The Bitmap Heap Scan then reads each needed heap page once, in physical order.
  `Heap Blocks: exact=N` means the bitmap fitted in `work_mem`; `lossy` blocks force a
  `Recheck Cond` on every row of the page.

### BRIN

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*), round(avg(reading_value), 2) AS avg_value
FROM lab.sensor_brin
WHERE reading_time >= '2025-12-25 00:00:00+00'
  AND reading_time <  '2025-12-26 00:00:00+00';
```

```text
Aggregate  (cost=2523.02..2523.04 rows=1 width=40) (actual time=0.504..0.504 rows=1 loops=1)
  Buffers: shared hit=137
  ->  Bitmap Heap Scan on sensor_brin  (cost=3.62..2517.22 rows=1160 width=6) (actual time=0.149..0.449 rows=1145 loops=1)
        Recheck Cond: ((reading_time >= '2025-12-25 00:00:00+00'::timestamp with time zone) AND (reading_time < '2025-12-26 00:00:00+00'::timestamp with time zone))
        Rows Removed by Index Recheck: 4398
        Heap Blocks: lossy=128
        Buffers: shared hit=137
        ->  Bitmap Index Scan on sensor_brin_time_brin  (cost=0.00..3.33 rows=5440 width=0) (actual time=0.046..0.046 rows=1280 loops=1)
              Index Cond: ((reading_time >= '2025-12-25 00:00:00+00'::timestamp with time zone) AND (reading_time < '2025-12-26 00:00:00+00'::timestamp with time zone))
              Buffers: shared hit=9
Planning Time: 0.277 ms
Execution Time: 0.588 ms
```

- BRIN stores one min/max summary per range of 128 pages, so the index is tiny, but it
  returns whole page ranges: expect `Rows Removed by Index Recheck` and a lossy bitmap.
- It only works when the column correlates with the physical row order (here the copy was
  written in `reading_time` order).

### GiST KNN (nearest neighbour)

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT name, category,
       round(ST_Distance(location_geom::geography,
                         ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)::geography)) AS metres
FROM geo.points_of_interest
ORDER BY location_geom <-> ST_SetSRID(ST_MakePoint(-96.80, 32.98), 4326)
LIMIT 5;
```

```text
Limit  (cost=0.14..66.18 rows=5 width=45) (actual time=32.763..32.992 rows=5 loops=1)
  Buffers: shared hit=427 read=30 dirtied=2
  I/O Timings: shared read=1.961
  ->  Index Scan using idx_pois_geom on points_of_interest  (cost=0.14..7924.94 rows=600 width=45) (actual time=32.758..32.986 rows=5 loops=1)
        Order By: (location_geom <-> '0101000020E610000033333333333358C03D0AD7A3707D4040'::geometry)
        Buffers: shared hit=427 read=30 dirtied=2
        I/O Timings: shared read=1.961
Planning Time: 22.328 ms
Execution Time: 33.186 ms
```

- `Order By: (location_geom <-> ...)` on the Index Scan means the GiST index returns rows
  nearest first; the Limit stops after five, so no Sort and no full scan.
- `<->` on geometry orders by planar distance in degrees; compute the reported distance with
  `::geography` (metres), as above.

### GIN full-text search

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT complaint_id, subject
FROM documents.complaint_records
WHERE search_vector @@ websearch_to_tsquery('english', 'water pressure');
```

```text
Bitmap Heap Scan on complaint_records  (cost=7.01..17.99 rows=10 width=42) (actual time=0.086..5.480 rows=150 loops=1)
  Recheck Cond: (search_vector @@ '''water'' & ''pressur'''::tsquery)
  Heap Blocks: exact=130
  Buffers: shared hit=135
  ->  Bitmap Index Scan on idx_complaints_search  (cost=0.00..7.01 rows=10 width=0) (actual time=0.057..0.058 rows=150 loops=1)
        Index Cond: (search_vector @@ '''water'' & ''pressur'''::tsquery)
        Buffers: shared hit=5
Planning Time: 1.465 ms
Execution Time: 5.553 ms
```

- The GIN index on `search_vector` answers `@@` through a Bitmap Index Scan; GIN can only
  produce bitmaps, never ordered output.
- The query must use the same text search configuration (`english`) as the stored vector,
  or the stems will not match.

## Join nodes

### Nested Loop

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_number, m.business_name, o.total_amount
FROM commerce.orders o
JOIN commerce.merchants m ON m.merchant_id = o.merchant_id
WHERE o.customer_citizen_id = 3301;
```

```text
Nested Loop  (cost=0.56..35.09 rows=13 width=47) (actual time=0.076..0.163 rows=17 loops=1)
  Buffers: shared hit=73
  ->  Index Scan using idx_orders_customer on orders o  (cost=0.29..15.92 rows=13 width=35) (actual time=0.072..0.141 rows=17 loops=1)
        Index Cond: (customer_citizen_id = 3301)
        Buffers: shared hit=22
  ->  Index Scan using merchants_pkey on merchants m  (cost=0.27..1.47 rows=1 width=28) (actual time=0.001..0.001 rows=1 loops=17)
        Index Cond: (merchant_id = o.merchant_id)
        Buffers: shared hit=51
Planning Time: 14.191 ms
Execution Time: 0.318 ms
```

- The outer side (orders of one customer) is small, so for each outer row the inner index
  is probed once: note `loops=` on the inner node and multiply.
- Nested Loop is the only join that can use a parameterised inner index scan; it degrades
  badly when the outer row count is underestimated.

### Hash Join

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT m.business_type, count(*) AS orders, round(sum(o.total_amount), 2) AS revenue
FROM commerce.orders o
JOIN commerce.merchants m ON m.merchant_id = o.merchant_id
GROUP BY m.business_type;
```

```text
HashAggregate  (cost=2867.61..2867.72 rows=7 width=44) (actual time=13.004..13.007 rows=7 loops=1)
  Group Key: m.business_type
  Batches: 1  Memory Usage: 24kB
  Buffers: shared hit=1849
  ->  Hash Join  (cost=32.25..2492.61 rows=50000 width=10) (actual time=1.487..9.319 rows=50000 loops=1)
        Hash Cond: (o.merchant_id = m.merchant_id)
        Buffers: shared hit=1849
        ->  Seq Scan on orders o  (cost=0.00..2328.00 rows=50000 width=14) (actual time=1.391..3.780 rows=50000 loops=1)
              Buffers: shared hit=1828
        ->  Hash  (cost=26.00..26.00 rows=500 width=12) (actual time=0.087..0.088 rows=500 loops=1)
              Buckets: 1024  Batches: 1  Memory Usage: 32kB
              Buffers: shared hit=21
              ->  Seq Scan on merchants m  (cost=0.00..26.00 rows=500 width=12) (actual time=0.006..0.057 rows=500 loops=1)
                    Buffers: shared hit=21
Planning Time: 0.667 ms
Execution Time: 13.085 ms
```

- The smaller input (merchants) is hashed; the larger one streams past it.
- `Buckets`, `Batches` and `Memory Usage` on the Hash node: `Batches: 1` means the hash
  table fitted in `work_mem` (times `hash_mem_multiplier`); more batches mean a spill.

### Merge Join

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.order_id, o.total_amount, p.amount
FROM commerce.orders o
JOIN commerce.payments p ON p.order_id = o.order_id
ORDER BY o.order_id
LIMIT 5;
```

```text
Limit  (cost=0.71..1.31 rows=5 width=20) (actual time=0.042..0.065 rows=5 loops=1)
  Buffers: shared hit=9 read=1
  I/O Timings: shared read=0.012
  ->  Merge Join  (cost=0.71..5895.46 rows=48734 width=20) (actual time=0.042..0.064 rows=5 loops=1)
        Merge Cond: (o.order_id = p.order_id)
        Buffers: shared hit=9 read=1
        I/O Timings: shared read=0.012
        ->  Index Scan using orders_pkey on orders o  (cost=0.29..3063.58 rows=50000 width=14) (actual time=0.017..0.036 rows=5 loops=1)
              Buffers: shared hit=7
        ->  Index Scan using idx_payments_order on payments p  (cost=0.29..2097.90 rows=48734 width=14) (actual time=0.022..0.022 rows=5 loops=1)
              Buffers: shared hit=2 read=1
              I/O Timings: shared read=0.012
Planning Time: 0.994 ms
Execution Time: 0.175 ms
```

- Both inputs arrive sorted on the join key (here from the primary key and
  `idx_payments_order`), so the join walks them in step and the output is already in
  `ORDER BY` order: the Limit can stop early.
- If either side needs an explicit Sort first, a Merge Join is usually only chosen for very
  large inputs or when the sorted order is needed anyway.

## Sorting and aggregation

### Sort: in memory vs spilled to disk

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, total_amount
FROM commerce.orders
ORDER BY total_amount DESC;
```

```text
Sort  (cost=6230.41..6355.41 rows=50000 width=14) (actual time=20.873..22.855 rows=50000 loops=1)
  Sort Key: total_amount DESC
  Sort Method: quicksort  Memory: 3099kB
  Buffers: shared hit=1831
  ->  Seq Scan on orders  (cost=0.00..2328.00 rows=50000 width=14) (actual time=1.105..6.577 rows=50000 loops=1)
        Buffers: shared hit=1828
Planning Time: 0.502 ms
Execution Time: 24.489 ms
```

```sql
BEGIN;
SET LOCAL work_mem = '1MB';
SET LOCAL max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, total_amount
FROM commerce.orders
ORDER BY total_amount DESC;
ROLLBACK;
```

```text
Sort  (cost=6732.66..6857.66 rows=50000 width=14) (actual time=38.334..45.522 rows=50000 loops=1)
  Sort Key: total_amount DESC
  Sort Method: external merge  Disk: 1240kB
  Buffers: shared hit=1831, temp read=155 written=157
  I/O Timings: temp read=0.191 write=2.441
  ->  Seq Scan on orders  (cost=0.00..2328.00 rows=50000 width=14) (actual time=1.115..9.138 rows=50000 loops=1)
        Buffers: shared hit=1828
Planning Time: 0.637 ms
Execution Time: 48.052 ms
```

- `Sort Method: quicksort  Memory: ...` means the sort fitted in `work_mem`.
- `Sort Method: external merge  Disk: ...` plus `temp read/written` in Buffers means it
  spilled. Raise `work_mem` for the session or query (not globally), or avoid the sort with
  an index that already delivers the order.
- `SET LOCAL` inside a transaction keeps the experiment from leaking into the session.

### Incremental Sort

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, order_date, total_amount
FROM commerce.orders
ORDER BY order_date, total_amount DESC
LIMIT 10;
```

```text
Limit  (cost=0.36..1.43 rows=10 width=22) (actual time=0.152..0.153 rows=10 loops=1)
  Buffers: shared hit=22 read=1
  I/O Timings: shared read=0.027
  ->  Incremental Sort  (cost=0.36..5331.91 rows=50000 width=22) (actual time=0.151..0.152 rows=10 loops=1)
        Sort Key: order_date, total_amount DESC
        Presorted Key: order_date
        Full-sort Groups: 1  Sort Method: quicksort  Average Memory: 25kB  Peak Memory: 25kB
        Buffers: shared hit=22 read=1
        I/O Timings: shared read=0.027
        ->  Index Scan using idx_orders_date on orders  (cost=0.29..3085.59 rows=50000 width=22) (actual time=0.060..0.098 rows=11 loops=1)
              Buffers: shared hit=12 read=1
              I/O Timings: shared read=0.027
Planning Time: 0.386 ms
Execution Time: 0.196 ms
```

- The index provides `order_date` order (`Presorted Key`), so only rows that share the
  same `order_date` need sorting, a group at a time; with a `LIMIT` it can stop after the
  first few groups instead of sorting 50,000 rows.

### HashAggregate vs GroupAggregate

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT processor, count(*) AS payments
FROM commerce.payments
GROUP BY processor;
```

```text
HashAggregate  (cost=1949.01..1949.04 rows=3 width=18) (actual time=29.846..29.848 rows=3 loops=1)
  Group Key: processor
  Batches: 1  Memory Usage: 24kB
  Buffers: shared hit=1 read=1217
  I/O Timings: shared read=21.155
  ->  Seq Scan on payments  (cost=0.00..1705.34 rows=48734 width=10) (actual time=0.008..24.196 rows=48734 loops=1)
        Buffers: shared hit=1 read=1217
        I/O Timings: shared read=21.155
Planning Time: 0.352 ms
Execution Time: 30.030 ms
```

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT order_id, count(*) AS items, sum(line_total) AS total
FROM commerce.order_items
WHERE order_id <= 1000
GROUP BY order_id;
```

```text
GroupAggregate  (cost=0.29..125.57 rows=2152 width=48) (actual time=0.042..0.756 rows=1000 loops=1)
  Group Key: order_id
  Buffers: shared hit=8 read=44
  I/O Timings: shared read=0.301
  ->  Index Scan using idx_order_items_order on order_items  (cost=0.29..82.23 rows=2191 width=14) (actual time=0.034..0.452 rows=2212 loops=1)
        Index Cond: (order_id <= 1000)
        Buffers: shared hit=8 read=44
        I/O Timings: shared read=0.301
Planning Time: 0.325 ms
Execution Time: 0.847 ms
```

- HashAggregate builds a hash table keyed by the group; good for few groups and unsorted
  input (`processor` has no index). Watch `Batches` and `Memory Usage`; above
  `work_mem * hash_mem_multiplier` it spills to disk in batches.
- GroupAggregate needs input sorted by the group key (here from the `order_id` index) and
  emits each group as soon as it is complete, using almost no memory.

### Memoize

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT t.trip_id, s.snapshots
FROM mobility.trip_segments t
CROSS JOIN LATERAL (
    SELECT count(*) AS snapshots
    FROM mobility.station_inventory i
    WHERE i.station_id = t.start_station_id
) s
WHERE t.start_time >= meta.as_of() - interval '1 day';
```

```text
Nested Loop  (cost=17.44..2422.88 rows=336 width=18) (actual time=0.090..4.515 rows=319 loops=1)
  Buffers: shared hit=467
  ->  Index Scan using idx_trips_time on trip_segments t  (cost=0.54..341.92 rows=336 width=18) (actual time=0.067..1.718 rows=319 loops=1)
        Index Cond: (start_time >= (meta.as_of() - '1 day'::interval))
        Buffers: shared hit=320
  ->  Memoize  (cost=16.90..16.91 rows=1 width=8) (actual time=0.008..0.008 rows=1 loops=319)
        Cache Key: t.start_station_id
        Cache Mode: binary
        Hits: 245  Misses: 74  Evictions: 0  Overflows: 0  Memory Usage: 9kB
        Buffers: shared hit=147
        ->  Aggregate  (cost=16.89..16.90 rows=1 width=8) (actual time=0.035..0.035 rows=1 loops=74)
              Buffers: shared hit=147
              ->  Index Only Scan using idx_inventory_station on station_inventory i  (cost=0.29..15.09 rows=720 width=0) (actual time=0.003..0.025 rows=282 loops=74)
                    Index Cond: (station_id = t.start_station_id)
                    Heap Fetches: 0
                    Buffers: shared hit=147
Planning Time: 0.907 ms
Execution Time: 4.600 ms
```

- The correlated `LATERAL` subquery must run once per outer row (`loops=319`); Memoize
  caches its result by `Cache Key`, so it actually ran only for the `Misses` (one per
  distinct station). `Hits` is the work saved.
- Memoize is chosen only when the planner expects few distinct keys relative to the outer
  rows; `Evictions` greater than 0 means the cache outgrew its share of `work_mem`.

## Parallel query

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM commerce.order_items oi
JOIN commerce.orders o USING (order_id)
WHERE o.tip_amount > 5;
```

```text
Finalize Aggregate  (cost=4665.72..4665.73 rows=1 width=8) (actual time=23.761..25.679 rows=1 loops=1)
  Buffers: shared hit=1968 read=218
  I/O Timings: shared read=3.486
  ->  Gather  (cost=4665.50..4665.71 rows=2 width=8) (actual time=23.255..25.675 rows=3 loops=1)
        Workers Planned: 2
        Workers Launched: 2
        Buffers: shared hit=1968 read=218
        I/O Timings: shared read=3.486
        ->  Partial Aggregate  (cost=3665.50..3665.51 rows=1 width=8) (actual time=19.831..19.833 rows=1 loops=3)
              Buffers: shared hit=1968 read=218
              I/O Timings: shared read=3.486
              ->  Parallel Hash Join  (cost=2246.81..3649.29 rows=6484 width=0) (actual time=6.290..19.437 rows=7142 loops=3)
                    Hash Cond: (oi.order_id = o.order_id)
                    Buffers: shared hit=1968 read=218
                    I/O Timings: shared read=3.486
                    ->  Parallel Index Only Scan using idx_order_items_order on order_items oi  (cost=0.29..1279.76 rows=46858 width=8) (actual time=0.030..9.280 rows=37486 loops=3)
                          Heap Fetches: 0
                          Buffers: shared hit=10 read=218
                          I/O Timings: shared read=3.486
                    ->  Parallel Hash  (cost=2195.65..2195.65 rows=4070 width=8) (actual time=5.420..5.421 rows=2271 loops=3)
                          Buckets: 8192  Batches: 1  Memory Usage: 384kB
                          Buffers: shared hit=1828
                          ->  Parallel Seq Scan on orders o  (cost=0.00..2195.65 rows=4070 width=8) (actual time=0.551..4.726 rows=2271 loops=3)
                                Filter: (tip_amount > '5'::numeric)
                                Rows Removed by Filter: 14396
                                Buffers: shared hit=1828
Planning Time: 0.763 ms
Execution Time: 25.744 ms
```

- `Gather` (or `Gather Merge` when order must be preserved) collects rows from
  `Workers Launched` background workers plus the leader.
- The work below Gather is split: `Parallel Seq Scan` and `Parallel Index Only Scan` hand
  out blocks to the processes, `Parallel Hash` builds one shared hash table, and the count
  is computed as `Partial Aggregate` per process and `Finalize Aggregate` above the Gather.
- Actual rows on parallel nodes are averaged per process and `loops` counts the leader too,
  so multiply by `loops` for the total. `Workers Planned` greater than `Workers Launched`
  means `max_parallel_workers` was exhausted at run time.

## Partition pruning

Uses the partitioned copy `lab.sensor_part` from the [setup](#setup-used-by-some-entries).

Plan-time pruning (literal bounds):

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM lab.sensor_part
WHERE reading_time >= '2025-12-24 00:00:00+00'
  AND reading_time <  '2025-12-25 00:00:00+00';
```

```text
Aggregate  (cost=523.80..523.81 rows=1 width=8) (actual time=1.526..1.526 rows=1 loops=1)
  Buffers: shared hit=1 read=138
  I/O Timings: shared read=0.885
  ->  Index Only Scan using sensor_part_2025_12_sensor_code_reading_time_idx on sensor_part_2025_12 sensor_part  (cost=0.29..520.92 rows=1151 width=0) (actual time=0.053..1.491 rows=1147 loops=1)
        Index Cond: ((reading_time >= '2025-12-24 00:00:00+00'::timestamp with time zone) AND (reading_time < '2025-12-25 00:00:00+00'::timestamp with time zone))
        Heap Fetches: 0
        Buffers: shared hit=1 read=138
        I/O Timings: shared read=0.885
Planning Time: 0.302 ms
Execution Time: 1.569 ms
```

Run-time pruning (the bound depends on a `STABLE` function, known only at executor start):

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM lab.sensor_part
WHERE reading_time >= meta.as_of() - interval '1 day';
```

```text
Aggregate  (cost=1241.40..1241.41 rows=1 width=8) (actual time=1.346..1.347 rows=1 loops=1)
  Buffers: shared hit=141
  ->  Append  (cost=0.54..1238.38 rows=1212 width=0) (actual time=0.066..1.288 rows=1152 loops=1)
        Buffers: shared hit=141
        Subplans Removed: 2
        ->  Index Only Scan using sensor_part_2025_12_sensor_code_reading_time_idx on sensor_part_2025_12 sensor_part_1  (cost=0.54..432.67 rows=1206 width=0) (actual time=0.066..1.217 rows=1152 loops=1)
              Index Cond: (reading_time >= (meta.as_of() - '1 day'::interval))
              Heap Fetches: 0
              Buffers: shared hit=141
Planning Time: 0.893 ms
Execution Time: 1.412 ms
```

- With literal bounds the pruned partitions never appear in the plan; only one partition
  is left here, so there is not even an `Append` node.
- With a `STABLE` expression all partitions are planned, then pruned when execution starts:
  look for `Subplans Removed: N`. Partitions that can only be pruned later, during execution
  (for example per outer row of a nested loop), stay in the plan as `(never executed)`.
- No pruning happens if the predicate is on an expression of the key (for example
  `date_trunc('day', reading_time) = ...`); keep the partition key bare.
- The scan uses the `(sensor_code, reading_time)` index although `sensor_code` is not
  constrained: reading the whole small index is still cheaper than the heap, because the
  query needs no other column (`Heap Fetches: 0`).

## CTE materialization

Since PostgreSQL 12 a CTE referenced once and without side effects is inlined into the outer
query. `MATERIALIZED` forces the old behaviour.

```sql
EXPLAIN (ANALYZE, BUFFERS)
WITH all_orders AS (
    SELECT * FROM commerce.orders
)
SELECT order_id, total_amount
FROM all_orders
WHERE order_id = 4242;
```

```text
Index Scan using orders_pkey on orders  (cost=0.29..2.51 rows=1 width=14) (actual time=0.066..0.067 rows=1 loops=1)
  Index Cond: (order_id = 4242)
  Buffers: shared hit=5 read=1
  I/O Timings: shared read=0.014
Planning Time: 0.347 ms
Execution Time: 0.558 ms
```

```sql
EXPLAIN (ANALYZE, BUFFERS)
WITH all_orders AS MATERIALIZED (
    SELECT * FROM commerce.orders
)
SELECT order_id, total_amount
FROM all_orders
WHERE order_id = 4242;
```

```text
CTE Scan on all_orders  (cost=2328.00..3453.00 rows=1 width=24) (actual time=18.549..18.785 rows=1 loops=1)
  Filter: (order_id = 4242)
  Rows Removed by Filter: 49999
  Buffers: shared hit=1828
  CTE all_orders
    ->  Seq Scan on orders  (cost=0.00..2328.00 rows=50000 width=191) (actual time=1.069..3.536 rows=50000 loops=1)
          Buffers: shared hit=1828
Planning Time: 0.623 ms
Execution Time: 19.766 ms
```

- Inlined: the `order_id` predicate is pushed into the scan and the primary key is used.
- Materialized: a `CTE Scan` over a `CTE` subplan that reads the whole table first; the
  filter is applied afterwards. Use `MATERIALIZED` deliberately, for example to evaluate an
  expensive or volatile expression once, or as an optimisation fence.

## Estimates vs actuals and extended statistics

The planner multiplies the selectivities of predicates on different columns as if they were
independent. In the sensor data every `air_quality` reading is measured in `AQI`, so the
second predicate removes nothing, but the planner still multiplies by its selectivity.

Before (copy of the readings with ordinary per-column statistics):

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM lab.sensor_stats
WHERE sensor_type = 'air_quality'
  AND unit_of_measure = 'AQI';
```

```text
Aggregate  (cost=3947.99..3948.00 rows=1 width=8) (actual time=14.711..14.712 rows=1 loops=1)
  Buffers: shared hit=2386
  ->  Seq Scan on sensor_stats  (cost=0.00..3936.53 rows=4582 width=0) (actual time=0.030..13.450 rows=21540 loops=1)
        Filter: ((sensor_type = 'air_quality'::mobility.sensor_type) AND ((unit_of_measure)::text = 'AQI'::text))
        Rows Removed by Filter: 81829
        Buffers: shared hit=2386
Planning Time: 0.292 ms
Execution Time: 14.793 ms
```

Teach the planner the functional dependency, re-analyze, and run the same query:

```sql
CREATE STATISTICS IF NOT EXISTS lab.sensor_stats_type_unit (dependencies)
    ON sensor_type, unit_of_measure FROM lab.sensor_stats;
ANALYZE lab.sensor_stats;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM lab.sensor_stats
WHERE sensor_type = 'air_quality'
  AND unit_of_measure = 'AQI';
```

```text
Aggregate  (cost=3990.12..3990.13 rows=1 width=8) (actual time=11.926..11.926 rows=1 loops=1)
  Buffers: shared hit=2386
  ->  Seq Scan on sensor_stats  (cost=0.00..3936.53 rows=21435 width=0) (actual time=0.011..10.846 rows=21540 loops=1)
        Filter: ((sensor_type = 'air_quality'::mobility.sensor_type) AND ((unit_of_measure)::text = 'AQI'::text))
        Rows Removed by Filter: 81829
        Buffers: shared hit=2386
Planning Time: 0.141 ms
Execution Time: 11.993 ms
```

What to look for:

- Compare `rows=` (estimate) with `actual ... rows=` on the scan node. Before: the estimate
  is about the product of the two selectivities. After: it matches the actual count.
- Here the misestimate does not change the plan, but the same error feeding a join decides
  between a Nested Loop and a Hash Join. Misestimates of 10x or more on a node that feeds a
  join are worth fixing.
- Inspect what was learned:

```sql
SELECT statistics_name, dependencies
FROM pg_stats_ext
WHERE statistics_schemaname = 'lab';
```

```text
    statistics_name     |               dependencies
------------------------+------------------------------------------
 sensor_stats_type_unit | {"3 => 8": 1.000000, "8 => 3": 1.000000}
```

- Other kinds: `ndistinct` (better `GROUP BY` estimates on column combinations) and `mcv`
  (most-common combinations, which also helps with `IN` lists and inequalities). Extended
  statistics are only collected by `ANALYZE`.

## Cleanup

```sql
DROP SCHEMA lab CASCADE;
```
