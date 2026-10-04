# Sample Queries

Verified queries for exploring the Polaris City base dataset (`sql/build.sql`, scale 1,
seed 42). Every query below was executed against a fresh copy of the base database; the
output under each one is pasted from that run. They need only the base dataset, no module
objects.

Conventions used throughout:

- The dataset's "now" is `meta.as_of()` (2025-12-31 23:59:59 UTC). Recency filters use it,
  never `now()` or `CURRENT_DATE`.
- Citizens' homes are points in `civics.citizens.home_geom`; neighbourhoods are polygons in
  `geo.neighborhood_boundaries`. Geometries are SRID 4326; distances use `::geography`
  (metres).
- Timestamps are `timestamptz`; hour-of-day and calendar logic is done in UTC.

The small CSV/JSON files in this directory are separate hand-written samples used by module
09 (`sql/09_data_movement/copy_bulk_operations.sql`), not the base dataset.

## Dataset

### 1. Dataset fingerprint and row counts

Purpose: confirm which build you are querying before comparing results.

```sql
SELECT generator_version, scale, seed, as_of,
       (row_counts ->> 'civics.citizens')::int   AS citizens,
       (row_counts ->> 'commerce.orders')::int   AS orders,
       (row_counts ->> 'mobility.sensor_readings')::int AS sensor_readings
FROM meta.dataset;
```

```text
 generator_version | scale | seed |         as_of          | citizens | orders | sensor_readings
-------------------+-------+------+------------------------+----------+--------+-----------------
 2.1.0             |     1 |   42 | 2025-12-31 23:59:59+00 |    10000 |  50000 |          103369
```

### 2. Planted effects

Purpose: list the generative parameters that analyses can try to recover.

```sql
SELECT effect, domain, true_value
FROM meta.planted_effects
ORDER BY domain, effect;
```

```text
                effect                |  domain   | true_value
--------------------------------------+-----------+------------
 turnout_age_slope                    | civics    |      0.035
 turnout_income_slope                 | civics    |       0.40
 merchant_popularity_zipf_exponent    | commerce  |       1.10
 order_amount_outlier_rate            | commerce  |      0.002
 order_growth_exponent                | commerce  |       0.85
 complaint_resolution_income_gradient | documents |      -0.25
 peak_hour_bus_delay_ratio            | mobility  |        3.0
 peak_hour_road_speed_factor          | mobility  |       0.70
 sensor_level_shift_windows           | mobility  |          3
 sensor_point_anomaly_rate            | mobility  |      0.006
```

## Civics

### 3. Citizens by status

Purpose: see the status mix of the citizen registry.

```sql
SELECT status, count(*) AS citizens,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM civics.citizens
GROUP BY status
ORDER BY status;
```

```text
  status   | citizens | pct
-----------+----------+------
 active    |     9598 | 96.0
 inactive  |      257 |  2.6
 suspended |       98 |  1.0
 deceased  |       47 |  0.5
```

### 4. Turnout by election

Purpose: participation records per election, as a share of citizens.

```sql
SELECT election_name, election_date, count(*) AS voters,
       round(100.0 * count(*) / (SELECT count(*) FROM civics.citizens), 1) AS pct_of_citizens
FROM civics.voting_records
GROUP BY election_name, election_date
ORDER BY election_date;
```

```text
     election_name      | election_date | voters | pct_of_citizens
------------------------+---------------+--------+-----------------
 Municipal General 2023 | 2023-05-06    |   3356 |            33.6
 Bond Referendum 2023   | 2023-11-07    |   2169 |            21.7
 School Board 2024      | 2024-05-04    |   1921 |            19.2
 Municipal General 2025 | 2025-05-03    |   3822 |            38.2
```

### 5. Permit processing time by type

Purpose: median and 90th-percentile days from application to approval.

```sql
SELECT permit_type,
       count(*) AS approved,
       round(percentile_cont(0.5) WITHIN GROUP (
           ORDER BY extract(epoch FROM approval_date - application_date) / 86400)::numeric, 1) AS median_days,
       round(percentile_cont(0.9) WITHIN GROUP (
           ORDER BY extract(epoch FROM approval_date - application_date) / 86400)::numeric, 1) AS p90_days
FROM civics.permit_applications
WHERE approval_date IS NOT NULL
GROUP BY permit_type
ORDER BY median_days DESC;
```

