-- Location: /examples/analytics_showcase.sql
-- Business intelligence patterns and analytics demonstration

SELECT '📊 Analytics Showcase - Business Intelligence Patterns' as title;

-- 1. Sales Funnel Analysis
SELECT 'Demo 1: Sales Funnel Analysis' as demo;

WITH sales_funnel AS (
    SELECT
        m.category,
        COUNT(DISTINCT c.citizen_id) as potential_customers,
        COUNT(DISTINCT o.customer_id) as actual_customers,
        COUNT(o.order_id) as total_orders,
        COUNT(CASE WHEN o.status = 'completed' THEN o.order_id END) as completed_orders,
        SUM(CASE WHEN o.status = 'completed' THEN o.total_amount ELSE 0 END) as revenue
    FROM merchants m
    CROSS JOIN citizens c
    LEFT JOIN orders o ON m.merchant_id = o.merchant_id
    GROUP BY m.category
)
SELECT
    category,
    potential_customers,
    actual_customers,
    (actual_customers::float / potential_customers * 100)::decimal(5,2) as conversion_rate_pct,
    total_orders,
    completed_orders,
    (completed_orders::float / NULLIF(total_orders, 0) * 100)::decimal(5,2) as completion_rate_pct,
    revenue::decimal(12,2) as total_revenue
FROM sales_funnel
WHERE category IS NOT NULL
ORDER BY revenue DESC;

-- 2. Customer Lifetime Value Analysis
SELECT 'Demo 2: Customer Lifetime Value (CLV) Analysis' as demo;

WITH customer_metrics AS (
    SELECT
        c.citizen_id,
        c.name,
        c.registration_date,
        COUNT(o.order_id) as order_count,
        COALESCE(SUM(o.total_amount), 0) as total_spent,
        COALESCE(AVG(o.total_amount), 0) as avg_order_value,
        MIN(o.order_date) as first_order,
        MAX(o.order_date) as last_order,
        EXTRACT(days FROM MAX(o.order_date) - MIN(o.order_date)) as customer_lifespan_days
    FROM citizens c
    LEFT JOIN orders o ON c.citizen_id = o.customer_id AND o.status = 'completed'
    GROUP BY c.citizen_id, c.name, c.registration_date
),
clv_segments AS (
    SELECT *,
        CASE
            WHEN total_spent = 0 THEN 'No Purchase'
            WHEN total_spent < 50 THEN 'Low Value'
            WHEN total_spent < 150 THEN 'Medium Value'
            WHEN total_spent < 300 THEN 'High Value'
            ELSE 'VIP'
        END as clv_segment,
        CASE
            WHEN order_count <= 1 THEN 'One-time'
            WHEN order_count <= 3 THEN 'Occasional'
            WHEN order_count <= 5 THEN 'Regular'
            ELSE 'Frequent'
        END as frequency_segment
    FROM customer_metrics
)
SELECT
    clv_segment,
    frequency_segment,
    COUNT(*) as customer_count,
    AVG(total_spent)::decimal(10,2) as avg_clv,
    AVG(order_count)::decimal(4,1) as avg_orders,
    AVG(avg_order_value)::decimal(8,2) as avg_order_value,
    AVG(NULLIF(customer_lifespan_days, 0))::decimal(6,1) as avg_lifespan_days
FROM clv_segments
GROUP BY clv_segment, frequency_segment
ORDER BY
    CASE clv_segment
        WHEN 'VIP' THEN 1 WHEN 'High Value' THEN 2 WHEN 'Medium Value' THEN 3
        WHEN 'Low Value' THEN 4 ELSE 5 END,
    CASE frequency_segment
        WHEN 'Frequent' THEN 1 WHEN 'Regular' THEN 2 WHEN 'Occasional' THEN 3 ELSE 4 END;

-- 3. RFM Analysis (Recency, Frequency, Monetary)
SELECT 'Demo 3: RFM Analysis for Customer Segmentation' as demo;

