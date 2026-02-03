CREATE DATABASE airbnb_dwh;


create schema airbnb;

CREATE TABLE airbnb.customer_dim (
    customer_id INT, 
    first_name NVARCHAR(100),
    last_name NVARCHAR(100),
    email NVARCHAR(255),
    phone_number NVARCHAR(50),
    address NVARCHAR(255),
    city NVARCHAR(100),
    state NVARCHAR(100),
    country NVARCHAR(100),
    zip_code NVARCHAR(20),
    signup_date DATE,
    last_login DATETIME,
    total_bookings INT,
    total_spent DECIMAL(10, 2),
    preferred_language NVARCHAR(50),
    referral_code NVARCHAR(50),
    account_status NVARCHAR(50)
);

select * from airbnb.customer_dim;

-------------------------------------------------

CREATE TABLE airbnb.bookings_fact (
    booking_id NVARCHAR(100),
    property_id NVARCHAR(100),
    customer_id INT,
    owner_id NVARCHAR(100),
    check_in_date DATE,
    check_out_date DATE,
    booking_date DATETIME,
    amount FLOAT,
    currency NVARCHAR(10),
    city NVARCHAR(100),
    country NVARCHAR(100),
    full_address NVARCHAR(255),
    stay_duration BIGINT,
    booking_year INT,
    booking_month INT,
    timestamp DATETIME
);

select * from airbnb.bookings_fact;

CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'GrowDataSkills@123';
OPEN MASTER KEY DECRYPTION BY PASSWORD = 'GrowDataSkills@123';

------------------------------------

CREATE TABLE airbnb.BookingCustomerAggregation
WITH (DISTRIBUTION = ROUND_ROBIN)
AS
SELECT 
    c.country,
    COUNT_BIG(*) AS total_bookings,
    SUM(ISNULL(b.amount, 0)) AS total_amount,
    MAX(b.booking_date) AS last_booking_date
FROM 
    airbnb.bookings_fact b
JOIN 
    airbnb.customer_dim c ON b.customer_id = c.customer_id
GROUP BY 
    c.country;

CREATE PROCEDURE airbnb.BookingAggregation
AS
BEGIN
    TRUNCATE TABLE airbnb.BookingCustomerAggregation;

    INSERT INTO airbnb.BookingCustomerAggregation
    SELECT 
        c.country,
        COUNT_BIG(*) AS total_bookings,
        SUM(ISNULL(b.amount, 0)) AS total_amount,
        MAX(b.booking_date) AS last_booking_date
    FROM 
        airbnb.bookings_fact b
    JOIN 
        airbnb.customer_dim c ON b.customer_id = c.customer_id
    GROUP BY 
        c.country;
END;

EXEC [airbnb].[BookingAggregation];

select * from airbnb.BookingCustomerAggregation;




-- For Linked Services connnection
-- Connect to your Synapse SQL pool (airbnb_dwh) and run:
CREATE USER [azure-airbnb-cdc-ingestion-pipeline] FROM EXTERNAL PROVIDER;
EXEC sp_addrolemember 'db_datareader', [azure-airbnb-cdc-ingestion-pipeline];
EXEC sp_addrolemember 'db_datawriter', [azure-airbnb-cdc-ingestion-pipeline];
EXEC sp_addrolemember 'db_ddladmin', [azure-airbnb-cdc-ingestion-pipeline];
