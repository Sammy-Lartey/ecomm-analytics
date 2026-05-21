-- This model cleans and standardizes the raw product data, ensuring that key fields are properly formatted and that missing values are handled appropriately. 
-- It also derives new fields such as is_addon based on category information to enable more granular analysis in downstream models. 
-- The cleaned product data serves as a foundation for all product-related analyses in the project.

with source as (

    select * from {{ source('raw', 'products') }}

),

cleaned as (

    select
        -- ids
        product_id,

        -- names
        trim(product_name)                                      as product_name,
        trim(brand_safe_name)                                   as brand_safe_name,
        trim(product_name_orig)                                 as product_name_orig,
        trim(base_key)                                          as base_key,
        trim(product_version)                                   as product_version,

        -- categorisation
        trim(category)                                          as category,
        trim(vendor)                                            as vendor,
        trim(resale_model)                                      as resale_model,
        trim(billing_cycle)                                     as billing_cycle,

        -- flags
        case
            when lower(trim(is_subscription)) = 'true'  then true
            when lower(trim(is_subscription)) = 'false' then false
            else false
        end                                                     as is_subscription,

        -- derived flag — is this product an add-on?
        case
            when trim(category) = 'Add-on' then true
            else false
        end                                                     as is_addon,

        -- pricing
        cast(base_price_usd as decimal(12, 4))                  as base_price_usd,
        cast(base_price_usd_orig as decimal(12, 4))             as base_price_usd_orig,

        -- dates
        cast(first_release_date as date)                        as first_release_date

    from source
    where product_id is not null

)

select * from cleaned
