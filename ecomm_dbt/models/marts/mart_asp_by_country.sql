with orders as (

    select * from {{ ref('stg_events') }}
    where event_type = 'order'

)

select
    country,
    region,
    currency,

    -- volume
    count(event_id)                                                 as total_orders,
    count(distinct customer_id)                                     as unique_customers,

    -- average selling price
    round(avg(unit_price_local)::decimal, 2)                        as avg_selling_price_local,
    round(avg(net_revenue_usd)::decimal, 2)                         as avg_selling_price_usd,

    -- revenue
    round(sum(net_revenue_usd)::decimal, 2)                         as total_revenue_usd,

    -- fx rate
    round(avg(fx_rate_to_usd)::decimal, 6)                          as avg_fx_rate,

    -- discount impact on ASP
    round(avg(discount_local)::decimal, 2)                          as avg_discount_local,
    count(case when discount_code is not null then 1 end)           as discounted_orders

from orders
group by country, region, currency
order by total_revenue_usd desc
