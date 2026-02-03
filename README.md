# Azure-airbnb-cdc-ingestion-pipeline
Tech Stack : Python, ADLS, CosmosDB, Azure Data Factory, Azure Synapse, SQL

# AirBnB CDC Pipeline - Architecture Deep Dive

## 📐 Architecture Overview

This document provides a comprehensive explanation of the architecture, design decisions, and technical implementation details of the AirBnB CDC Ingestion Pipeline.

## 🎨 Architecture Patterns

### 1. Lambda Architecture (Simplified)
The pipeline implements a simplified version of Lambda Architecture with two data paths:

**Batch Layer** (Customer Data):
- Source: CSV files in ADLS
- Frequency: Hourly processing
- Pattern: ETL (Extract, Transform, Load)
- Use Case: Slowly changing dimension data

**Speed Layer** (Booking Data):
- Source: CosmosDB Change Feed
- Frequency: Near real-time (event-driven)
- Pattern: Streaming CDC
- Use Case: Fast-changing transactional data

### 2. Medallion Architecture (Bronze-Silver-Gold)

Although simplified, the pipeline follows medallion principles:

**Bronze Layer** (Raw Data):
```
ADLS: customer_data/*.csv
CosmosDB: Raw booking events
```

**Silver Layer** (Cleaned & Validated):
```
Data Flow Transformations:
- Data quality checks
- Schema validation
- Bad records filtering
- Type conversions
```

**Gold Layer** (Business-Ready):
```
Synapse Tables:
- customer_dim (Dimension)
- bookings_fact (Fact)
- BookingCustomerAggregation (Aggregates)
```

## 🔄 Change Data Capture (CDC) Implementation

### CosmosDB Change Feed

**How it Works**:
1. CosmosDB maintains a change feed log for all inserts and updates
2. Change feed provides a persistent, ordered stream of changes
3. ADF reads from change feed using continuation tokens
4. Only new/changed documents since last read are processed

**Configuration**:
```json
{
  "enableChangeFeed": true,
  "changeFeedStartFromTheBeginning": true
}
```

**Benefits**:
- No polling overhead
- Exactly-once delivery guarantee
- Automatic checkpoint management
- Scalable to millions of changes/second

### SCD Type 1 Implementation

For `customer_dim` table:
- Updates overwrite existing records
- No historical tracking
- Simple upsert logic based on customer_id
- Suitable for reference data where history is not critical

**Example**:
```
Initial State:
customer_id=1, name="John Doe", city="New York"

After Update:
customer_id=1, name="John Doe", city="Boston"
(Previous city value is lost)
```

### Upsert Pattern in Data Flow

The pipeline uses a sophisticated upsert pattern:

1. **Lookup Existing Records**:
```
DerivedColumns (new data)
    ↓
Lookup Join with SynapseLookUp (existing data)
    ON booking_id
```

2. **Determine Operation**:
```
alterRowForUpdate:
- insertIf(isNull(SynapseLookUp@booking_id))
- updateIf(not(isNull(SynapseLookUp@booking_id)))
```

3. **Execute Upsert**:
```
SynapseFactWrite Sink:
- insertable: true
- updateable: true
- upsertable: true
- keys: [booking_id]
```

## 🏗️ Component Architecture

### 1. Data Sources

#### Python Data Generator
```python
Purpose: Simulate real-time booking events
Technology: Python + Faker library
Output: JSON documents to CosmosDB
Frequency: Continuous (simulated real-time)

Sample Output:
{
  "booking_id": "BK123456",
  "property_id": "PR789",
  "customer_id": 42,
  "owner_id": "OW456",
  "check_in_date": "2024-03-15",
  "check_out_date": "2024-03-20",
  "booking_date": "2024-03-01 14:30:00",
  "amount": 1250.00,
  "currency": "USD",
  "property_location": {
    "city": "New York",
    "country": "USA"
  },
  "timestamp": "2024-03-01T14:30:00Z"
}
```

#### Customer CSV Files
```
Format: CSV
Location: ADLS/customer_data/
Naming: cust_yyyy_mm_dd_hh_mm_ss.csv
Upload: Manual or automated process
Frequency: Hourly batches
```

