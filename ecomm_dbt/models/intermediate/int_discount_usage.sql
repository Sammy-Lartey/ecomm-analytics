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
        coalesce(lc.is_loyal_customer, false)                   as is_loyal_customer

    from orders o
    left join loyal_customers lc
        on o.customer_id = lc.customer_id

),

discount_usage as (

    select
        -- group null discount codes as 'No Discount'
        coalesce(discount_code, 'No Discount')                  as discount_code,
        count(event_id)                                         as total_orders,
        count(distinct customer_id)                             as unique_customers,

        -- revenue
        sum(net_revenue_usd)                                    as total_revenue_usd,
        avg(net_revenue_usd)                                    as avg_order_value_usd,

        -- discount amounts
        sum(discount_local)                                     as total_discount_local,
        avg(discount_local)                                     as avg_discount_local,

        -- loyalty metrics — do discounts drive repeat purchases?
        count(case when is_loyal_customer then 1 end)           as loyal_customer_orders,
        count(distinct case when is_loyal_customer
                            then customer_id end)               as loyal_unique_customers,

        -- loyal customer rate per discount code
        round(
            count(distinct case when is_loyal_customer
                                then customer_id end)::decimal
            / nullif(count(distinct customer_id), 0) * 100
        , 2)                                                    as loyal_customer_pct,

        -- refunds per discount code
        count(case when is_refunded then 1 end)                 as total_refunds

    from orders_with_loyalty
    group by coalesce(discount_code, 'No Discount')

)

select * from discount_usage
order by total_orders desc
