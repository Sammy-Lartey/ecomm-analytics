-- This model analyzes the performance of discount codes, including total orders, unique customers, loyal customers, revenue generated, average order value, discount amounts, and refund rates. 
-- It provides insights into which discount codes are most effective at driving sales and customer loyalty, as well as the financial impact of discounts on revenue and profitability. 
-- This information can help inform future discount strategies, promotional efforts, and customer retention initiatives.

with discount_usage as (

    select * from {{ ref('int_discount_usage') }}

)

select
    discount_code,
    total_orders,
    unique_customers,
    loyal_unique_customers,
    loyal_customer_orders,

    -- revenue
    round(total_revenue_usd::decimal, 2)                            as total_revenue_usd,
    round(avg_order_value_usd::decimal, 2)                          as avg_order_value_usd,

    -- discount amounts
    round(total_discount_local::decimal, 2)                         as total_discount_local,
    round(avg_discount_local::decimal, 2)                           as avg_discount_local,

    -- loyalty lift — does this discount code drive repeat purchases?
    loyal_customer_pct,

    -- refunds
    total_refunds

from discount_usage
order by total_orders desc