### 2. Azure Data Lake Storage (ADLS)

**Container Structure**:
```
airbnb-data-lake/
├── customer_data/           # Raw customer CSV files
│   ├── cust_2024_02_03_01_00_00.csv
│   ├── cust_2024_02_03_02_00_00.csv
│   └── ...
│
├── archive/                 # Processed files moved here
│   ├── cust_2024_02_03_01_00_00.csv
│   └── ...
│
└── rejected_data/          # Bad records from Data Flow
    ├── bookings_rejected_20240203.csv
    └── ...
```

**Access Control**:
- Managed Identity authentication
- RBAC roles assigned to ADF
- Storage Blob Data Contributor role

### 3. Azure Cosmos DB

**Configuration**:
```
Account: cosmos-airbnb-cdc
Database: AirBnB
Container: Bookings
Partition Key: /booking_id
Throughput: 400 RU/s (autoscale up to 4000)
Consistency: Session (default)
Change Feed: Enabled
```

**Indexing Policy**:
```json
{
  "indexingMode": "consistent",
  "includedPaths": [
    { "path": "/booking_id/?" },
    { "path": "/customer_id/?" },
    { "path": "/booking_date/?" },
    { "path": "/timestamp/?" }
  ]
}
```

### 4. Azure Data Factory

#### Linked Services
```
1. AirBnBADLS
   - Type: Azure Data Lake Storage Gen2
   - Auth: Managed Identity
   - Purpose: Access customer CSV files

2. CosmosDBConnection
   - Type: Azure Cosmos DB (NoSQL)
   - Auth: Account Key (stored in Key Vault)
   - Purpose: Read change feed

3. SynapseConnection
   - Type: Azure Synapse Analytics
   - Auth: Managed Identity
   - Purpose: Write to data warehouse
```

#### Datasets
```
1. CustomerDataCSV
   - Type: DelimitedText
   - Location: ADLS/customer_data/*.csv
   - Schema: Auto-detect

2. BookingDataCosmosDB
   - Type: CosmosDB Collection
   - Container: Bookings
   - Change Feed: Enabled

3. CustomerDimSynapse
   - Type: Azure Synapse Analytics Table
   - Schema: airbnb
   - Table: customer_dim

4. BookingFactDataSynapse
   - Type: Azure Synapse Analytics Table
   - Schema: airbnb
   - Table: bookings_fact
```

### 5. Data Flow Transformations

#### Transformation Graph
```
┌─────────────────────────────────────────────────────────────────┐
│                        Data Flow: BookingDataTransformation      │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Sources:                                                        │
│  ┌─────────────────┐      ┌─────────────────┐                  │
│  │  BookingData    │      │ SynapseLookUp   │                  │
│  │  (CosmosDB)     │      │ (Synapse Table) │                  │
│  └────────┬────────┘      └────────┬────────┘                  │
│           │                        │                             │
│           │                        │                             │
│  ┌────────▼───────────────────────┐│                            │
│  │  dataQualityCheck (Split)      ││                            │
│  │  Condition:                     ││                            │
│  │  check_out_date < check_in_date││                            │
│  └───┬─────────────────────┬──────┘│                            │
│      │                     │        │                            │
│  ┌───▼────────┐    ┌───────▼──────┐│                            │
│  │BadRecords  │    │AcceptedRecords│                            │
│  │(Filtered)  │    └───────┬───────┘                            │
│  └────────────┘            │                                     │
│                    ┌───────▼────────┐                           │
│                    │ DerivedColumns │                           │
│                    │ Calculations:  │                           │
│                    │ - stay_duration│                           │
│                    │ - booking_year │                           │
│                    │ - booking_month│                           │
│                    │ - full_address │                           │
│                    │ - city, country│                           │
│                    └───────┬────────┘                           │
│                            │                                     │
│                    ┌───────▼────────┐                           │
│                    │ lookupInSynapse├─────┐                     │
│                    │ (Left Join)    │     │                     │
│                    └───────┬────────┘     │                     │
│                            │              │                     │
│                    ┌───────▼────────┐     │                     │
│                    │alterRowForUpdate│    │                     │
│                    │ Insert/Update   │    │                     │
│                    │ Logic           │    │                     │
│                    └───────┬────────┘     │                     │
│                            │              │                     │
│                    ┌───────▼────────┐     │                     │
│                    │  finalColumns  │     │                     │
│                    │  (Select Map)  │     │                     │
│                    └───────┬────────┘     │                     │
│                            │              │                     │
│  Sink:                     │              │                     │
│  ┌─────────────────────────▼──────────────▼─────┐              │
│  │         SynapseFactWrite                      │              │
│  │         (Upsert to bookings_fact)             │              │
│  │         Rejected Data → ADLS                  │              │
│  └───────────────────────────────────────────────┘              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

#### Key Transformations Explained

**1. dataQualityCheck (Conditional Split)**
```
Purpose: Separate valid and invalid records
Logic:
  IF check_out_date < check_in_date THEN
    BadRecords
  ELSE
    AcceptedRecords
  END IF

