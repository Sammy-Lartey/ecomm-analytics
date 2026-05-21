-- This model cleans and standardizes the raw customer data, ensuring that key fields are properly formatted and that missing values are handled appropriately. 
-- It also derives new fields such as region based on country information to enable more granular analysis in downstream models. 
-- The cleaned customer data serves as a foundation for all customer-related analyses in the project.

with source as (

    select * from {{ source('raw', 'customers') }}

),

cleaned as (

    select
        -- ids
        customer_id,

        -- dates
        cast(signup_date as timestamp)                          as signup_date,

        -- location
        trim(country)                                           as country,
        cast(country_latitude as decimal(10, 4))                as country_latitude,
        cast(country_longitude as decimal(10, 4))               as country_longitude,

        -- region — same fill logic as stg_events
        case
            when region is null or trim(region) = ''
                then case trim(country)
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
            else trim(region)
        end                                                     as region,

        -- customer profile
        trim(segment)                                           as segment,
        trim(age_band)                                          as age_band,
        trim(acquisition_channel)                               as acquisition_channel,
        trim(currency_preference)                               as currency_preference

    from source
    where customer_id is not null

)

select * from cleaned
