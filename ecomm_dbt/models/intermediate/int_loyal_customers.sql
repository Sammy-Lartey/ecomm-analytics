with customer_orders as (

    select * from {{ ref('int_customer_orders') }}

),

customers as (

    select * from {{ ref('stg_customers') }}

),

loyal as (

    select
        co.customer_id,

        -- loyalty flag — 2 or more orders
        case
            when co.total_orders >= 2 then true
            else false
        end                                                     as is_loyal_customer,

        -- order metrics
        co.total_orders,
        co.total_revenue_usd,
        co.avg_order_value_usd,
        co.total_refunds,
        co.primary_channel,

        -- purchase dates
        co.first_purchase_date,
        co.last_purchase_date,
        co.customer_lifespan_days,
        co.days_to_second_purchase,

        -- customer profile from stg_customers
        c.country,
        c.region,
        c.segment,
        c.age_band,
        c.acquisition_channel,
        c.currency_preference,
        c.signup_date

    from customer_orders co
    left join customers c
        on co.customer_id = c.customer_id

)

select * from loyal
