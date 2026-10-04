-- Analytical path: 30-day revenue and order count per neighbourhood and
-- business type for a random window in the year. Scans and aggregates
-- several thousand rows per call; sensitive to work_mem and parallelism.
\set d random(30, 360)
SELECT n.neighborhood_name, m.business_type,
       count(*) AS orders, sum(o.total_amount) AS revenue
FROM commerce.orders o
JOIN commerce.merchants m USING (merchant_id)
JOIN geo.neighborhood_boundaries n
  ON n.neighborhood_id = ('1' || right(m.zip_code, 2))::int - 100
WHERE o.order_date >= meta.as_of() - make_interval(days => :d)
  AND o.order_date <  meta.as_of() - make_interval(days => :d - 30)
GROUP BY ROLLUP (n.neighborhood_name, m.business_type)
ORDER BY revenue DESC NULLS LAST
LIMIT 20;
