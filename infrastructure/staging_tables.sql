-- Run once in Redshift Query Editor v2 after terraform apply
-- Creates the three staging tables used by the incremental pipeline

-- Events staging — mirrors raw.events exactly
CREATE TABLE IF NOT EXISTS raw.events_staging (LIKE raw.events);

-- Products staging — mirrors raw.products exactly  
CREATE TABLE IF NOT EXISTS raw.products_staging (LIKE raw.products);

-- Customers staging — mirrors raw.customers exactly
CREATE TABLE IF NOT EXISTS raw.customers_staging (LIKE raw.customers);