```text
 permit_type | approved | median_days | p90_days
-------------+----------+-------------+----------
 building    |      827 |         8.0 |     22.0
 business    |      457 |         7.0 |     21.0
 event       |      446 |         7.0 |     21.5
 parking     |      358 |         7.0 |     23.0
 street      |      233 |         6.0 |     20.8
```

### 6. Overdue tax balances

Purpose: outstanding amounts on unpaid taxes past their due date, by tax type.

```sql
SELECT tax_type,
       count(*)                                AS overdue_items,
       round(sum(amount_due - amount_paid), 2) AS balance_owed
FROM civics.tax_payments
WHERE payment_status <> 'paid'
  AND due_date < meta.as_of()::date
GROUP BY tax_type
ORDER BY balance_owed DESC;
```

```text
 tax_type | overdue_items | balance_owed
----------+---------------+--------------
 property |          1195 |   5361391.34
 vehicle  |           839 |    125325.69
```

## Commerce

### 7. Delivered revenue in the last 30 days

Purpose: headline revenue KPI anchored on the dataset clock.

```sql
SELECT count(*)                         AS orders,
       round(sum(total_amount), 2)      AS revenue,
       round(avg(total_amount), 2)      AS avg_order_value
FROM commerce.orders
WHERE status = 'delivered'
  AND order_date >= meta.as_of() - interval '30 days';
```

```text
 orders |  revenue  | avg_order_value
--------+-----------+-----------------
   3952 | 800669.91 |          202.60
```

### 8. Quarterly order growth

Purpose: order volume per quarter of 2025 (the generator plants growth over the year).

```sql
SELECT date_trunc('quarter', order_date AT TIME ZONE 'UTC')::date AS quarter,
       count(*) AS orders
FROM commerce.orders
WHERE order_date >= '2025-01-01 00:00:00+00'
GROUP BY 1
ORDER BY 1;
```

```text
  quarter   | orders
------------+--------
 2025-01-01 |   9807
 2025-04-01 |  12442
 2025-07-01 |  13611
 2025-10-01 |  14017
```

### 9. Top merchants by delivered revenue

Purpose: the five largest merchants and their share of all delivered revenue.

```sql
SELECT m.business_name, m.business_type,
       round(sum(o.total_amount), 2) AS revenue,
       round(100 * sum(o.total_amount) / sum(sum(o.total_amount)) OVER (), 2) AS pct_of_total
FROM commerce.orders o
JOIN commerce.merchants m USING (merchant_id)
WHERE o.status = 'delivered'
GROUP BY m.merchant_id, m.business_name, m.business_type
ORDER BY revenue DESC
LIMIT 5;
```

```text
      business_name      | business_type |  revenue   | pct_of_total
-------------------------+---------------+------------+--------------
 Liberty Systems #1      | technology    | 3878903.93 |        40.73
 Pioneer Salon #339      | service       |  414039.35 |         4.35
 Riverside Cleaners #258 | service       |  289773.98 |         3.04
 Lone Star Systems #205  | technology    |  260653.45 |         2.74
 Northgate Systems #43   | technology    |  226542.62 |         2.38
```

### 10. Payment method mix and failure rate

Purpose: how customers pay and how often each method fails.

```sql
SELECT payment_method,
       count(*) AS payments,
       round(100.0 * count(*) FILTER (WHERE status = 'failed') / count(*), 2) AS failed_pct
FROM commerce.payments
GROUP BY payment_method
ORDER BY payments DESC;
```

```text
 payment_method | payments | failed_pct
----------------+----------+------------
 credit_card    |    21916 |       1.54
 debit_card     |    12141 |       1.49
 digital_wallet |     8799 |       1.33
 cash           |     3889 |       1.70
 bank_transfer  |     1528 |       1.37
 check          |      461 |       0.65
```

### 11. Repeat customers

Purpose: distribution of customers by number of orders placed.

```sql
SELECT CASE WHEN n = 1 THEN '1'
            WHEN n <= 5 THEN '2-5'
            WHEN n <= 10 THEN '6-10'
            ELSE '11+' END AS orders_per_customer,
       count(*) AS customers
FROM (SELECT customer_citizen_id, count(*) AS n
      FROM commerce.orders
      GROUP BY customer_citizen_id) c
GROUP BY 1
ORDER BY min(n);
```