Why: Prevent logically impossible bookings from entering the warehouse
```

**2. DerivedColumns**
```
Transformation: Add calculated fields

stay_duration = (toTimestamp(check_out_date, 'yyyy-MM-dd') - 
                 toTimestamp(check_in_date, 'yyyy-MM-dd')) / 86400000

Why: Convert milliseconds to days (86400000 ms = 1 day)

booking_year = year(toTimestamp(booking_date, 'yyyy-MM-dd HH:mm:ss'))
booking_month = month(toTimestamp(booking_date, 'yyyy-MM-dd HH:mm:ss'))

Why: Enable time-based analysis and partitioning

full_address = concat(property_location.city, ', ', property_location.country)
city = property_location.city
country = property_location.country

Why: Flatten nested JSON structure for easier querying
```

**3. lookupInSynapse (Lookup Transformation)**
```
Type: Left Outer Join
Key: DerivedColumns@booking_id = SynapseLookUp@booking_id
Order: DESC by SynapseLookUp@timestamp
Pickup: First (most recent)
Broadcast: Auto

Purpose: Find if booking already exists to determine insert vs update
Output: Combined stream with both new and existing data
```

**4. alterRowForUpdate (Alter Row)**
```
Insert Condition: isNull(SynapseLookUp@booking_id)
Update Condition: not(isNull(SynapseLookUp@booking_id))

Why: Mark each row for appropriate DML operation
Result: Metadata added to control sink behavior
```

**5. finalColumns (Select)**
```
Purpose: Map columns to final schema
Action: Select only required columns from DerivedColumns
Exclude: Lookup columns used only for logic
```

### 6. Azure Synapse Analytics

#### Architecture
```
Synapse Workspace: synapse-airbnb-cdc
SQL Pool: airbnb_dwh (DW100c)
Performance Tier: Entry-level (100 DWU)
Storage: Integrated with ADLS Gen2
```

#### Distribution Strategy

**customer_dim**:
```sql
-- HASH distribution on customer_id
CREATE TABLE airbnb.customer_dim (...)
WITH (
    DISTRIBUTION = HASH(customer_id),
    CLUSTERED COLUMNSTORE INDEX
);

Why: Even data distribution for customer lookups
```

**bookings_fact**:
```sql
-- HASH distribution on booking_id
CREATE TABLE airbnb.bookings_fact (...)
WITH (
    DISTRIBUTION = HASH(booking_id),
    CLUSTERED COLUMNSTORE INDEX
);

Why: Optimal for upsert operations and fact table queries
```

**BookingCustomerAggregation**:
```sql
-- ROUND_ROBIN distribution
CREATE TABLE airbnb.BookingCustomerAggregation (...)
WITH (
    DISTRIBUTION = ROUND_ROBIN
);

Why: Small lookup table, round-robin is simplest and sufficient
```

#### Indexing Strategy
```
Clustered Columnstore Index (CCI):
- Default for all tables
- Excellent compression (5-10x)
- Fast for analytical queries
- Batch size: 1,048,576 rows for optimal compression

Note: For production, consider adding:
- Nonclustered indexes on foreign keys
- Statistics on frequently filtered columns
- Partitioning on date columns for large fact tables
```

## 🔐 Security Architecture

### Authentication & Authorization

**Managed Identity Flow**:
```
1. ADF System-Assigned Managed Identity
   ↓
