-- ============================================================
--  RetailPulse: Sales & Customer Intelligence
--  Author   : [Your Name]
--  Database : PostgreSQL 15
--  Dataset  : Synthetic retail data — FY 2023 (India ops)
-- ============================================================


-- ──────────────────────────────────────────────
--  SECTION 1: SCHEMA SETUP
-- ──────────────────────────────────────────────

CREATE TABLE customers (
    customer_id     SERIAL PRIMARY KEY,
    name            VARCHAR(120),
    city            VARCHAR(80),
    segment         VARCHAR(30) CHECK (segment IN ('Loyal','New','Occasional','At-risk')),
    signup_date     DATE,
    email           VARCHAR(120) UNIQUE
);

CREATE TABLE products (
    product_id      SERIAL PRIMARY KEY,
    name            VARCHAR(120),
    category        VARCHAR(60),
    sub_category    VARCHAR(60),
    unit_price      NUMERIC(10,2),
    cost_price      NUMERIC(10,2)
);

CREATE TABLE orders (
    order_id        SERIAL PRIMARY KEY,
    customer_id     INT REFERENCES customers(customer_id),
    order_date      DATE,
    channel         VARCHAR(30) CHECK (channel IN ('Online','In-store','B2B','WhatsApp')),
    status          VARCHAR(20) CHECK (status IN ('Delivered','Returned','Pending','Cancelled')),
    city            VARCHAR(80)
);

CREATE TABLE order_items (
    item_id         SERIAL PRIMARY KEY,
    order_id        INT REFERENCES orders(order_id),
    product_id      INT REFERENCES products(product_id),
    quantity        INT,
    unit_price      NUMERIC(10,2),
    discount_pct    NUMERIC(5,2) DEFAULT 0
);

-- Derived revenue column (stored for query performance)
ALTER TABLE order_items
    ADD COLUMN line_revenue NUMERIC(12,2)
    GENERATED ALWAYS AS
        (quantity * unit_price * (1 - discount_pct / 100)) STORED;


-- ──────────────────────────────────────────────
--  SECTION 2: CORE BUSINESS QUERIES
-- ──────────────────────────────────────────────

-- Q1: Quarterly revenue summary with QoQ growth
WITH quarterly AS (
    SELECT
        EXTRACT(QUARTER FROM o.order_date)::INT  AS quarter,
        EXTRACT(YEAR   FROM o.order_date)::INT   AS year,
        SUM(oi.line_revenue)                     AS total_revenue,
        COUNT(DISTINCT o.order_id)               AS total_orders,
        COUNT(DISTINCT o.customer_id)            AS unique_customers
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.order_id
    WHERE o.status = 'Delivered'
      AND EXTRACT(YEAR FROM o.order_date) = 2023
    GROUP BY quarter, year
)
SELECT
    quarter,
    ROUND(total_revenue / 100000, 2)                          AS revenue_lakhs,
    total_orders,
    unique_customers,
    ROUND(total_revenue / total_orders, 0)                    AS avg_order_value,
    ROUND(
        100.0 * (total_revenue - LAG(total_revenue) OVER (ORDER BY quarter))
              / NULLIF(LAG(total_revenue) OVER (ORDER BY quarter), 0),
    1)                                                        AS qoq_growth_pct
FROM quarterly
ORDER BY quarter;


-- Q2: Top-10 revenue-generating products with margin
SELECT
    p.name,
    p.category,
    SUM(oi.quantity)                            AS units_sold,
    ROUND(SUM(oi.line_revenue), 0)              AS gross_revenue,
    ROUND(
        100.0 * SUM(oi.line_revenue - oi.quantity * p.cost_price)
              / NULLIF(SUM(oi.line_revenue), 0),
    1)                                          AS margin_pct,
    RANK() OVER (ORDER BY SUM(oi.line_revenue) DESC) AS revenue_rank
FROM order_items oi
JOIN products p ON p.product_id = oi.product_id
JOIN orders   o ON o.order_id   = oi.order_id
WHERE o.status = 'Delivered'
GROUP BY p.product_id, p.name, p.category
ORDER BY gross_revenue DESC
LIMIT 10;