WITH rfm_base AS (
    SELECT
        c.citizen_id,
        c.name,
        COALESCE(MAX(o.order_date), c.registration_date) as last_order_date,
        COUNT(CASE WHEN o.status = 'completed' THEN o.order_id END) as frequency,
        COALESCE(SUM(CASE WHEN o.status = 'completed' THEN o.total_amount END), 0) as monetary_value,
        CURRENT_DATE - COALESCE(MAX(o.order_date), c.registration_date) as recency_days
    FROM citizens c
    LEFT JOIN orders o ON c.citizen_id = o.customer_id
    GROUP BY c.citizen_id, c.name, c.registration_date
),
rfm_scores AS (
    SELECT *,
        NTILE(5) OVER (ORDER BY recency_days ASC) as recency_score,
        NTILE(5) OVER (ORDER BY frequency DESC) as frequency_score,
        NTILE(5) OVER (ORDER BY monetary_value DESC) as monetary_score
    FROM rfm_base
),
rfm_segments AS (
    SELECT *,
        CASE
            WHEN recency_score >= 4 AND frequency_score >= 4 AND monetary_score >= 4 THEN 'Champions'
            WHEN recency_score >= 3 AND frequency_score >= 3 AND monetary_score >= 3 THEN 'Loyal Customers'
            WHEN recency_score >= 3 AND frequency_score <= 2 AND monetary_value > 0 THEN 'Potential Loyalists'
            WHEN recency_score >= 4 AND frequency_score <= 2 THEN 'New Customers'
            WHEN recency_score <= 2 AND frequency_score >= 3 THEN 'At Risk'
            WHEN recency_score <= 2 AND frequency_score <= 2 AND monetary_value > 0 THEN 'Cannot Lose Them'
            WHEN monetary_value = 0 THEN 'New'
            ELSE 'Others'
        END as rfm_segment
    FROM rfm_scores
)
SELECT
    rfm_segment,
    COUNT(*) as customer_count,
    AVG(recency_days)::decimal(6,1) as avg_recency_days,
    AVG(frequency)::decimal(4,1) as avg_frequency,
    AVG(monetary_value)::decimal(10,2) as avg_monetary_value,
    ROUND(AVG(recency_score)::numeric, 1) as avg_r_score,
    ROUND(AVG(frequency_score)::numeric, 1) as avg_f_score,
    ROUND(AVG(monetary_score)::numeric, 1) as avg_m_score
FROM rfm_segments
GROUP BY rfm_segment
ORDER BY avg_monetary_value DESC;

-- 4. Time Series Trend Analysis
SELECT 'Demo 4: Monthly Revenue Trend Analysis' as demo;

WITH monthly_metrics AS (
    SELECT
        DATE_TRUNC('month', order_date) as month,
        COUNT(*) as order_count,
        SUM(total_amount) as revenue,
        AVG(total_amount) as avg_order_value,
        COUNT(DISTINCT customer_id) as unique_customers
    FROM orders
    WHERE status = 'completed' AND order_date IS NOT NULL
    GROUP BY DATE_TRUNC('month', order_date)
),
trend_analysis AS (
    SELECT *,
        LAG(revenue, 1) OVER (ORDER BY month) as prev_month_revenue,
        revenue - LAG(revenue, 1) OVER (ORDER BY month) as revenue_change,
        AVG(revenue) OVER (ORDER BY month ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) as revenue_3month_avg
    FROM monthly_metrics
)
SELECT
    month,
    order_count,
    revenue::decimal(12,2),
    avg_order_value::decimal(8,2),
    unique_customers,
    COALESCE(revenue_change, 0)::decimal(12,2) as mom_revenue_change,
    CASE
        WHEN prev_month_revenue > 0 THEN (revenue_change / prev_month_revenue * 100)::decimal(6,2)
        ELSE NULL
    END as mom_growth_pct,
    revenue_3month_avg::decimal(12,2) as three_month_avg
FROM trend_analysis
ORDER BY month;

-- 5. Product Performance Analysis
SELECT 'Demo 5: Merchant Category Performance Matrix' as demo;

WITH category_performance AS (
    SELECT
        m.category,
        COUNT(DISTINCT m.merchant_id) as merchant_count,
        COUNT(o.order_id) as total_orders,
        SUM(o.total_amount) as revenue,
        AVG(o.total_amount) as avg_order_value,
        COUNT(DISTINCT o.customer_id) as unique_customers,
        SUM(o.total_amount) / COUNT(DISTINCT m.merchant_id) as revenue_per_merchant
    FROM merchants m
    LEFT JOIN orders o ON m.merchant_id = o.merchant_id AND o.status = 'completed'
    WHERE m.status = 'active'
    GROUP BY m.category
),
performance_ranking AS (
    SELECT *,
        PERCENT_RANK() OVER (ORDER BY revenue) as revenue_percentile,
        PERCENT_RANK() OVER (ORDER BY unique_customers) as customer_percentile,
        PERCENT_RANK() OVER (ORDER BY avg_order_value) as aov_percentile
    FROM category_performance
)
SELECT
    category,
    merchant_count,
    total_orders,
    revenue::decimal(12,2),
    avg_order_value::decimal(8,2),
    unique_customers,
    revenue_per_merchant::decimal(12,2),
    CASE
        WHEN revenue_percentile >= 0.8 AND customer_percentile >= 0.8 THEN 'Star'
        WHEN revenue_percentile >= 0.6 AND customer_percentile >= 0.6 THEN 'Cash Cow'
        WHEN revenue_percentile <= 0.4 AND customer_percentile >= 0.6 THEN 'Question Mark'
        ELSE 'Dog'
    END as bcg_matrix_category