2. Azure AD authenticates the identity
   ↓
3. RBAC roles grant permissions:
   - Storage Blob Data Contributor (ADLS)
   - Cosmos DB Data Contributor (CosmosDB)
   - Synapse SQL Database Contributor (Synapse)
   ↓
4. Token-based access (no credentials in code)
```

**Synapse Authentication**:
```sql
-- Create user for ADF Managed Identity
CREATE USER [adf-airbnb-cdc] FROM EXTERNAL PROVIDER;

-- Grant necessary permissions
EXEC sp_addrolemember 'db_datareader', [adf-airbnb-cdc];
EXEC sp_addrolemember 'db_datawriter', [adf-airbnb-cdc];
EXEC sp_addrolemember 'db_ddladmin', [adf-airbnb-cdc];
```

### Data Encryption

**At Rest**:
- ADLS: Microsoft-managed keys (default) or Customer-managed keys (CMK)
- CosmosDB: Automatic encryption with service-managed keys
- Synapse: Transparent Data Encryption (TDE) enabled

**In Transit**:
- All connections use HTTPS/TLS 1.2+
- Certificate-based authentication for Synapse
- Secure token exchange for CosmosDB

### Network Security

**Private Endpoints** (Recommended for Production):
```
Azure Virtual Network
├── Subnet: adf-subnet
│   └── ADF Managed VNet Integration
├── Subnet: synapse-subnet
│   └── Synapse Private Endpoint
├── Subnet: storage-subnet
│   └── ADLS Private Endpoint
└── Subnet: cosmos-subnet
    └── CosmosDB Private Endpoint
```

**Firewall Rules**:
```
ADLS: Allow trusted Azure services
CosmosDB: Specific ADF IP ranges or VNet rules
Synapse: Firewall rules for allowed IPs
```

## 📊 Performance Optimization

### Data Flow Optimization

**Partition Configuration**:
```
Source Partitioning:
- CosmosDB: Auto-partitioned by partition key
- Optimal: 4-8 partitions per Spark executor core

Compute:
- Cluster Size: 4 driver cores, 8 executor cores
- Memory: 28 GB per executor
- Auto-scaling: Enabled (min 4, max 16 cores)
```

**Caching**:
```
When to Cache:
- Lookup datasets (SynapseLookUp)
- Small dimension tables
- Datasets used multiple times in flow

Benefit: Avoid re-reading same data
```

**Broadcast Joins**:
```
lookup configuration:
  broadcast: 'auto'
  
Effect: Small table broadcasted to all executors
Threshold: Tables < 10MB
```

### Synapse Optimization

**Statistics**:
```sql
-- Create statistics for optimal query plans
CREATE STATISTICS stat_booking_id ON airbnb.bookings_fact(booking_id);
CREATE STATISTICS stat_customer_id ON airbnb.bookings_fact(customer_id);
CREATE STATISTICS stat_booking_date ON airbnb.bookings_fact(booking_date);

-- Update statistics after significant data changes
UPDATE STATISTICS airbnb.bookings_fact;
```

**Query Optimization**:
```sql
-- Use result set caching for repeated queries
SET RESULT_SET_CACHING ON;

-- Use temp tables for complex multi-step transformations
CREATE TABLE #temp_bookings AS
SELECT ...
FROM airbnb.bookings_fact
WHERE ...;

-- Leverage materialized views for frequent aggregations
CREATE MATERIALIZED VIEW mv_monthly_revenue AS
SELECT 
    booking_year,
    booking_month,
    country,
    SUM(amount) as total_revenue
FROM airbnb.bookings_fact
GROUP BY booking_year, booking_month, country;
```

## 🔄 Pipeline Orchestration

### Dependency Chain
```
Hourly Trigger (3600s)
    ↓
Pipeline 1: LoadCustomerDim
    │
    ├─ Success ─→ Pipeline 2: LoadBookingFact
    │                  │
    │                  ├─ Success ─→ Pipeline 3: ExecuteStoredProcedure
    │                  │
    │                  └─ Failure ─→ Send Alert
    │
    └─ Failure ─→ Retry (3 times) ─→ Send Alert
