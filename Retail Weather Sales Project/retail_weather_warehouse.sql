-- ============================================================================
-- RETAIL + WEATHER DATA WAREHOUSE
-- ============================================================================
-- Source 1: online_retail_II.csv
--    Real UK-based online retailer -> Dec 2009 - Dec 2011
--    Source: Kaggle (mashlyn/online-retail-ii-uci)

-- Source 2: all_weather_data.csv
--    Real UK weather observations -> Jan 2009 - Sep 2014
--    Source: Kaggle (jakewright/2m-daily-weather-history-uk)
-- ============================================================================


CREATE DATABASE IF NOT EXISTS retail_weather;
USE retail_weather;



-- ***************** Dataset 1 - Retail dataset *****************

-- **** Raw CSV Import for retail *****
CREATE TABLE stage_online_retail (
    record_id           BIGINT NOT NULL AUTO_INCREMENT,
    invoice_id          VARCHAR(20),
    product_code        VARCHAR(20),
    product_description VARCHAR(255),
    quantity            INT,
    invoice_date        DATE,
    invoice_time        TIME,
    unit_price          DECIMAL(10,2),
    customer_id         INT NULL,
    country             VARCHAR(100),
    PRIMARY KEY (record_id)
);

-- Load Raw Retail Data
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/online_retail_II.csv'
INTO TABLE stage_online_retail
CHARACTER SET latin1
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(
    invoice_id,
    product_code,
    product_description,
    quantity,
    @invoice_datetime,
    unit_price,
    @customer_id,
    country
)
SET
    invoice_date = DATE(STR_TO_DATE(TRIM(@invoice_datetime), '%c/%e/%Y %H:%i')),
    invoice_time = TIME(STR_TO_DATE(TRIM(@invoice_datetime), '%c/%e/%Y %H:%i')),
    customer_id  = CASE 
                       WHEN TRIM(@customer_id) = '' THEN NULL 
                       ELSE CAST(CAST(TRIM(@customer_id) AS DECIMAL(15,1)) AS UNSIGNED) 
                   END,
    country      = TRIM(TRAILING '\r' FROM country);


-- Dimention tables for the retail data

-- Checks and cleanup before building the product table:
-- Temporary table for Primary Lookup (most frequent UPPERCASE description)
CREATE TEMPORARY TABLE temp_uppercase_lookup AS
SELECT 
    product_code,
    product_description
FROM (
    SELECT 
        product_code,
        TRIM(product_description) AS product_description,
        COUNT(*) AS freq,
        ROW_NUMBER() OVER (PARTITION BY product_code ORDER BY COUNT(*) DESC) AS rn  # creates different buckets/partitions that has the unique descriptions with their frequency
    FROM stage_online_retail
    WHERE product_description IS NOT NULL 
      AND TRIM(product_description) != ''
      AND CAST(TRIM(product_description) AS BINARY) = CAST(UPPER(TRIM(product_description)) AS BINARY) # checks if the description is all upper case
    GROUP BY product_code, TRIM(product_description)
) ranked_upper
WHERE rn = 1;  # gets the top-ranked description

-- Temporary table for Fallback Lookup (in case there is no product name with all uppercase)
CREATE TEMPORARY TABLE temp_fallback_lookup AS
SELECT 
    product_code,
    product_description
FROM (
    SELECT 
        product_code,
        TRIM(product_description) AS product_description,
        COUNT(*) AS freq,
        ROW_NUMBER() OVER (PARTITION BY product_code ORDER BY COUNT(*) DESC) AS rn
    FROM stage_online_retail
    WHERE product_description IS NOT NULL 
      AND TRIM(product_description) != ''
    GROUP BY product_code, TRIM(product_description)
) ranked_fallback
WHERE rn = 1;

-- Create and Populate dim_product
CREATE TABLE dim_product (
    product_code        VARCHAR(20) NOT NULL,
    product_description VARCHAR(255) NULL,
    PRIMARY KEY (product_code)
);

INSERT INTO dim_product (product_code, product_description)
SELECT DISTINCT
    s.product_code,
    COALESCE(u.product_description, f.product_description) AS product_description
FROM stage_online_retail s
LEFT JOIN temp_uppercase_lookup u ON s.product_code = u.product_code
LEFT JOIN temp_fallback_lookup f  ON s.product_code = f.product_code
WHERE s.product_code IS NOT NULL AND TRIM(s.product_code) != '';

-- Clean up temporary tables
DROP TEMPORARY TABLE IF EXISTS temp_uppercase_lookup;
DROP TEMPORARY TABLE IF EXISTS temp_fallback_lookup;



-- Creating the fact table

-- Transactional Fact Table
CREATE TABLE fact_sales (
    sales_record_id BIGINT NOT NULL AUTO_INCREMENT,
    invoice_id      VARCHAR(20) NOT NULL,
    product_code    VARCHAR(20) NOT NULL,
    customer_id     INT NULL,
    country         VARCHAR(100) NOT NULL,
    invoice_date    DATE NOT NULL,
    invoice_time    TIME NOT NULL,
    quantity        INT NOT NULL,
    unit_price      DECIMAL(10,2) NOT NULL,
    total_amount    DECIMAL(12,2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    PRIMARY KEY (sales_record_id),
    CONSTRAINT fk_sales_product FOREIGN KEY (product_code) REFERENCES dim_product(product_code)
);

-- Populate fact_sales from staging (Preserves all rows, including country and missing customer_ids)
INSERT INTO fact_sales (
    invoice_id,
    product_code,
    customer_id,
    country,
    invoice_date,
    invoice_time,
    quantity,
    unit_price
)
SELECT 
    r.invoice_id,
    r.product_code,
    r.customer_id,
    r.country,
    r.invoice_date,
    r.invoice_time,
    r.quantity,
    r.unit_price
FROM stage_online_retail r
WHERE r.product_code IS NOT NULL AND TRIM(r.product_code) != '';

-- Indexes on Fact Table
CREATE INDEX idx_fact_invoice_date ON fact_sales (invoice_date);
CREATE INDEX idx_fact_invoice_id   ON fact_sales (invoice_id);


-- ***************** Dataset 2 - UK Weather dataset *****************

-- **** Raw CSV Import for weather *****
CREATE TABLE uk_weather (
    weather_record_id       BIGINT NOT NULL AUTO_INCREMENT,
    location                VARCHAR(150),
    weather_date            DATE NOT NULL,
    min_temp_c              INT,
    max_temp_c              INT,
    rain_mm                 DECIMAL(10,2),
    humidity_pct            INT,
    cloud_cover_pct         INT,
    wind_speed_kmh          INT,
    wind_direction          VARCHAR(10),
    wind_direction_degrees  DECIMAL(6,2),
    PRIMARY KEY (weather_record_id)
);

-- Load Raw Weather Data
LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 8.0/Uploads/all_weather_data.csv'
INTO TABLE uk_weather
FIELDS TERMINATED BY ','
OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 ROWS
(
    location,
    @weather_date,
    min_temp_c,
    max_temp_c,
    rain_mm,
    humidity_pct,
    cloud_cover_pct,
    wind_speed_kmh,
    wind_direction,
    wind_direction_degrees
)
SET
    weather_date   = STR_TO_DATE(TRIM(@weather_date), '%m/%d/%Y'),
    wind_direction = TRIM(TRAILING '\r' FROM wind_direction);

-- Index on Weather Date
CREATE INDEX idx_weather_date ON uk_weather (weather_date);