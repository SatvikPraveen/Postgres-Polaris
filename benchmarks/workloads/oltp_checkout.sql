-- OLTP write path: one order with two line items and a payment, as a single
-- transaction. Exercises FK checks, the order-totals trigger, sequences and
-- WAL. Customer and merchant ids are uniform over the scale-1 key space.
\set cid random(1, 10000)
\set mid random(1, 500)
\set p1 random(100, 5000)
\set p2 random(100, 5000)
BEGIN;
INSERT INTO commerce.orders (merchant_id, customer_citizen_id, order_number, order_date, status)
VALUES (:mid, :cid, 'BENCH-' || :client_id || '-' || nextval('commerce.orders_order_id_seq'), meta.as_of(), 'confirmed')
RETURNING order_id \gset
INSERT INTO commerce.order_items (order_id, item_name, unit_price, quantity, line_total)
VALUES (:order_id, 'bench item a', :p1 / 100.0, 1, :p1 / 100.0),
       (:order_id, 'bench item b', :p2 / 100.0, 2, :p2 / 50.0);
INSERT INTO commerce.payments (order_id, payment_method, amount, status, processed_at)
SELECT order_id, 'credit_card', total_amount, 'completed', meta.as_of()
FROM commerce.orders WHERE order_id = :order_id;
COMMIT;