```text
 orders_per_customer | customers
---------------------+-----------
 1                   |       358
 2-5                 |      5792
 6-10                |      3593
 11+                 |       181
```

## Mobility

### 12. Trips by mode

Purpose: segment count, median distance and median speed per travel mode.

```sql
SELECT trip_mode,
       count(*) AS segments,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY distance_km)::numeric, 2)       AS median_km,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY average_speed_kmh)::numeric, 1) AS median_kmh
FROM mobility.trip_segments
GROUP BY trip_mode
ORDER BY segments DESC;
```

```text
 trip_mode | segments | median_km | median_kmh
-----------+----------+-----------+------------
 car       |    15003 |      9.00 |       37.0
 walking   |     9386 |      1.07 |        4.8
 bus       |     8953 |      5.97 |       20.4
 cycling   |     5035 |      3.47 |       15.0
 rideshare |     4445 |      6.93 |       33.6
 rail      |     3971 |     12.02 |       38.1
 scooter   |     3559 |      2.03 |       14.0
 other     |     1556 |      3.90 |       20.1
```

### 13. Hourly trip profile on weekdays

Purpose: the commute double peak in weekday trip starts (UTC hours), top six hours.

```sql
SELECT extract(hour FROM start_time AT TIME ZONE 'UTC')::int AS hour_utc,
       count(*) AS segments
FROM mobility.trip_segments
WHERE extract(isodow FROM start_time AT TIME ZONE 'UTC') <= 5
GROUP BY 1
ORDER BY segments DESC
LIMIT 6;
```

```text
 hour_utc | segments
----------+----------
       17 |     3615
        8 |     3608
        7 |     3331
       18 |     3182
       16 |     2951
        9 |     2048
```

### 14. Busiest stations in the last 7 days

Purpose: stations with the most departing segments in the final week of data.

```sql
SELECT s.station_name, s.station_type, count(*) AS departures
FROM mobility.trip_segments t
JOIN mobility.stations s ON s.station_id = t.start_station_id
WHERE t.start_time >= meta.as_of() - interval '7 days'
GROUP BY s.station_id, s.station_name, s.station_type
ORDER BY departures DESC
LIMIT 5;
```

```text
    station_name     | station_type | departures
---------------------+--------------+------------
 Oak Hill Rail 4     | rail         |         16
 Market Row Rail 11  | rail         |         16
 Civic Center Rail 9 | rail         |         16
 Bluebonnet Rail 5   | rail         |         14
 Bluebonnet Rail 12  | rail         |         14
```

### 15. Latest reading per sensor type

Purpose: most recent value of each sensor, using `DISTINCT ON` and the `(sensor_code, reading_time DESC)` index.

```sql
SELECT DISTINCT ON (sensor_type) sensor_type, sensor_code, reading_time, reading_value, unit_of_measure
FROM mobility.sensor_readings
ORDER BY sensor_type, reading_time DESC, sensor_code;
```

```text
   sensor_type   | sensor_code |      reading_time      | reading_value | unit_of_measure
-----------------+-------------+------------------------+---------------+-----------------
 traffic_counter | TRF-001     | 2025-12-31 23:00:00+00 |      117.5975 | vehicles/hour
 air_quality     | AQI-001     | 2025-12-31 23:00:00+00 |       51.3078 | AQI
 noise           | NOI-001     | 2025-12-31 23:00:00+00 |       44.4932 | dB
 speed           | SPD-001     | 2025-12-31 23:00:00+00 |       35.0481 | mph
 weather         | WTH-001     | 2025-12-31 23:00:00+00 |       46.9189 | temperature_f
```

### 16. Station availability snapshot

Purpose: average share of capacity available per station type in the last 24 hours of inventory snapshots.

```sql
SELECT s.station_type,
       count(DISTINCT s.station_id) AS stations,
       round(100 * avg(i.available_count::numeric / nullif(s.total_capacity, 0)), 1) AS avg_available_pct
FROM mobility.station_inventory i
JOIN mobility.stations s USING (station_id)
WHERE i.recorded_at >= meta.as_of() - interval '24 hours'
GROUP BY s.station_type
ORDER BY avg_available_pct;
```

