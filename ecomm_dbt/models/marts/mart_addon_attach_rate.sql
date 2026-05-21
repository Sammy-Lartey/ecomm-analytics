-- This model calculates the attach rate of add-on products, which is the percentage of customers who bought a core product and also bought an add-on product in the same month. 
-- It also provides insights into the total number of customers who bought add-ons, the total number of core customers, and the revenue generated from add-ons.

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
        o.order_month,
        o.net_revenue_usd,
        p.product_id,
        p.brand_safe_name,
        p.category,
        p.is_addon

    from orders o
    join products p
        on o.product_id = p.product_id

),

-- customers who bought at least one core product
core_customers as (

    select distinct
        customer_id,
        order_month

    from orders_with_products
    where is_addon = false

),

-- customers who bought add-ons
addon_purchases as (

    select
        customer_id,
        order_month,
        brand_safe_name                                             as addon_name,
        category                                                    as addon_category,
        count(event_id)                                             as addon_orders,
        round(sum(net_revenue_usd)::decimal, 2)                     as addon_revenue_usd

    from orders_with_products
    where is_addon = true
    group by customer_id, order_month, brand_safe_name, category

),

attach_rate as (

    select
        a.addon_name,
        a.addon_category,
        count(distinct a.customer_id)                               as customers_with_addon,
        count(distinct c.customer_id)                               as total_core_customers,

        -- attach rate — what % of core product buyers also bought this add-on
        round(
            count(distinct a.customer_id)::decimal
            / nullif(count(distinct c.customer_id), 0) * 100
        , 2)                                                        as attach_rate_pct,

        sum(a.addon_orders)                                         as total_addon_orders,
        round(sum(a.addon_revenue_usd)::decimal, 2)                 as total_addon_revenue_usd

    from core_customers c
    left join addon_purchases a
        on  c.customer_id = a.customer_id
        and c.order_month = a.order_month
    where a.addon_name is not null
    group by a.addon_name, a.addon_category

)

select * from attach_rate
order by attach_rate_pct desc
