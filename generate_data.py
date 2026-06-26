import random
import psycopg2
import pandas as pd
import numpy as np
from faker import Faker
from datetime import date, timedelta
from psycopg2.extras import execute_values

fake = Faker("en_IN")
random.seed(42)
np.random.seed(42)
Faker.seed(42)

# i wanted the data to feel like an actual Indian retail business
# so Mumbai and Delhi get more customers, Electronics has higher price range etc.

cities = ["Mumbai", "Delhi", "Bengaluru", "Chennai", "Hyderabad", "Pune", "Kolkata", "Ahmedabad"]
city_weights = [0.20, 0.18, 0.15, 0.10, 0.10, 0.10, 0.09, 0.08]

segments = ["Loyal", "New", "Occasional", "At-risk"]
seg_weights = [0.28, 0.35, 0.25, 0.12]

channels = ["Online", "In-store", "B2B", "WhatsApp"]
chan_weights = [0.40, 0.25, 0.20, 0.15]

statuses = ["Delivered", "Returned", "Pending", "Cancelled"]
status_weights = [0.84, 0.09, 0.04, 0.03]

categories = {
    "Electronics":   ["Mobile", "Laptop", "Accessories", "Audio"],
    "Apparel":       ["Men", "Women", "Kids", "Footwear"],
    "Grocery":       ["Staples", "Snacks", "Beverages", "Dairy"],
    "Home & Living": ["Furniture", "Decor", "Kitchen", "Bedding"],
    "Beauty":        ["Skincare", "Haircare", "Makeup", "Wellness"],
}

price_ranges = {
    "Electronics":   (499, 89999),
    "Apparel":       (199, 4999),
    "Grocery":       (29, 999),
    "Home & Living": (299, 24999),
    "Beauty":        (99, 3499),
}

START = date(2023, 1, 1)
END   = date(2023, 12, 31)


def random_date(start, end):
    return start + timedelta(days=random.randint(0, (end - start).days))


# oct-nov is diwali season so more orders, may-jun is slow
def pick_date_with_seasonality():
    for _ in range(6):
        d = random_date(START, END)
        weight = 1.8 if d.month in (10, 11) else 0.7 if d.month in (5, 6) else 1.0
        if random.random() < weight / 1.8:
            return d
    return random_date(START, END)


def make_customers(n=12000):
    rows = []
    for i in range(1, n + 1):
        rows.append({
            "customer_id": i,
            "name":        fake.name(),
            "city":        random.choices(cities, weights=city_weights)[0],
            "segment":     random.choices(segments, weights=seg_weights)[0],
            "signup_date": random_date(date(2020, 1, 1), START),
            "email":       fake.unique.email(),
        })
    return pd.DataFrame(rows)


def make_products(n=800):
    rows = []
    for i in range(1, n + 1):
        cat = random.choice(list(categories.keys()))
        sub = random.choice(categories[cat])
        lo, hi = price_ranges[cat]
        price = round(random.uniform(lo, hi), 2)
        cost  = round(price * random.uniform(0.45, 0.72), 2)
        rows.append({
            "product_id":   i,
            "name":         f"{fake.word().capitalize()} {sub} {random.randint(100, 999)}",
            "category":     cat,
            "sub_category": sub,
            "unit_price":   price,
            "cost_price":   cost,
        })
    return pd.DataFrame(rows)


def make_orders(n=35000, customer_ids=None):
    rows = []
    for i in range(1, n + 1):
        order_date = pick_date_with_seasonality()
        channel    = random.choices(channels, weights=chan_weights)[0]

        # B2B teams usually place orders on Monday mornings
        if channel == "B2B" and random.random() < 0.55:
            days_to_monday = (7 - order_date.weekday()) % 7
            order_date = min(order_date + timedelta(days=days_to_monday), END)

        rows.append({
            "order_id":    i,
            "customer_id": random.choice(customer_ids),
            "order_date":  order_date,
            "channel":     channel,
            "status":      random.choices(statuses, weights=status_weights)[0],
            "city":        random.choices(cities, weights=city_weights)[0],
        })
    return pd.DataFrame(rows)


def make_order_items(orders_df, product_ids):
    rows = []
    item_id = 1
    for _, order in orders_df.iterrows():
        n_items = np.random.choice([1, 2, 3, 4, 5], p=[0.30, 0.30, 0.20, 0.12, 0.08])
        for pid in random.sample(product_ids, min(n_items, len(product_ids))):
            rows.append({
                "item_id":      item_id,
                "order_id":     int(order["order_id"]),
                "product_id":   pid,
                "quantity":     random.choices([1, 2, 3, 4, 5], weights=[0.50, 0.25, 0.13, 0.07, 0.05])[0],
                "unit_price":   round(random.uniform(99, 4999), 2),
                "discount_pct": random.choices([0, 5, 10, 15, 20, 25], weights=[0.45, 0.20, 0.15, 0.10, 0.07, 0.03])[0],
            })
            item_id += 1
    return pd.DataFrame(rows)


def load_to_postgres(customers, products, orders, items):
    conn = psycopg2.connect(dbname="retailpulse", user="postgres", password="postgres", host="localhost", port=5432)
    cur  = conn.cursor()

    def insert(table, df, cols):
        sql  = f"INSERT INTO {table} ({', '.join(cols)}) VALUES %s ON CONFLICT DO NOTHING"
        data = [tuple(row) for row in df[cols].itertuples(index=False)]
        execute_values(cur, sql, data, page_size=1000)
        conn.commit()
        print(f"loaded {table}: {len(data)} rows")

    insert("customers",   customers, ["customer_id", "name", "city", "segment", "signup_date", "email"])
    insert("products",    products,  ["product_id", "name", "category", "sub_category", "unit_price", "cost_price"])
    insert("orders",      orders,    ["order_id", "customer_id", "order_date", "channel", "status", "city"])
    insert("order_items", items,     ["item_id", "order_id", "product_id", "quantity", "unit_price", "discount_pct"])

    cur.close()
    conn.close()


if __name__ == "__main__":
    print("generating data...")

    customers = make_customers()
    products  = make_products()
    orders    = make_orders(customer_ids=customers["customer_id"].tolist())
    items     = make_order_items(orders, products["product_id"].tolist())

    # save CSVs locally first
    customers.to_csv("customers.csv", index=False)
    products.to_csv("products.csv",   index=False)
    orders.to_csv("orders.csv",       index=False)
    items.to_csv("order_items.csv",   index=False)
    print("CSVs saved")

    # load into postgres
    load_to_postgres(customers, products, orders, items)

    print(f"\ndone.")
    print(f"customers: {len(customers)}, products: {len(products)}, orders: {len(orders)}, items: {len(items)}")