```text
 station_type | stations | avg_available_pct
--------------+----------+-------------------
 bike_share   |       40 |              54.3
 scooter      |       20 |              54.9
```

## Geo

### 17. Residents per neighbourhood

Purpose: point-in-polygon assignment of citizens, with density per km2.

```sql
SELECT n.neighborhood_name,
       count(c.citizen_id) AS residents,
       round(count(c.citizen_id) / n.area_sq_km, 1) AS residents_per_km2
FROM geo.neighborhood_boundaries n
LEFT JOIN civics.citizens c ON ST_Contains(n.boundary_geom, c.home_geom)
GROUP BY n.neighborhood_id, n.neighborhood_name, n.area_sq_km
ORDER BY residents DESC
LIMIT 5;
```

```text
 neighborhood_name | residents | residents_per_km2
-------------------+-----------+-------------------
 Cottonwood        |       771 |             232.4
 Bluebonnet        |       730 |             220.1
 Civic Center      |       666 |             200.7
 Station District  |       649 |             195.6
 Brookhaven        |       567 |             171.0
```

### 18. Nearest park to each of three citizens

Purpose: KNN search with a GiST index, distance reported in metres.

```sql
SELECT c.citizen_id, p.name AS nearest_park, p.metres
FROM civics.citizens c
CROSS JOIN LATERAL (
    SELECT poi.name,
           round(ST_Distance(poi.location_geom::geography, c.home_geom::geography)) AS metres
    FROM geo.points_of_interest poi
    WHERE poi.category = 'park'
    ORDER BY poi.location_geom <-> c.home_geom
    LIMIT 1
) p
WHERE c.citizen_id IN (1, 2, 3)
ORDER BY c.citizen_id;
```

```text
 citizen_id |      nearest_park       | metres
------------+-------------------------+--------
          1 | Arts District Park 510  |    122
          2 | Medical Center Park 401 |   1178
          3 | Live Oak Park 421       |    498
```

### 19. Road network by type

Purpose: length and condition of the road network, with lengths measured on the spheroid.

```sql
SELECT road_type,
       count(*) AS segments,
       round((sum(ST_Length(segment_geom::geography)) / 1000)::numeric, 1) AS length_km,
       round(avg(condition_rating), 2) AS avg_condition
FROM geo.road_segments
GROUP BY road_type
ORDER BY length_km DESC;
```

```text
  road_type  | segments | length_km | avg_condition
-------------+----------+-----------+---------------
 residential |      576 |     223.1 |          3.06
 arterial    |      269 |     103.6 |          2.99
 collector   |      222 |      85.6 |          2.90
```

## Documents

### 20. Complaint resolution by category

Purpose: resolution rate and median days to resolve, per complaint category.

```sql
SELECT category,
       count(*) AS complaints,
       round(100.0 * count(resolved_at) / count(*), 1) AS resolved_pct,
       round(percentile_cont(0.5) WITHIN GROUP (
           ORDER BY extract(epoch FROM resolved_at - submitted_at) / 86400)::numeric, 1) AS median_days
FROM documents.complaint_records
GROUP BY category
ORDER BY median_days DESC;
```

```text
 category  | complaints | resolved_pct | median_days
-----------+------------+--------------+-------------
 roads     |       1212 |         92.8 |         9.8
 other     |        164 |         96.3 |         5.2
 graffiti  |        512 |         95.3 |         4.8
 noise     |       1059 |         94.7 |         4.2
 utilities |        689 |         95.6 |         2.7
 trash     |        675 |         95.0 |         2.4
 parking   |        539 |         95.0 |         2.2
 animals   |        150 |         96.0 |         1.6
```

### 21. Full-text search over complaints

Purpose: ranked search with the stored `english` tsvector and a highlighted snippet.

```sql
SELECT complaint_number,
       ts_headline('english', description, q, 'MaxWords=12, MinWords=5') AS snippet,
       round(ts_rank(search_vector, q)::numeric, 3) AS rank
FROM documents.complaint_records,
     websearch_to_tsquery('english', 'pothole OR "damaged pavement"') AS q
WHERE search_vector @@ q
ORDER BY rank DESC, complaint_id
LIMIT 3;
```

