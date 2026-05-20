import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from pyspark.sql.types import TimestampType, BooleanType, DoubleType, IntegerType
from pyspark.sql.window import Window

# ── Job setup ─────────────────────────────────────────────────────────────────
args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "RAW_BUCKET",
    "PROCESSED_BUCKET",
    "REDSHIFT_URL",
    "REDSHIFT_ROLE",
    "REDSHIFT_TMP_DIR"
])

sc          = SparkContext()
glueContext = GlueContext(sc)
spark       = glueContext.spark_session
job         = Job(glueContext)
job.init(args["JOB_NAME"], args)

RAW_BUCKET       = args["RAW_BUCKET"]
PROCESSED_BUCKET = args["PROCESSED_BUCKET"]
REDSHIFT_URL     = args["REDSHIFT_URL"]
REDSHIFT_ROLE    = args["REDSHIFT_ROLE"]
REDSHIFT_TMP_DIR = args["REDSHIFT_TMP_DIR"]

# ── Helper: write Parquet to processed bucket + load to Redshift ──────────────
def write_table(df, table_name):
    parquet_path = f"s3://{PROCESSED_BUCKET}/{table_name}/"
    df.write.mode("overwrite").parquet(parquet_path)
    print(f"Written Parquet: {parquet_path}")

    df.write \
        .format("io.github.spark_redshift_community.spark.redshift") \
        .option("url", REDSHIFT_URL) \
        .option("dbtable", f"staging.{table_name}") \
        .option("tempdir", REDSHIFT_TMP_DIR) \
        .option("aws_iam_role", REDSHIFT_ROLE) \
        .option("preactions", f"CREATE SCHEMA IF NOT EXISTS staging; DROP TABLE IF EXISTS staging.{table_name};") \
        .mode("overwrite") \
        .save()
    print(f"Loaded to Redshift: staging.{table_name}")

# ══════════════════════════════════════════════════════════════════════════════
# 1. EVENTS
# ══════════════════════════════════════════════════════════════════════════════
print("Processing events...")

events_raw = spark.read.option("header", True).csv(
    f"s3://{RAW_BUCKET}/ecommerce/events.csv"
)

events = events_raw \
    .withColumn("event_date",
        F.to_timestamp("event_date")) \
    .withColumn("refund_datetime",
        F.to_timestamp("refund_datetime")) \
    .withColumn("quantity",
        F.col("quantity").cast(IntegerType())) \
    .withColumn("unit_price_local",
        F.col("unit_price_local").cast(DoubleType())) \
    .withColumn("discount_local",
        F.col("discount_local").cast(DoubleType())) \
    .withColumn("tax_local",
        F.col("tax_local").cast(DoubleType())) \
    .withColumn("net_revenue_local",
        F.col("net_revenue_local").cast(DoubleType())) \
    .withColumn("fx_rate_to_usd",
        F.col("fx_rate_to_usd").cast(DoubleType())) \
    .withColumn("net_revenue_usd",
        F.col("net_revenue_usd").cast(DoubleType())) \
    .withColumn("is_refunded",
        F.col("is_refunded").cast(BooleanType())) \
    .withColumn("latitude",
        F.col("latitude").cast(DoubleType())) \
    .withColumn("longitude",
        F.col("longitude").cast(DoubleType())) \
    .withColumn("discount_code",
        F.when(
            F.col("discount_code").isin("N/A", "n/a", "", None), None
        ).otherwise(F.col("discount_code"))) \
    .withColumn("region",
        F.when(
            F.col("region").isin("", None), "Unknown"
        ).otherwise(F.col("region"))) \
    .withColumn("event_type",     F.lower(F.trim(F.col("event_type")))) \
    .withColumn("channel",        F.trim(F.col("channel"))) \
    .withColumn("payment_method", F.trim(F.col("payment_method"))) \
    .withColumn("order_month",    F.date_format("event_date", "yyyy-MM")) \
    .withColumn("order_year",     F.year("event_date")) \
    .withColumn("order_month_num",F.month("event_date")) \
    .dropDuplicates(["event_id"])

# ── Loyal customer flag (2+ orders per customer) ──────────────────────────────
order_counts = events \
    .filter(F.col("event_type") == "order") \
    .groupBy("customer_id") \
    .agg(F.count("event_id").alias("order_count"))

events = events \
    .join(order_counts, on="customer_id", how="left") \
    .withColumn("is_loyal_customer",
        F.when(F.col("order_count") >= 2, True).otherwise(False)) \
    .drop("order_count")

# ── Days to second purchase ───────────────────────────────────────────────────
orders_only = events.filter(F.col("event_type") == "order")

window_spec = Window.partitionBy("customer_id").orderBy("event_date")

orders_ranked = orders_only \
    .withColumn("purchase_rank", F.rank().over(window_spec)) \
    .withColumn("prev_purchase_date",
        F.lag("event_date", 1).over(window_spec)) \
    .withColumn("days_since_prev_purchase",
        F.datediff(F.col("event_date"), F.col("prev_purchase_date")))

second_purchase = orders_ranked \
    .filter(F.col("purchase_rank") == 2) \
    .select("customer_id",
            F.col("days_since_prev_purchase").alias("days_to_second_purchase"))

events = events \
    .join(second_purchase, on="customer_id", how="left")

write_table(events, "stg_events")

# ══════════════════════════════════════════════════════════════════════════════
# 2. PRODUCTS
# ══════════════════════════════════════════════════════════════════════════════
print("Processing products...")

products_raw = spark.read.option("header", True).csv(
    f"s3://{RAW_BUCKET}/ecommerce/products.csv"
)

products = products_raw \
    .withColumn("is_subscription",
        F.col("is_subscription").cast(BooleanType())) \
    .withColumn("base_price_usd",
        F.col("base_price_usd").cast(DoubleType())) \
    .withColumn("base_price_usd_orig",
        F.col("base_price_usd_orig").cast(DoubleType())) \
    .withColumn("first_release_date",
        F.to_date("first_release_date")) \
    .withColumn("billing_cycle",  F.trim(F.col("billing_cycle"))) \
    .withColumn("category",       F.trim(F.col("category"))) \
    .withColumn("vendor",         F.trim(F.col("vendor"))) \
    .dropDuplicates(["product_id"])

write_table(products, "stg_products")

# ══════════════════════════════════════════════════════════════════════════════
# 3. CUSTOMERS
# ══════════════════════════════════════════════════════════════════════════════
print("Processing customers...")

customers_raw = spark.read.option("header", True).csv(
    f"s3://{RAW_BUCKET}/ecommerce/customers.csv"
)

customers = customers_raw \
    .withColumn("signup_date",
        F.to_timestamp("signup_date")) \
    .withColumn("country_latitude",
        F.col("country_latitude").cast(DoubleType())) \
    .withColumn("country_longitude",
        F.col("country_longitude").cast(DoubleType())) \
    .withColumn("region",
        F.when(
            F.col("region").isin("", None), "Unknown"
        ).otherwise(F.col("region"))) \
    .withColumn("segment",              F.trim(F.col("segment"))) \
    .withColumn("acquisition_channel",  F.trim(F.col("acquisition_channel"))) \
    .withColumn("age_band",             F.trim(F.col("age_band"))) \
    .dropDuplicates(["customer_id"])

write_table(customers, "stg_customers")

# ── Done ──────────────────────────────────────────────────────────────────────
print("All tables processed successfully.")
job.commit()
