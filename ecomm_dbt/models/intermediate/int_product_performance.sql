-- This model aggregates product performance metrics by joining order data with product information. 
-- It provides insights into which products are driving the most revenue, have the highest average selling price, and are most popular among customers. 
-- The model also breaks down performance by product attributes like category, brand, and billing cycle to identify trends and opportunities for optimization.

with orders as (

    select * from {{ ref('stg_events') }}
    where event_type = 'order'

),

products as (

    select * from {{ ref('stg_products') }}

),

product_performance as (

    select
        p.product_id,
        p.product_name,
        p.brand_safe_name,
        p.category,
        p.vendor,
        p.billing_cycle,
        p.is_subscription,
        p.is_addon,
        p.base_price_usd,

        -- order metrics
        count(o.event_id)                                       as total_orders,
        count(distinct o.customer_id)                           as unique_customers,

        -- revenue
        sum(o.net_revenue_usd)                                  as total_revenue_usd,
        avg(o.net_revenue_usd)                                  as avg_revenue_per_order_usd,

        -- average selling price — actual price paid vs base price
        avg(o.unit_price_local)                                 as avg_selling_price_local,
        avg(o.net_revenue_usd)                                  as avg_selling_price_usd,

        -- discounts
        sum(o.discount_local)                                   as total_discount_local,
        avg(o.discount_local)                                   as avg_discount_local,
        count(case when o.discount_code is not null
                   then 1 end)                                  as discounted_orders,

        -- refunds
        count(case when o.is_refunded then 1 end)               as total_refunds,

        -- channel breakdown
        count(case when o.channel = 'Website'      then 1 end)  as orders_website,
        count(case when o.channel = 'Marketplace'  then 1 end)  as orders_marketplace,
        count(case when o.channel = 'Direct Sales' then 1 end)  as orders_direct_sales,
        count(case when o.channel = 'Partner'      then 1 end)  as orders_partner,
        count(case when o.channel = 'Reseller'     then 1 end)  as orders_reseller

    from products p
    left join orders o
        on p.product_id = o.product_id
    group by
        p.product_id,
        p.product_name,
        p.brand_safe_name,
        p.category,
        p.vendor,
        p.billing_cycle,
        p.is_subscription,
        p.is_addon,
        p.base_price_usd

)

select * from product_performance
