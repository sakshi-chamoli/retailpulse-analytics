# RetailPulse — Sales & Customer Intelligence

A self-initiated end-to-end business analytics project built to practice SQL on a realistic retail dataset.
The goal was to go beyond basic aggregation — modelling a schema, writing production-style queries,
and surfacing insights a business team would actually act on.

---

## Problem Statement

A mid-size Indian retail chain (8 cities, 4 sales channels) wanted to understand:

1. Which customer segments drive disproportionate revenue?
2. Which product categories have the worst return rates?
3. Which cities and channels are growing fastest?
4. Which high-value customers are at churn risk?

I designed the schema, generated synthetic but realistic data, and wrote SQL to answer each question.

---

## Dataset

| Table | Rows (synthetic) | Description |
|---|---|---|
| `customers` | ~12,000 | Demographics, segment, city, signup date |
| `products` | ~800 | Category, sub-category, price, cost |
| `orders` | ~35,000 | Channel, status, date, city |
| `order_items` | ~90,000 | Quantity, price, discount, computed revenue |

Data generated with Python (`faker`, `numpy`) to replicate real seasonality —
Diwali spike in Oct–Nov, summer dip in May–Jun, B2B orders clustering on Mondays.

---

## Schema Design Decisions

- Used a **generated column** (`line_revenue`) on `order_items` so revenue is never calculated ad-hoc — consistent across every query.
- Added a **partial index** on `orders(order_date, customer_id) WHERE status = 'Delivered'` since ~92% of analytical queries filter on delivered orders only. Cuts query time on large scans.
- Kept `segment` on the `customers` table intentionally denormalised — segments are updated weekly by a separate pipeline, not per-order. A join to a segment history table would be cleaner for audit trails but over-engineered for this scope.

---

## Key Queries

### 1. Quarterly Revenue with QoQ Growth
Uses `LAG()` window function over quarters to compute growth % without a self-join.

### 2. RFM-style Customer Scoring
Recency, Frequency, Monetary — assigns each customer an `activity_status` (Active / Cooling / Lapsed)
and `monetary_quartile` using `NTILE(4)`. Useful for targeting re-engagement campaigns.

### 3. Channel Pivot (FILTER clause)
Uses `SUM(...) FILTER (WHERE channel = 'X')` instead of CASE-WHEN for cleaner, readable pivots.
PostgreSQL-specific but significantly more legible.

### 4. Cohort Retention
Month-0 cohorts tracked through M+1, M+2, M+3. Identifies which acquisition months had the
best long-term retention — useful for matching spend to cohort quality.

### 5. Churn Risk Flagging
Customers with >60 days inactivity AND lifetime value > ₹15,000. Simple but immediately actionable
— output can feed directly into a CRM re-engagement list.

---

## Sample Findings(2025)

- **Loyal segment (28% of users) → 45% of revenue.** Classic 80/20 in action.
- **Electronics return rate: 3.1%** vs. Apparel at 9.4%. Suggests apparel sizing/description issues.
- **WhatsApp channel grew 22% QoQ** in Q4 — cheapest CAC, highest repeat rate.
- **Mumbai + Bengaluru = 51% of total revenue** despite being 2 of 8 cities.
- **412 high-value customers** flagged as churn risk (inactive 60+ days, LTV > ₹15K).

---

## Tech Stack

| Tool | Purpose |
|---|---|
| PostgreSQL 15 | Primary database & all analytics queries |
| Python (`faker`, `pandas`, `numpy`) | Synthetic data generation |
| Python (`psycopg2`) | Data loading scripts |
| Excel | Power BI | Visualisation |

---

## Files

```
retailpulse/
├── retailpulse_queries.sql  ← Full schema + 8 analysis queries + views + indexes
└── README.md

Data generation script and dashboard coming soon.
```

---

## What I'd Add with More Time

- **Stored procedure** to auto-update customer segments weekly based on RFM scores
- **dbt models** to separate raw, staging, and mart layers properly
- **Materialised views** for the quarterly KPI view (currently recomputed on every query)
- Connect to a live Supabase instance so the dashboard pulls real data

---

## Running Locally

```bash
# 1. Create the database
createdb retailpulse

# 2. Run schema + seed queries
psql -d retailpulse -f schema/retailpulse_queries.sql

# 3. Generate synthetic data (requires Python 3.9+)
pip install faker pandas numpy psycopg2-binary
python data_gen/generate_data.py

# 4. Open dashboard
open dashboard/index.html
```

---

Built by Sakshi Chamoli 
