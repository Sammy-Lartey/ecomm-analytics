-- This model calculates key sales metrics by month, including total orders, unique customers, loyal customers, total revenue, average order value, loyal customer percentage, refund rates, and discounted orders. 
-- It provides insights into sales performance over time, the impact of customer loyalty on monthly sales, and trends in refunds and discount usage. 
-- This information can help identify seasonal patterns, evaluate the effectiveness of marketing campaigns, and inform inventory and promotional strategies throughout the year.

with orders as (

    select * from {{ ref('stg_events') }}
    where event_type = 'order'

),

loyal_customers as (

    select
        customer_id,
        is_loyal_customer

    from {{ ref('int_loyal_customers') }}

),

orders_with_loyalty as (

    select
        o.*,
        coalesce(lc.is_loyal_customer, false)                       as is_loyal_customer

    from orders o
    left join loyal_customers lc
        on o.customer_id = lc.customer_id

),

monthly as (

    select
        order_month,
        order_year,
        order_month_num,
        order_quarter,

        -- volume
        count(event_id)                                             as total_orders,
        count(distinct customer_id)                                 as unique_customers,
        count(distinct case when is_loyal_customer
                            then customer_id end)                   as loyal_customers,

        -- revenue
        round(sum(net_revenue_usd)::decimal, 2)                     as total_revenue_usd,
        round(avg(net_revenue_usd)::decimal, 2)                     as avg_order_value_usd,

        -- loyal customer percentage of monthly sales
        round(
            count(distinct case when is_loyal_customer
                                then customer_id end)::decimal
            / nullif(count(distinct customer_id), 0) * 100
        , 2)                                                        as loyal_customer_pct,

        -- refunds
        count(case when is_refunded then 1 end)                     as total_refunds,
        round(
            count(case when is_refunded then 1 end)::decimal
            / nullif(count(event_id), 0) * 100
        , 2)                                                        as refund_rate_pct,

        -- discounted orders
        count(case when discount_code is not null then 1 end)       as discounted_orders

    from orders_with_loyalty
    group by
        order_month,
        order_year,
        order_month_num,
        order_quarter

)

select * from monthly
order by order_year, order_month_num