-- Q3: Customer segmentation — RFM-style analysis
-- Recency / Frequency / Monetary value per customer
WITH rfm_base AS (
    SELECT
        c.customer_id,
        c.name,
        c.segment,
        c.city,
        MAX(o.order_date)                                      AS last_order_date,
        COUNT(DISTINCT o.order_id)                             AS frequency,
        ROUND(SUM(oi.line_revenue), 0)                         AS monetary,
        CURRENT_DATE - MAX(o.order_date)                       AS recency_days
    FROM customers c
    JOIN orders      o  ON o.customer_id  = c.customer_id
    JOIN order_items oi ON oi.order_id    = o.order_id
    WHERE o.status = 'Delivered'
    GROUP BY c.customer_id, c.name, c.segment, c.city
)
SELECT
    customer_id,
    name,
    city,
    segment,
    recency_days,
    frequency,
    monetary,
    ROUND(monetary / NULLIF(frequency, 0), 0)               AS avg_order_value,
    NTILE(4) OVER (ORDER BY monetary DESC)                  AS monetary_quartile,
    CASE
        WHEN recency_days <= 30  THEN 'Active'
        WHEN recency_days <= 90  THEN 'Cooling'
        ELSE 'Lapsed'
    END                                                     AS activity_status
FROM rfm_base
ORDER BY monetary DESC;


-- Q4: Monthly revenue by channel — pivot-style using FILTER
SELECT
    TO_CHAR(o.order_date, 'YYYY-MM')                              AS month,
    ROUND(SUM(oi.line_revenue) FILTER (WHERE o.channel = 'Online'),   0) AS online,
    ROUND(SUM(oi.line_revenue) FILTER (WHERE o.channel = 'In-store'),  0) AS in_store,
    ROUND(SUM(oi.line_revenue) FILTER (WHERE o.channel = 'B2B'),       0) AS b2b,
    ROUND(SUM(oi.line_revenue) FILTER (WHERE o.channel = 'WhatsApp'),  0) AS whatsapp,
    ROUND(SUM(oi.line_revenue),                                        0) AS total
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'Delivered'
  AND EXTRACT(YEAR FROM o.order_date) = 2023
GROUP BY month
ORDER BY month;


-- Q5: Return rate by category (quality/ops signal)
SELECT
    p.category,
    COUNT(*) FILTER (WHERE o.status = 'Delivered')           AS delivered,
    COUNT(*) FILTER (WHERE o.status = 'Returned')            AS returned,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE o.status = 'Returned')
              / NULLIF(COUNT(*), 0),
    2)                                                       AS return_rate_pct
FROM orders o
JOIN order_items oi ON oi.order_id  = o.order_id
JOIN products   p  ON p.product_id  = oi.product_id
GROUP BY p.category
ORDER BY return_rate_pct DESC;


-- Q6: Cohort retention — customers who purchased in month M and returned in M+1, M+2, M+3
WITH first_order AS (
    SELECT
        customer_id,
        DATE_TRUNC('month', MIN(order_date)) AS cohort_month
    FROM orders
    WHERE status = 'Delivered'
    GROUP BY customer_id
),
subsequent AS (
    SELECT
        f.customer_id,
        f.cohort_month,
        DATE_TRUNC('month', o.order_date)   AS order_month,
        EXTRACT(MONTH FROM AGE(
            DATE_TRUNC('month', o.order_date),
            f.cohort_month
        ))::INT                             AS months_since_first
    FROM first_order f
    JOIN orders o ON o.customer_id = f.customer_id
    WHERE o.status = 'Delivered'
)
SELECT
    TO_CHAR(cohort_month, 'Mon YYYY')       AS cohort,
    COUNT(DISTINCT customer_id)             AS cohort_size,
    COUNT(DISTINCT customer_id) FILTER (WHERE months_since_first = 1)  AS retained_m1,
    COUNT(DISTINCT customer_id) FILTER (WHERE months_since_first = 2)  AS retained_m2,
    COUNT(DISTINCT customer_id) FILTER (WHERE months_since_first = 3)  AS retained_m3,
    ROUND(100.0 * COUNT(DISTINCT customer_id) FILTER (WHERE months_since_first = 1)
        / NULLIF(COUNT(DISTINCT customer_id), 0), 1)                   AS ret_rate_m1_pct
