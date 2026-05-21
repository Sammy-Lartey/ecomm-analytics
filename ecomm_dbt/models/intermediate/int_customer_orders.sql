with orders as (

    select * from {{ ref('stg_events') }}
    where event_type = 'order'

),

customer_orders as (

    select
        customer_id,

        -- order counts
        count(event_id)                                         as total_orders,

        -- revenue
        sum(net_revenue_usd)                                    as total_revenue_usd,
        avg(net_revenue_usd)                                    as avg_order_value_usd,

        -- purchase dates
        min(event_date)                                         as first_purchase_date,
        max(event_date)                                         as last_purchase_date,

        -- customer lifespan in days between first and last purchase
        datediff(
            'day',
            min(event_date),
            max(event_date)
        )                                                       as customer_lifespan_days,

        -- refunds
        sum(case when is_refunded then 1 else 0 end)            as total_refunds,

        -- channels used — most frequent channel for this customer
        max(channel)                                            as primary_channel

    from orders
    group by customer_id

),

-- rank purchases per customer to identify second purchase date
ranked_orders as (

    select
        customer_id,
        event_date,
        row_number() over (
            partition by customer_id
            order by event_date asc
        )                                                       as purchase_rank

    from orders

),

second_purchase as (

    select
        r2.customer_id,
        datediff(
            'day',
            r1.event_date,
            r2.event_date
        )                                                       as days_to_second_purchase

    from ranked_orders r1
    join ranked_orders r2
        on  r1.customer_id   = r2.customer_id
        and r1.purchase_rank = 1
        and r2.purchase_rank = 2

)

select
    co.*,
    sp.days_to_second_purchase

from customer_orders co
left join second_purchase sp
    on co.customer_id = sp.customer_id