```text
 complaint_number |                       snippet                       | rank
------------------+-----------------------------------------------------+-------
 CMP-2025-000016  | <b>Damaged</b> <b>pavement</b> reported by resident | 0.051
 CMP-2025-000019  | <b>Damaged</b> <b>pavement</b> reported by resident | 0.051
 CMP-2025-000038  | <b>Damaged</b> <b>pavement</b> reported by resident | 0.051
```

### 22. Querying JSONB metadata

Purpose: road complaints by hazard type, using the GIN-indexable containment operator.

```sql
SELECT metadata ->> 'hazard_type' AS hazard_type, count(*) AS complaints
FROM documents.complaint_records
WHERE metadata @> '{"category": "roads"}'
GROUP BY 1
ORDER BY complaints DESC;
```

```text
    hazard_type    | complaints
-------------------+------------
 damaged pavement  |        322
 pothole           |        319
 missing road sign |        287
 faded crosswalk   |        284
```

### 23. Published policies by department

Purpose: count of published policy documents and their most frequent tag per department.

```sql
SELECT p.department,
       count(DISTINCT p.policy_id)             AS published,
       mode() WITHIN GROUP (ORDER BY t.tag)    AS most_common_tag
FROM documents.policy_documents p
LEFT JOIN LATERAL unnest(p.tags) AS t(tag) ON true
WHERE p.status = 'published'
GROUP BY p.department
ORDER BY published DESC, p.department
LIMIT 5;
```

```text
   department   | published | most_common_tag
----------------+-----------+-----------------
 Public Works   |        15 | pw
 Finance        |        14 | fn
 Transportation |        14 | tr
 Health         |        12 | hl
 Planning       |        12 | pl
```

## Cross-domain

### 24. Peak versus off-peak transit delay

Purpose: recover the planted 3x peak delay ratio for buses and rail.

```sql
SELECT round(avg(delay_minutes) FILTER (WHERE is_peak), 2)     AS peak_min,
       round(avg(delay_minutes) FILTER (WHERE NOT is_peak), 2) AS offpeak_min,
       round(avg(delay_minutes) FILTER (WHERE is_peak)
             / avg(delay_minutes) FILTER (WHERE NOT is_peak), 2) AS ratio
FROM (SELECT delay_minutes,
             extract(isodow FROM start_time AT TIME ZONE 'UTC') <= 5
             AND (extract(hour FROM start_time AT TIME ZONE 'UTC') BETWEEN 7 AND 8
                  OR extract(hour FROM start_time AT TIME ZONE 'UTC') BETWEEN 16 AND 18) AS is_peak
      FROM mobility.trip_segments
      WHERE trip_mode IN ('bus', 'rail')) t;
```

```text
 peak_min | offpeak_min | ratio
----------+-------------+-------
     6.02 |        1.97 |  3.06
```

### 25. Complaint resolution time by neighbourhood income

Purpose: median days to resolve a complaint for low-, middle- and high-income neighbourhoods (the generator plants slower resolution in poorer areas).

```sql
WITH nb AS (
    SELECT neighborhood_id, median_income,
           ntile(3) OVER (ORDER BY median_income) AS income_tercile
    FROM geo.neighborhood_boundaries
)
SELECT nb.income_tercile,
       min(nb.median_income) AS min_income,
       max(nb.median_income) AS max_income,
       count(*)              AS resolved_complaints,
       round(percentile_cont(0.5) WITHIN GROUP (
           ORDER BY extract(epoch FROM c.resolved_at - c.submitted_at) / 86400)::numeric, 1) AS median_days
FROM documents.complaint_records c
JOIN nb USING (neighborhood_id)
WHERE c.resolved_at IS NOT NULL
GROUP BY nb.income_tercile
ORDER BY nb.income_tercile;
```

```text
 income_tercile | min_income | max_income | resolved_complaints | median_days
----------------+------------+------------+---------------------+-------------
              1 |   31800.00 |   47000.00 |                1594 |         4.3
              2 |   49400.00 |   66500.00 |                1758 |         4.9
              3 |   67600.00 |  113500.00 |                1378 |         2.9
```

The gap is partly confounded by category mix; `sql/16_capstones/citywide_analytics_dashboard.sql`
estimates the planted gradient with category fixed effects.