FROM subsequent
WHERE months_since_first <= 3
GROUP BY cohort_month
ORDER BY cohort_month;


-- Q7: City-level performance — revenue, orders, avg basket size
SELECT
    o.city,
    COUNT(DISTINCT o.order_id)              AS total_orders,
    COUNT(DISTINCT o.customer_id)           AS unique_customers,
    ROUND(SUM(oi.line_revenue), 0)          AS gross_revenue,
    ROUND(AVG(oi.line_revenue), 0)          AS avg_item_value,
    ROUND(SUM(oi.line_revenue) /
          NULLIF(COUNT(DISTINCT o.order_id), 0), 0) AS avg_basket_size
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'Delivered'
GROUP BY o.city
ORDER BY gross_revenue DESC
LIMIT 15;


-- Q8: Customers at churn risk — no order in last 60 days, previously high-value
WITH last_activity AS (
    SELECT
        c.customer_id,
        c.name,
        c.email,
        c.segment,
        MAX(o.order_date)               AS last_order_date,
        CURRENT_DATE - MAX(o.order_date) AS days_inactive,
        SUM(oi.line_revenue)            AS lifetime_value
    FROM customers c
    JOIN orders      o  ON o.customer_id  = c.customer_id
    JOIN order_items oi ON oi.order_id    = o.order_id
    WHERE o.status = 'Delivered'
    GROUP BY c.customer_id, c.name, c.email, c.segment
)
SELECT
    customer_id,
    name,
    email,
    segment,
    days_inactive,
    ROUND(lifetime_value, 0)            AS lifetime_value,
    'High churn risk'                   AS flag
FROM last_activity
WHERE days_inactive > 60
  AND lifetime_value > 15000
ORDER BY lifetime_value DESC;


-- ──────────────────────────────────────────────
--  SECTION 3: VIEWS (for dashboard consumption)
-- ──────────────────────────────────────────────

CREATE OR REPLACE VIEW vw_quarterly_kpis AS
SELECT
    EXTRACT(QUARTER FROM o.order_date)::INT     AS quarter,
    ROUND(SUM(oi.line_revenue) / 100000, 2)     AS revenue_lakhs,
    COUNT(DISTINCT o.order_id)                  AS orders,
    COUNT(DISTINCT o.customer_id)               AS customers,
    ROUND(AVG(oi.line_revenue * oi.quantity), 0) AS avg_order_value
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
WHERE o.status = 'Delivered'
  AND EXTRACT(YEAR FROM o.order_date) = 2023
GROUP BY quarter;

CREATE OR REPLACE VIEW vw_segment_revenue AS
SELECT
    c.segment,
    COUNT(DISTINCT c.customer_id)               AS customers,
    COUNT(DISTINCT o.order_id)                  AS orders,
    ROUND(SUM(oi.line_revenue), 0)              AS revenue
FROM customers c
JOIN orders      o  ON o.customer_id  = c.customer_id
JOIN order_items oi ON oi.order_id    = o.order_id
WHERE o.status = 'Delivered'
GROUP BY c.segment;


-- ──────────────────────────────────────────────
--  SECTION 4: INDEX STRATEGY
-- ──────────────────────────────────────────────

-- Speed up date-range scans on the largest table
CREATE INDEX idx_orders_date        ON orders(order_date);
CREATE INDEX idx_orders_customer    ON orders(customer_id);
CREATE INDEX idx_orders_status      ON orders(status);
CREATE INDEX idx_items_order        ON order_items(order_id);
CREATE INDEX idx_items_product      ON order_items(product_id);
-- Partial index — only delivered orders (used by most analytics queries)
CREATE INDEX idx_orders_delivered   ON orders(order_date, customer_id)
    WHERE status = 'Delivered';