```

### Error Handling Strategy

**Retry Policy**:
```json
{
  "retryPolicy": {
    "count": 3,
    "intervalInSeconds": 30,
    "policy": "exponential"
  },
  "timeout": "01:00:00"
}
```

**Failure Actions**:
```
On Pipeline Failure:
1. Log error details to Log Analytics
2. Write failed records to rejected_data container
3. Send email notification (Logic App)
4. Create incident ticket (optional)
5. Trigger failure webhook (optional)
```

## 📈 Scalability Considerations

### Horizontal Scaling
```
Data Flow:
- Auto-scale Spark cluster (4-16 cores)
- Partition data for parallel processing
- Optimize partition count based on data volume

CosmosDB:
- Autoscale RU/s (400-4000)
- Partition by booking_id for even distribution
- Add read replicas for global distribution

Synapse:
- Scale DWU up/down based on load
- Pause during non-business hours
- Implement workload management groups
```

### Data Volume Projections
```
Current: ~1K bookings/hour
Expected Growth: 10x in 1 year

Recommendations:
1. Partition bookings_fact by year/month
2. Implement data archival strategy (> 2 years)
3. Use polybase for bulk loads (> 100K rows)
4. Consider Azure Synapse Serverless for cold data
```

## 🎓 Lessons Learned & Best Practices

### Common Pitfalls

1. **Quoted Column Names in Keys**
   - ❌ `keys:[(booking_id)]`
   - ✅ `keys:[booking_id]`

2. **Missing Column Mappings**
   - Always map ALL required columns in sink
   - Use explicit mapping, not auto-mapping

3. **Timestamp Handling**
   - Use consistent format: `'yyyy-MM-dd HH:mm:ss'`
   - Handle timezone conversions explicitly

4. **Large Dimension Tables**
   - Don't broadcast joins for tables > 10MB
   - Use merge joins for large-to-large joins

### Recommendations

1. **Testing**
   - Use Data Flow Debug mode
   - Test with sample data before full run
   - Validate transformations with known inputs/outputs

2. **Monitoring**
   - Set up alerts for all pipeline failures
   - Monitor Data Flow execution time trends
   - Track Synapse DWU utilization

3. **Cost Optimization**
   - Pause Synapse during non-business hours
   - Use CosmosDB autoscale (not provisioned)
   - Leverage ADLS lifecycle management for archives
   - Right-size Data Flow cluster

4. **Data Quality**
   - Implement data quality rules in Data Flow
   - Add constraints in Synapse tables
   - Monitor rejected records regularly
   - Create data quality dashboards

## 🔮 Future State Architecture

### Proposed Enhancements

**1. Advanced CDC with SCD Type 2**
```sql
ALTER TABLE airbnb.customer_dim ADD
    effective_date DATETIME,
    end_date DATETIME,
    is_current BIT;

-- Track full history of customer changes
```

**2. Real-time Dashboards**
```
Power BI Direct Query ← Synapse Serverless ← ADLS Delta Lake
Benefits:
- Near real-time visualizations
- No data movement
- Cost-effective for large datasets
```

**3. Data Lineage with Purview**
```
Azure Purview
├── Scan ADLS
├── Scan CosmosDB
├── Scan Synapse
└── Generate lineage graphs automatically
```

**4. Advanced Analytics**
```
Azure Synapse Spark Pools
├── ML Model Training (booking prediction)
├── Anomaly Detection (fraud detection)
└── Advanced Analytics (customer segmentation)
```

## 📚 References

- [Azure Data Factory Documentation](https://docs.microsoft.com/azure/data-factory/)
- [Azure Synapse Analytics Documentation](https://docs.microsoft.com/azure/synapse-analytics/)
- [Cosmos DB Change Feed](https://docs.microsoft.com/azure/cosmos-db/change-feed)
- [Data Flow Transformations](https://docs.microsoft.com/azure/data-factory/data-flow-transformation-overview)

---

**Document Version**: 1.0  
**Last Updated**: February 2026  
**Author**: Mohammed Tousif
