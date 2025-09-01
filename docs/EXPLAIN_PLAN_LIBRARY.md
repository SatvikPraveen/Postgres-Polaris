# EXPLAIN Plan Library - PostgreSQL Polaris

**Location**: `/docs/EXPLAIN_PLAN_LIBRARY.md`

Before/after plan snapshots with analysis for common optimization scenarios.

## 🎯 How to Use This Library

1. **Identify Problem**: Match your slow query pattern
2. **Compare Plans**: See before/after optimization
3. **Apply Fix**: Implement the suggested solution
4. **Measure Results**: Verify performance improvement

## 📊 Plan Reading Basics

### Key Metrics

- **Total Cost**: Higher = more expensive
- **Actual Time**: Wall-clock execution time
- **Rows**: Expected vs actual row counts
- **Buffers**: Memory/disk I/O usage

### Node Types (Most Common)

- **Seq Scan**: Full table scan (often bad for large tables)
- **Index Scan**: Using index (usually good)
- **Index Only Scan**: Best - no table access needed
- **Nested Loop**: Join algorithm (good for small datasets)
- **Hash Join**: Join algorithm (good for larger datasets)
- **Sort**: Ordering operation (expensive if can't fit in memory)

## 🔍 Optimization Scenarios

### Scenario 1: Sequential Scan → Index Scan

**Problem**: Slow customer lookup by email

```sql
-- Query
SELECT * FROM citizens WHERE email = 'alice.johnson@email.com';
```

**Before Optimization** (No Index):

```
Seq Scan on citizens  (cost=0.00..180.00 rows=1 width=120)
                     (actual time=2.156..2.158 rows=1 loops=1)
  Filter: (email = 'alice.johnson@email.com'::text)
  Rows Removed by Filter: 9999
  Buffers: shared hit=80
Planning Time: 0.123 ms
Execution Time: 2.184 ms
```

**Analysis**:

- **Problem**: Full table scan checking all 10,000 rows
- **Cost**: 2.18ms for single lookup
- **Buffers**: Reading 80 pages unnecessarily

**Solution**:

```sql
CREATE INDEX idx_citizens_email ON citizens(email);
```

**After Optimization** (With Index):

```
Index Scan using idx_citizens_email on citizens
                     (cost=0.29..8.30 rows=1 width=120)
                     (actual time=0.015..0.016 rows=1 loops=1)
  Index Cond: (email = 'alice.johnson@email.com'::text)
  Buffers: shared hit=3
Planning Time: 0.156 ms
Execution Time: 0.032 ms
```

**Results**:

- **Performance**: 68x faster (2.18ms → 0.032ms)
- **I/O**: 96% reduction (80 → 3 buffers)
- **Scalability**: O(log n) vs O(n)

---

### Scenario 2: Inefficient Join → Optimized Join

**Problem**: Customer order summary query

```sql
SELECT c.name, COUNT(o.order_id) as order_count, SUM(o.total_amount) as total_spent
FROM citizens c
LEFT JOIN orders o ON c.citizen_id = o.customer_id
GROUP BY c.citizen_id, c.name
ORDER BY total_spent DESC NULLS LAST;
```

**Before Optimization** (No Foreign Key Index):

```
Sort  (cost=1456.84..1481.84 rows=10000 width=64)
     (actual time=28.156..28.189 rows=10000 loops=1)
  Sort Key: (sum(o.total_amount)) DESC NULLS LAST
  Sort Method: quicksort  Memory: 1155kB
  Buffers: shared hit=180
  ->  HashAggregate  (cost=580.00..705.00 rows=10000 width=64)
                    (actual time=25.123..26.890 rows=10000 loops=1)
        Group Key: c.citizen_id, c.name
        Batches: 1  Memory Usage: 1297kB
        Buffers: shared hit=180
        ->  Hash Right Join  (cost=230.00..455.00 rows=10000 width=36)
                           (actual time=3.456..18.923 rows=10000 loops=1)
              Hash Cond: (o.customer_id = c.citizen_id)
              Buffers: shared hit=180
              ->  Seq Scan on orders o  (cost=0.00..155.00 rows=8500 width=16)
                                      (actual time=0.012..1.234 rows=8500 loops=1)
                    Buffers: shared hit=55
              ->  Hash  (cost=130.00..130.00 rows=10000 width=28)
                       (actual time=3.234..3.234 rows=10000 loops=1)
                    Buckets: 16384  Batches: 1  Memory Usage: 478kB
                    Buffers: shared hit=125
                    ->  Seq Scan on citizens c  (cost=0.00..130.00 rows=10000 width=28)
                                              (actual time=0.008..1.567 rows=10000 loops=1)
                          Buffers: shared hit=125
Planning Time: 0.456 ms
Execution Time: 28.789 ms
```

**Analysis**:

- **Problem**: Sequential scans on both tables, inefficient hash join
- **Cost**: 28.8ms total execution time
- **Memory**: High memory usage for hash table

**Solution**:

```sql
-- Add foreign key constraint (creates index automatically)
ALTER TABLE orders ADD CONSTRAINT fk_orders_customer
  FOREIGN KEY (customer_id) REFERENCES citizens(id);

-- Alternative: Manual index
-- CREATE INDEX idx_orders_customer_id ON orders(customer_id);
```

**After Optimization** (With FK Index):

```
Sort  (cost=856.84..881.84 rows=10000 width=64)
     (actual time=8.156..8.189 rows=10000 loops=1)
  Sort Key: (sum(o.total_amount)) DESC NULLS LAST
  Sort Method: quicksort  Memory: 1155kB
  Buffers: shared hit=145
  ->  HashAggregate  (cost=280.00..405.00 rows=10000 width=64)
                    (actual time=5.123..6.890 rows=10000 loops=1)
        Group Key: c.citizen_id, c.name
        Batches: 1  Memory Usage: 1297kB
        Buffers: shared hit=145
        ->  Hash Right Join  (cost=230.00..255.00 rows=10000 width=36)
                           (actual time=1.456..3.923 rows=10000 loops=1)
              Hash Cond: (o.customer_id = c.citizen_id)
              Buffers: shared hit=145
              ->  Index Scan using idx_orders_customer_id on orders o
                    (cost=0.29..155.00 rows=8500 width=16)
                    (actual time=0.012..0.834 rows=8500 loops=1)
                    Buffers: shared hit=20
              ->  Hash  (cost=130.00..130.00 rows=10000 width=28)
                       (actual time=1.234..1.234 rows=10000 loops=1)
                    Buckets: 16384  Batches: 1  Memory Usage: 478kB
                    Buffers: shared hit=125
                    ->  Seq Scan on citizens c  (cost=0.00..130.00 rows=10000 width=28)
                                              (actual time=0.008..0.567 rows=10000 loops=1)
                          Buffers: shared hit=125
Planning Time: 0.256 ms
Execution Time: 8.689 ms
```

**Results**:

- **Performance**: 3.3x faster (28.8ms → 8.7ms)
- **I/O**: 19% reduction (180 → 145 buffers)
- **Scalability**: Better join algorithm selection

---

### Scenario 3: Sort Spill → In-Memory Sort

**Problem**: Large result set sorting causing disk spills

```sql
SELECT t.*,
       ROW_NUMBER() OVER (PARTITION BY route_id ORDER BY departure_time) as trip_sequence
FROM trips t
WHERE trip_date >= '2024-01-01'
ORDER BY route_id, departure_time;
```

**Before Optimization** (Default work_mem):

```
WindowAgg  (cost=2456.89..2956.89 rows=25000 width=88)
          (actual time=156.234..189.567 rows=25000 loops=1)
  Buffers: shared hit=145, temp read=89 written=89
  ->  Sort  (cost=2456.89..2519.39 rows=25000 width=80)
           (actual time=156.123..167.890 rows=25000 loops=1)
        Sort Key: route_id, departure_time
        Sort Method: external merge  Disk: 1784kB
        Buffers: shared hit=145, temp read=89 written=89
        ->  Seq Scan on trips t  (cost=0.00..1205.00 rows=25000 width=80)
                                (actual time=0.012..18.234 rows=25000 loops=1)
              Filter: (trip_date >= '2024-01-01'::date)
              Rows Removed by Filter: 0
              Buffers: shared hit=145
Planning Time: 0.456 ms
Execution Time: 195.234 ms
```

**Analysis**:

- **Problem**: Sort spilling to disk ("external merge")
- **Cost**: 195ms with significant I/O
- **Memory**: work_mem too small for dataset

**Solution**:

```sql
-- Increase work_mem for this session
SET work_mem = '8MB';

-- Or create index to avoid sorting
CREATE INDEX idx_trips_route_date ON trips(route_id, departure_time);
```

**After Optimization** (Increased work_mem):

```
WindowAgg  (cost=1456.89..1956.89 rows=25000 width=88)
          (actual time=45.234..67.567 rows=25000 loops=1)
  Buffers: shared hit=145
  ->  Sort  (cost=1456.89..1519.39 rows=25000 width=80)
           (actual time=45.123..52.890 rows=25000 loops=1)
        Sort Key: route_id, departure_time
        Sort Method: quicksort  Memory: 3456kB
        Buffers: shared hit=145
        ->  Seq Scan on trips t  (cost=0.00..1205.00 rows=25000 width=80)
                                (actual time=0.012..15.234 rows=25000 loops=1)
              Filter: (trip_date >= '2024-01-01'::date)
              Rows Removed by Filter: 0
              Buffers: shared hit=145
Planning Time: 0.256 ms
Execution Time: 72.234 ms
```

**Results**:

- **Performance**: 2.7x faster (195ms → 72ms)
- **I/O**: Eliminated disk spills
- **Memory**: In-memory quicksort

---

### Scenario 4: Missing Partial Index

**Problem**: Queries on active records only

```sql
-- 90% of orders are 'completed', only 10% are 'pending' or 'processing'
SELECT COUNT(*) FROM orders WHERE status IN ('pending', 'processing');
```

**Before Optimization** (Full Table Index):

```
Aggregate  (cost=455.00..455.01 rows=1 width=8)
          (actual time=12.456..12.457 rows=1 loops=1)
  Buffers: shared hit=85
  ->  Bitmap Heap Scan on orders  (cost=89.25..430.00 rows=1000 width=0)
                                 (actual time=1.234..11.567 rows=850 loops=1)
        Recheck Cond: (status = ANY ('{pending,processing}'::text[]))
        Heap Blocks: exact=45
        Buffers: shared hit=85
        ->  Bitmap Index Scan on idx_orders_status  (cost=0.00..89.00 rows=1000 width=0)
                                                   (actual time=1.156..1.156 rows=850 loops=1)
              Index Cond: (status = ANY ('{pending,processing}'::text[]))
              Buffers: shared hit=40
Planning Time: 0.256 ms
Execution Time: 12.678 ms
```

**Analysis**:

- **Problem**: Index includes all status values, including 90% irrelevant 'completed'
- **Size**: Index is 10x larger than needed
- **Performance**: Still reasonable but could be better

**Solution**:

```sql
-- Drop full index, create partial index
DROP INDEX idx_orders_status;
CREATE INDEX idx_orders_active_status ON orders(status)
  WHERE status IN ('pending', 'processing', 'cancelled');
```

**After Optimization** (Partial Index):

```
Aggregate  (cost=245.00..245.01 rows=1 width=8)
          (actual time=2.456..2.457 rows=1 loops=1)
  Buffers: shared hit=15
  ->  Index Scan using idx_orders_active_status on orders
        (cost=0.29..220.00 rows=1000 width=0)
        (actual time=0.034..1.567 rows=850 loops=1)
        Index Cond: (status = ANY ('{pending,processing}'::text[]))
        Buffers: shared hit=15
Planning Time: 0.156 ms
Execution Time: 2.678 ms
```

**Results**:

- **Performance**: 4.7x faster (12.7ms → 2.7ms)
- **I/O**: 82% reduction (85 → 15 buffers)
- **Storage**: 90% smaller index

---

### Scenario 5: JSONB Query Optimization

**Problem**: Searching documents by nested JSON properties

```sql
SELECT id, data->>'title' as title
FROM documents
WHERE data->>'type' = 'complaint'
  AND data->>'category' = 'noise'
  AND data->>'priority' = 'high';
```

**Before Optimization** (No JSONB Index):

```
Seq Scan on documents  (cost=0.00..456.00 rows=1 width=64)
                      (actual time=18.456..45.234 rows=15 loops=1)
  Filter: (((data ->> 'type'::text) = 'complaint'::text) AND
           ((data ->> 'category'::text) = 'noise'::text) AND
           ((data ->> 'priority'::text) = 'high'::text))
  Rows Removed by Filter: 1985
  Buffers: shared hit=125
Planning Time: 0.234 ms
Execution Time: 45.456 ms
```

**Analysis**:

- **Problem**: Full table scan with complex JSON filtering
- **Selectivity**: Only 15 rows match out of 2000
- **Cost**: High CPU for JSON parsing

**Solution**:

```sql
-- Create GIN index for JSONB queries
CREATE INDEX idx_documents_gin ON documents USING GIN(data);

-- Or expression index for specific paths
CREATE INDEX idx_documents_type ON documents((data->>'type'));
CREATE INDEX idx_documents_category ON documents((data->>'category'));
```

**After Optimization** (GIN Index):

```
Bitmap Heap Scan on documents  (cost=45.25..89.30 rows=15 width=64)
                              (actual time=1.234..2.567 rows=15 loops=1)
  Recheck Cond: ((data @> '{"type":"complaint"}'::jsonb) AND
                 (data @> '{"category":"noise"}'::jsonb) AND
                 (data @> '{"priority":"high"}'::jsonb))
  Heap Blocks: exact=12
  Buffers: shared hit=18
  ->  Bitmap Index Scan on idx_documents_gin  (cost=0.00..45.24 rows=15 width=0)
                                             (actual time=1.156..1.156 rows=15 loops=1)
        Index Cond: ((data @> '{"type":"complaint"}'::jsonb) AND
                     (data @> '{"category":"noise"}'::jsonb) AND
                     (data @> '{"priority":"high"}'::jsonb))
        Buffers: shared hit=6
Planning Time: 0.456 ms
Execution Time: 3.234 ms
```

**Results**:

- **Performance**: 14x faster (45.5ms → 3.2ms)
- **I/O**: 86% reduction (125 → 18 buffers)
- **CPU**: Efficient GIN index scanning

---

## 🛠️ Optimization Toolkit

### Quick Diagnostics

```sql
-- Find slow queries
SELECT query, mean_exec_time, calls, total_exec_time
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;

-- Check index usage
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
WHERE idx_scan = 0;

-- Buffer cache hit ratio
SELECT datname,
       round(blks_hit*100.0/(blks_hit+blks_read), 2) as cache_hit_ratio
FROM pg_stat_database
WHERE datname = current_database();
```

### Performance Settings

```sql
-- Query tuning parameters
SET work_mem = '256MB';           -- Sort/hash operations
SET maintenance_work_mem = '1GB'; -- Index creation, VACUUM
SET random_page_cost = 1.1;       -- SSD optimization
SET effective_cache_size = '8GB'; -- Available OS cache
```

### Index Recommendations

```sql
-- Find missing indexes (requires pg_stat_statements)
SELECT schemaname, tablename, attname, n_distinct, correlation
FROM pg_stats
WHERE schemaname = 'public'
  AND n_distinct > 10
  AND correlation < 0.1
ORDER BY schemaname, tablename;
```

---

## 📈 Performance Patterns

### Good Plans Look Like

- **Index Scans**: Instead of Sequential Scans
- **Index Only Scans**: Best case - no table access
- **Nested Loop**: For small result sets
- **Hash Join**: For larger joins
- **In-Memory Sorts**: quicksort vs external merge

### Red Flags

- **Sequential Scans**: On large tables
- **External Merge**: Sort spilling to disk
- **High Buffer Counts**: Excessive I/O
- **Actual vs Estimated**: Large row count mismatches

### Cost Interpretation

- **< 100**: Very fast, single-digit milliseconds
- **100-1000**: Fast, good for OLTP
- **1000-10000**: Moderate, acceptable for reports
- **> 10000**: Slow, needs optimization

---

**Next**: Apply these patterns to your queries and measure the improvements!
