with source as (

    select * from {{ source('raw', 'events') }}

),

cleaned as (

    select
        -- ids
        event_id,
        event_type,
        customer_id,
        product_id,

        -- dates — cast from varchar to proper timestamp
        cast(event_date as timestamp)                           as event_date,
        cast(refund_datetime as timestamp)                      as refund_datetime,

        -- location
        country,
        cast(latitude as decimal(10, 4))                        as latitude,
        cast(longitude as decimal(10, 4))                       as longitude,

        -- region — fill missing US and Canada from country lookup
        case
            when region is null or trim(region) = ''
                then case country
                    when 'United States'  then 'AMER'
                    when 'Canada'         then 'AMER'
                    when 'Australia'      then 'APAC'
                    when 'Philippines'    then 'APAC'
                    when 'Germany'        then 'EU'
                    when 'France'         then 'EU'
                    when 'United Kingdom' then 'EU'
                    when 'Netherlands'    then 'EU'
                    when 'Spain'          then 'EU'
                    when 'Brazil'         then 'LATAM'
                    else 'Unknown'
                end
            else region
        end                                                     as region,

        -- channel and payment
        trim(channel)                                           as channel,
        trim(payment_method)                                    as payment_method,

        -- currency
        trim(currency)                                          as currency,

        -- financials
        cast(quantity as integer)                               as quantity,
        cast(unit_price_local as decimal(12, 4))                as unit_price_local,
        cast(net_revenue_local as decimal(12, 4))               as net_revenue_local,
        cast(discount_local as decimal(12, 4))                  as discount_local,
        cast(tax_local as decimal(12, 4))                       as tax_local,
        cast(fx_rate_to_usd as decimal(10, 6))                  as fx_rate_to_usd,
        cast(net_revenue_usd as decimal(12, 4))                 as net_revenue_usd,

        -- discount code — convert N/A strings to proper nulls
        case
            when discount_code in ('N/A', 'n/a', '') then null
            else trim(discount_code)
        end                                                     as discount_code,

        -- refund fields
        case
            when lower(trim(is_refunded)) = 'true'  then true
            when lower(trim(is_refunded)) = 'false' then false
            else false
        end                                                     as is_refunded,

        case
            when trim(refund_reason) = '' then null
            else trim(refund_reason)
        end                                                     as refund_reason,

        -- derived date parts — useful for time series analysis
        to_char(cast(event_date as timestamp), 'YYYY-MM')       as order_month,
        date_part('year', cast(event_date as timestamp))::int   as order_year,
        date_part('month', cast(event_date as timestamp))::int  as order_month_num,
        date_part('quarter', cast(event_date as timestamp))::int as order_quarter

    from source
    where event_id is not null  -- drop 361 fully null Excel padding rows

)

select * from cleaned
