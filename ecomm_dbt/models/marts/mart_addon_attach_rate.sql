-- This model calculates the attach rate of add-on products to core products.

with orders as (

    select * from {{ ref('stg_events') }}
    where event_type = 'order'

),

products as (

    select * from {{ ref('stg_products') }}

),

orders_with_products as (

    select
        o.event_id,
        o.customer_id,
        o.net_revenue_usd,
        p.product_id,
        p.brand_safe_name,
        p.category,
        p.is_addon

    from orders o
    join products p
        on o.product_id = p.product_id

),

-- total unique customers who ever bought a core product
total_core_customers as (

    select count(distinct customer_id) as core_customer_count
    from orders_with_products
    where is_addon = false

),

-- customers who bought each specific add-on
addon_customers as (

    select
        brand_safe_name                                             as addon_name,
        category                                                    as addon_category,
        count(distinct customer_id)                                 as customers_with_addon,
        count(event_id)                                             as total_addon_orders,
        round(sum(net_revenue_usd)::decimal, 2)                     as total_addon_revenue_usd

    from orders_with_products
    where is_addon = true
    group by brand_safe_name, category

)

select
    a.addon_name,
    a.addon_category,
    a.customers_with_addon,
    t.core_customer_count                                           as total_core_customers,
    round(
        a.customers_with_addon::decimal
        / nullif(t.core_customer_count, 0) * 100
    , 2)                                                            as attach_rate_pct,
    a.total_addon_orders,
    a.total_addon_revenue_usd

from addon_customers a
cross join total_core_customers t
order by attach_rate_pct desc