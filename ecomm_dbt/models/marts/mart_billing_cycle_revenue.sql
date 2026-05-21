with orders as (

    select * from {{ ref('stg_events') }}
    where event_type = 'order'

),

products as (

    select * from {{ ref('stg_products') }}

),

loyal_customers as (

    select
        customer_id,
        is_loyal_customer

    from {{ ref('int_loyal_customers') }}

),

orders_enriched as (

    select
        o.event_id,
        o.customer_id,
        o.net_revenue_usd,
        o.channel,
        o.is_refunded,
        p.billing_cycle,
        p.category,
        p.vendor,
        p.is_addon,
        coalesce(lc.is_loyal_customer, false)                       as is_loyal_customer

    from orders o
    join products p
        on o.product_id = p.product_id
    left join loyal_customers lc
        on o.customer_id = lc.customer_id

),

billing_revenue as (

    select
        billing_cycle,
        category,

        -- volume
        count(event_id)                                             as total_orders,
        count(distinct customer_id)                                 as unique_customers,
        count(distinct case when is_loyal_customer
                            then customer_id end)                   as loyal_customers,

        -- revenue
        round(sum(net_revenue_usd)::decimal, 2)                     as total_revenue_usd,
        round(avg(net_revenue_usd)::decimal, 2)                     as avg_revenue_per_order_usd,

        -- revenue per customer — key metric for annual vs monthly comparison
        round(
            sum(net_revenue_usd)::decimal
            / nullif(count(distinct customer_id), 0)
        , 2)                                                        as avg_revenue_per_customer_usd,

        -- refunds
        count(case when is_refunded then 1 end)                     as total_refunds,
        round(
            count(case when is_refunded then 1 end)::decimal
            / nullif(count(event_id), 0) * 100
        , 2)                                                        as refund_rate_pct

    from orders_enriched
    group by billing_cycle, category

)

select * from billing_revenue
order by billing_cycle, total_revenue_usd desc
