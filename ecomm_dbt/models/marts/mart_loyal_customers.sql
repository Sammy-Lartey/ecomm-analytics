-- This model identifies loyal customers based on their purchase behavior and calculates key metrics such as total revenue, average order value, and customer lifespan. 
-- It also provides insights into the primary sales channel for loyal customers and their purchase timeline, which can help inform targeted marketing strategies and customer retention efforts.

with loyal_customers as (

    select * from {{ ref('int_loyal_customers') }}
    where is_loyal_customer = true

)

select
    customer_id,
    country,
    region,
    segment,
    age_band,
    acquisition_channel,
    currency_preference,
    signup_date,

    -- order metrics
    total_orders,
    round(total_revenue_usd::decimal, 2)                            as total_revenue_usd,
    round(avg_order_value_usd::decimal, 2)                          as avg_order_value_usd,
    total_refunds,
    primary_channel,

    -- purchase timeline
    first_purchase_date,
    last_purchase_date,
    customer_lifespan_days,
    days_to_second_purchase

from loyal_customers
order by total_revenue_usd desc
