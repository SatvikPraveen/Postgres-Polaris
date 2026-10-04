-- Read path: a citizen profile plus their five most recent orders.
-- Index-only/PK lookups; measures executor and protocol overhead.
\set cid random(1, 10000)
SELECT c.citizen_id, c.first_name, c.last_name, c.zip_code,
       o.order_id, o.order_date, o.total_amount
FROM civics.citizens c
LEFT JOIN LATERAL (
    SELECT order_id, order_date, total_amount
    FROM commerce.orders
    WHERE customer_citizen_id = c.citizen_id
    ORDER BY order_date DESC
    LIMIT 5
) o ON true
WHERE c.citizen_id = :cid;