FROM performance_ranking
WHERE category IS NOT NULL
ORDER BY revenue DESC;

-- 6. Cohort Analysis
SELECT 'Demo 6: Customer Retention Cohort Analysis' as demo;

WITH customer_cohorts AS (
    SELECT
        c.citizen_id,
        DATE_TRUNC('month', c.registration_date) as cohort_month,
        o.order_date,
        DATE_TRUNC('month', o.order_date) as order_month,
        EXTRACT(month FROM AGE(o.order_date, c.registration_date)) as month_number
    FROM citizens c
    JOIN orders o ON c.citizen_id = o.customer_id
    WHERE c.registration_date IS NOT NULL AND o.status = 'completed'
),
cohort_table AS (
    SELECT
        cohort_month,
        month_number,
        COUNT(DISTINCT citizen_id) as customers
    FROM customer_cohorts
    GROUP BY cohort_month, month_number
),
cohort_sizes AS (
    SELECT
        cohort_month,
        COUNT(DISTINCT citizen_id) as cohort_size
    FROM citizens
    WHERE registration_date IS NOT NULL
    GROUP BY DATE_TRUNC('month', registration_date)
)
SELECT
    ct.cohort_month,
    cs.cohort_size,
    COALESCE(SUM(CASE WHEN ct.month_number = 0 THEN ct.customers END), 0) as month_0,
    COALESCE(SUM(CASE WHEN ct.month_number = 1 THEN ct.customers END), 0) as month_1,
    COALESCE(SUM(CASE WHEN ct.month_number = 2 THEN ct.customers END), 0) as month_2,
    COALESCE(SUM(CASE WHEN ct.month_number = 3 THEN ct.customers END), 0) as month_3,
    CASE WHEN cs.cohort_size > 0
         THEN (COALESCE(SUM(CASE WHEN ct.month_number = 1 THEN ct.customers END), 0)::float / cs.cohort_size * 100)::decimal(5,2)
         ELSE 0 END as retention_month_1_pct
FROM cohort_sizes cs
LEFT JOIN cohort_table ct ON cs.cohort_month = ct.cohort_month
GROUP BY ct.cohort_month, cs.cohort_size
ORDER BY ct.cohort_month;

-- Summary and Recommendations
SELECT 'Analytics Summary and Business Recommendations' as summary;

DO $$
DECLARE
    total_customers integer;
    total_revenue decimal(12,2);
    avg_clv decimal(10,2);
    top_category text;
BEGIN
    -- Get key metrics
    SELECT COUNT(*) INTO total_customers FROM citizens;
    SELECT COALESCE(SUM(total_amount), 0) INTO total_revenue FROM orders WHERE status = 'completed';
    SELECT COALESCE(AVG(customer_total), 0) INTO avg_clv FROM (
        SELECT SUM(total_amount) as customer_total
        FROM orders WHERE status = 'completed'
        GROUP BY customer_id
    ) customer_totals;

    SELECT category INTO top_category FROM (
        SELECT m.category, SUM(o.total_amount) as revenue
        FROM merchants m JOIN orders o ON m.merchant_id = o.merchant_id
        WHERE o.status = 'completed' AND m.category IS NOT NULL
        GROUP BY m.category ORDER BY revenue DESC LIMIT 1
    ) top_cat;

    RAISE NOTICE '===========================================';
    RAISE NOTICE 'BUSINESS INTELLIGENCE SUMMARY';
    RAISE NOTICE '===========================================';
    RAISE NOTICE 'Total Customers: %', total_customers;
    RAISE NOTICE 'Total Revenue: $%', total_revenue;
    RAISE NOTICE 'Average CLV: $%', avg_clv;
    RAISE NOTICE 'Top Category: %', COALESCE(top_category, 'N/A');
    RAISE NOTICE '';
    RAISE NOTICE 'Key Insights Generated:';
    RAISE NOTICE '• Sales funnel conversion rates';
    RAISE NOTICE '• Customer lifetime value segments';
    RAISE NOTICE '• RFM analysis for targeted marketing';
    RAISE NOTICE '• Monthly growth trends';
    RAISE NOTICE '• Category performance matrix';
    RAISE NOTICE '• Cohort retention analysis';
    RAISE NOTICE '';
    RAISE NOTICE 'Recommended Actions:';
    RAISE NOTICE '• Focus on high-CLV customer segments';
    RAISE NOTICE '• Develop retention programs for at-risk customers';
    RAISE NOTICE '• Invest in top-performing categories';
    RAISE NOTICE '• Create re-engagement campaigns for dormant users';
    RAISE NOTICE '===========================================';
END $$;
