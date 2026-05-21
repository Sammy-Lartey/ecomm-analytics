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

channel_performance as (

    select
        channel,

        -- volume
        count(event_id)                                             as total_orders,
        count(distinct customer_id)                                 as unique_customers,
        count(distinct case when is_loyal_customer
                            then customer_id end)                   as loyal_customers,

        -- revenue
        round(sum(net_revenue_usd)::decimal, 2)                     as total_revenue_usd,
        round(avg(net_revenue_usd)::decimal, 2)                     as avg_order_value_usd,

        -- loyal customer rate
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

        -- discount usage
        count(case when discount_code is not null then 1 end)       as discounted_orders,
        round(
            count(case when discount_code is not null then 1 end)::decimal
            / nullif(count(event_id), 0) * 100
        , 2)                                                        as discount_usage_pct

    from orders_with_loyalty
    group by channel

)

select * from channel_performance
order by total_revenue_usd desc
