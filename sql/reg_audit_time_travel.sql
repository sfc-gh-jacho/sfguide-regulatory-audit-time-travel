/*
================================================================================
 REGULATORY REPORTING WITH TIME TRAVEL AND AUDIT TRAIL - DEMO SCRIPT
 Prove what your data said on the filing date, what changed, and who changed it:
 - Time Travel (AT / BEFORE) and data retention
 - Zero-copy clones as frozen regulatory snapshots
 - Streams as a change audit trail
 - Query and access history ("who changed it")
 - UNDROP for accidental deletes

 Scenario: three fictional legal entities file a quarter-end capital report.
 After filing, three booking errors are corrected. The regulator asks for the
 report as filed, the list of changes, and who made them.

 The capital ratio in this script is a SIMPLIFIED, ILLUSTRATIVE calculation.
 It is not a real regulatory capital methodology.

 This script creates its own objects (REG_AUDIT_DEMO_DB, REG_AUDIT_WH) and
 changes nothing that already exists. Step 11 removes everything.

 TIP: Run the script top to bottom in ONE Snowsight worksheet. Later steps use
 session variables ($filing_ts, $fix_qid) set in earlier steps.

 ALL DATA IN THIS SCRIPT IS SYNTHETIC.
================================================================================
*/

-- [step:setup]
-- ============================================================================
-- STEP 1: SETUP - Database, Warehouse and Data Retention
-- ============================================================================

USE ROLE ACCOUNTADMIN;

CREATE WAREHOUSE IF NOT EXISTS REG_AUDIT_WH
    WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE REG_AUDIT_WH;

CREATE OR REPLACE DATABASE REG_AUDIT_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS REG_AUDIT_DEMO_DB.REPORTING;
USE SCHEMA REG_AUDIT_DEMO_DB.REPORTING;

-- Time Travel retention: how far back you can query, clone or undrop.
-- 7 days requires Enterprise Edition or higher (maximum 90).
-- On Standard Edition the maximum is 1 day: change 7 to 1.
ALTER DATABASE REG_AUDIT_DEMO_DB SET DATA_RETENTION_TIME_IN_DAYS = 7;

SHOW PARAMETERS LIKE 'DATA_RETENTION_TIME_IN_DAYS' IN DATABASE REG_AUDIT_DEMO_DB;

-- [step:load]
-- ============================================================================
-- STEP 2: LOAD SYNTHETIC POSITIONS
-- ============================================================================

-- Fictional legal entities and their (illustrative) Tier 1 capital
CREATE OR REPLACE TABLE REG_LEGAL_ENTITIES (
    LEGAL_ENTITY        VARCHAR(40),
    TIER1_CAPITAL_USD   NUMBER(18,2)
);
INSERT INTO REG_LEGAL_ENTITIES VALUES
    ('HARBOR_POINT_BANK',        950000000),
    ('SUMMIT_RIDGE_SECURITIES',  420000000),
    ('LAKESIDE_TRUST_CO',        180000000);

-- Simplified, illustrative risk weights by instrument type
CREATE OR REPLACE TABLE REG_RISK_WEIGHTS (
    INSTRUMENT_TYPE  VARCHAR(20),
    RISK_WEIGHT      NUMBER(5,2)
);
INSERT INTO REG_RISK_WEIGHTS VALUES
    ('GOVT_BOND', 0.00), ('MORTGAGE', 0.50), ('CORP_BOND', 1.00),
    ('LOAN',      1.00), ('EQUITY',   2.50);

-- 1,000 positions generated deterministically (same data on every run)
CREATE OR REPLACE TABLE REG_POSITIONS (
    POSITION_ID      NUMBER,
    LEGAL_ENTITY     VARCHAR(40),
    BOOK             VARCHAR(20),
    INSTRUMENT_TYPE  VARCHAR(20),
    COUNTERPARTY     VARCHAR(20),
    NOTIONAL_USD     NUMBER(18,2),
    TRADE_DATE       DATE
);

INSERT INTO REG_POSITIONS
SELECT
    SEQ4() + 1                                                              AS position_id,
    DECODE(MOD(SEQ4(), 3), 0, 'HARBOR_POINT_BANK',
                           1, 'SUMMIT_RIDGE_SECURITIES',
                              'LAKESIDE_TRUST_CO')                          AS legal_entity,
    DECODE(MOD(SEQ4(), 4), 0, 'RATES', 1, 'CREDIT', 2, 'LENDING', 'EQUITIES') AS book,
    DECODE(MOD(ABS(HASH(SEQ4(), 'type')), 5), 0, 'GOVT_BOND', 1, 'MORTGAGE',
                                              2, 'CORP_BOND', 3, 'LOAN', 'EQUITY') AS instrument_type,
    'CPTY_' || LPAD(MOD(ABS(HASH(SEQ4(), 'cpty')), 60) + 1, 3, '0')       AS counterparty,
    ROUND(500000 + MOD(ABS(HASH(SEQ4(), 'amt')), 9500000), -3)              AS notional_usd,
    DATEADD(DAY, -MOD(ABS(HASH(SEQ4(), 'dt')), 90), '2026-09-30'::DATE)     AS trade_date
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

-- Plant the three errors that will be corrected after filing:
-- (a) a "fat finger" notional on position 42 (10x too large)
UPDATE REG_POSITIONS SET NOTIONAL_USD = NOTIONAL_USD * 10 WHERE POSITION_ID = 42;
-- (b) position 1001 is an accidental duplicate booking of position 500
INSERT INTO REG_POSITIONS
SELECT 1001, LEGAL_ENTITY, BOOK, INSTRUMENT_TYPE, COUNTERPARTY, NOTIONAL_USD, TRADE_DATE
FROM REG_POSITIONS WHERE POSITION_ID = 500;
-- (c) a late trade (booked after filing) is simply missing for now

SELECT LEGAL_ENTITY, COUNT(*) AS positions, SUM(NOTIONAL_USD) AS total_notional
FROM REG_POSITIONS GROUP BY LEGAL_ENTITY ORDER BY LEGAL_ENTITY;

-- [step:file]
-- ============================================================================
-- STEP 3: RUN AND "FILE" THE QUARTER-END REPORT
-- ============================================================================

-- Illustrative capital report: risk-weighted assets and capital ratio
CREATE OR REPLACE VIEW REG_CAPITAL_REPORT AS
SELECT
    p.LEGAL_ENTITY,
    COUNT(*)                                            AS position_count,
    SUM(p.NOTIONAL_USD)                                 AS total_notional_usd,
    SUM(p.NOTIONAL_USD * w.RISK_WEIGHT)                 AS rwa_usd,
    e.TIER1_CAPITAL_USD,
    ROUND(e.TIER1_CAPITAL_USD / NULLIF(SUM(p.NOTIONAL_USD * w.RISK_WEIGHT), 0) * 100, 2)
                                                        AS tier1_ratio_pct
FROM REG_POSITIONS p
JOIN REG_RISK_WEIGHTS   w ON p.INSTRUMENT_TYPE = w.INSTRUMENT_TYPE
JOIN REG_LEGAL_ENTITIES e ON p.LEGAL_ENTITY    = e.LEGAL_ENTITY
GROUP BY p.LEGAL_ENTITY, e.TIER1_CAPITAL_USD;

-- The report submitted to the regulator
SELECT * FROM REG_CAPITAL_REPORT ORDER BY LEGAL_ENTITY;

-- Record the exact filing point. A short wait on each side makes sure the
-- timestamp sits cleanly after the data load and before any later change.
CALL SYSTEM$WAIT(2);
SET filing_ts = CURRENT_TIMESTAMP();
CALL SYSTEM$WAIT(2);
SELECT $filing_ts AS filing_timestamp;

-- [step:stream]
-- ============================================================================
-- STEP 4: START AN AUDIT TRAIL WITH A STREAM
-- ============================================================================
-- A stream records every insert, update and delete made after this point,
-- with the before and after values.

CREATE OR REPLACE STREAM REG_POSITIONS_CHANGES ON TABLE REG_POSITIONS;

-- [step:corrections]
-- ============================================================================
-- STEP 5: POST-FILING CORRECTIONS
-- ============================================================================
-- Two weeks after filing, operations fixes three booking errors.

-- (a) Correct the fat-finger notional on position 42
UPDATE REG_POSITIONS SET NOTIONAL_USD = NOTIONAL_USD / 10 WHERE POSITION_ID = 42;
SET fix_qid = LAST_QUERY_ID();   -- remember the first correction statement

-- (b) Remove the duplicate booking
DELETE FROM REG_POSITIONS WHERE POSITION_ID = 1001;

-- (c) Book the late trade that belonged in the quarter
INSERT INTO REG_POSITIONS VALUES
    (2001, 'LAKESIDE_TRUST_CO', 'LENDING', 'LOAN', 'CPTY_017', 85000000, '2026-09-29');

-- [step:compare]
-- ============================================================================
-- STEP 6: REPORT AS FILED VS. REPORT NOW
-- ============================================================================

-- The current (corrected) report
SELECT * FROM REG_CAPITAL_REPORT ORDER BY LEGAL_ENTITY;

-- The report exactly as filed: same logic, positions as of the filing time
SELECT
    p.LEGAL_ENTITY,
    COUNT(*)                                            AS position_count,
    SUM(p.NOTIONAL_USD)                                 AS total_notional_usd,
    SUM(p.NOTIONAL_USD * w.RISK_WEIGHT)                 AS rwa_usd,
    ROUND(e.TIER1_CAPITAL_USD / NULLIF(SUM(p.NOTIONAL_USD * w.RISK_WEIGHT), 0) * 100, 2)
                                                        AS tier1_ratio_pct
FROM REG_POSITIONS AT(TIMESTAMP => $filing_ts) p
JOIN REG_RISK_WEIGHTS   w ON p.INSTRUMENT_TYPE = w.INSTRUMENT_TYPE
JOIN REG_LEGAL_ENTITIES e ON p.LEGAL_ENTITY    = e.LEGAL_ENTITY
GROUP BY p.LEGAL_ENTITY, e.TIER1_CAPITAL_USD
ORDER BY p.LEGAL_ENTITY;

-- Alternative: state just BEFORE the first correction statement ran
SELECT COUNT(*) AS positions_before_first_fix
FROM REG_POSITIONS BEFORE(STATEMENT => $fix_qid);

-- Side-by-side: filed vs. corrected, with the difference
WITH filed AS (
    SELECT p.LEGAL_ENTITY, SUM(p.NOTIONAL_USD * w.RISK_WEIGHT) AS rwa_usd
    FROM REG_POSITIONS AT(TIMESTAMP => $filing_ts) p
    JOIN REG_RISK_WEIGHTS w ON p.INSTRUMENT_TYPE = w.INSTRUMENT_TYPE
    GROUP BY p.LEGAL_ENTITY
),
corrected AS (
    SELECT LEGAL_ENTITY, rwa_usd, tier1_ratio_pct FROM REG_CAPITAL_REPORT
)
SELECT
    c.LEGAL_ENTITY,
    f.rwa_usd                                           AS rwa_as_filed,
    c.rwa_usd                                           AS rwa_corrected,
    c.rwa_usd - f.rwa_usd                               AS rwa_change,
    ROUND(e.TIER1_CAPITAL_USD / NULLIF(f.rwa_usd, 0) * 100, 2) AS ratio_as_filed_pct,
    c.tier1_ratio_pct                                   AS ratio_corrected_pct
FROM corrected c
JOIN filed f              ON c.LEGAL_ENTITY = f.LEGAL_ENTITY
JOIN REG_LEGAL_ENTITIES e ON c.LEGAL_ENTITY = e.LEGAL_ENTITY
ORDER BY c.LEGAL_ENTITY;

-- [step:snapshot]
-- ============================================================================
-- STEP 7: FREEZE THE FILING WITH A ZERO-COPY CLONE
-- ============================================================================
-- Time Travel only reaches back as far as the retention period. A clone taken
-- AT the filing time keeps that exact state permanently, without copying data.

CREATE OR REPLACE TABLE REG_POSITIONS_Q3_FILED
    CLONE REG_POSITIONS AT(TIMESTAMP => $filing_ts);

-- Mark it so nobody mistakes it for live data
COMMENT ON TABLE REG_POSITIONS_Q3_FILED IS
    'Frozen snapshot of REG_POSITIONS as filed for Q3 2026. Do not modify.';

SELECT 'LIVE (corrected)'            AS version, COUNT(*) AS positions, SUM(NOTIONAL_USD) AS total_notional FROM REG_POSITIONS
UNION ALL
SELECT 'TIME TRAVEL (as filed)',     COUNT(*), SUM(NOTIONAL_USD) FROM REG_POSITIONS AT(TIMESTAMP => $filing_ts)
UNION ALL
SELECT 'SNAPSHOT CLONE (as filed)',  COUNT(*), SUM(NOTIONAL_USD) FROM REG_POSITIONS_Q3_FILED;

-- [step:audit]
-- ============================================================================
-- STEP 8: WHAT CHANGED - BUILD THE AUDIT LOG FROM THE STREAM
-- ============================================================================
-- An UPDATE appears in a stream as a DELETE (old row) + INSERT (new row) pair
-- with METADATA$ISUPDATE = TRUE.

-- Peek at the raw stream (reading it does not consume it)
SELECT POSITION_ID, NOTIONAL_USD, METADATA$ACTION, METADATA$ISUPDATE
FROM REG_POSITIONS_CHANGES
ORDER BY POSITION_ID, METADATA$ACTION;

-- Persist a readable audit log. Inserting FROM the stream consumes it, so the
-- next run captures only new changes.
CREATE OR REPLACE TABLE REG_AUDIT_LOG (
    POSITION_ID    NUMBER,
    CHANGE_TYPE    VARCHAR(10),
    LEGAL_ENTITY   VARCHAR(40),
    OLD_NOTIONAL   NUMBER(18,2),
    NEW_NOTIONAL   NUMBER(18,2),
    CAPTURED_AT    TIMESTAMP_LTZ
);

INSERT INTO REG_AUDIT_LOG
WITH chg AS (
    SELECT POSITION_ID, LEGAL_ENTITY, NOTIONAL_USD, METADATA$ACTION AS action, METADATA$ISUPDATE AS is_update
    FROM REG_POSITIONS_CHANGES
)
SELECT
    COALESCE(n.POSITION_ID, o.POSITION_ID),
    CASE WHEN n.is_update OR o.is_update THEN 'UPDATE'
         WHEN n.POSITION_ID IS NULL      THEN 'DELETE'
         ELSE 'INSERT' END,
    COALESCE(n.LEGAL_ENTITY, o.LEGAL_ENTITY),
    o.NOTIONAL_USD,
    n.NOTIONAL_USD,
    CURRENT_TIMESTAMP()
FROM      (SELECT * FROM chg WHERE action = 'INSERT') n
FULL JOIN (SELECT * FROM chg WHERE action = 'DELETE') o
       ON n.POSITION_ID = o.POSITION_ID;

SELECT POSITION_ID, CHANGE_TYPE, LEGAL_ENTITY, OLD_NOTIONAL, NEW_NOTIONAL
FROM REG_AUDIT_LOG ORDER BY POSITION_ID;

-- [step:who]
-- ============================================================================
-- STEP 9: WHO CHANGED IT - QUERY AND ACCESS HISTORY
-- ============================================================================

-- 9a. Immediately available: this session's data changes to REG_POSITIONS
SELECT START_TIME, USER_NAME, ROLE_NAME, QUERY_TYPE, QUERY_TEXT
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY_BY_SESSION(RESULT_LIMIT => 200))
WHERE QUERY_TYPE IN ('UPDATE', 'DELETE', 'INSERT')
  AND QUERY_TEXT ILIKE '%REG_POSITIONS %'
  AND QUERY_TEXT NOT ILIKE '%REG_AUDIT_LOG%'
  AND START_TIME >= $filing_ts
ORDER BY START_TIME;

-- 9b. Account-wide and durable (Enterprise Edition; results appear after the
--     view's normal latency, up to about 3 hours). Shows every user who
--     MODIFIED the table, with the columns touched.
SELECT
    ah.QUERY_START_TIME,
    ah.USER_NAME,
    obj.value:"objectName"::STRING               AS object_name,
    col.value:"columnName"::STRING               AS column_name
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY ah,
     LATERAL FLATTEN(ah.OBJECTS_MODIFIED) obj,
     LATERAL FLATTEN(obj.value:"columns", OUTER => TRUE) col
WHERE obj.value:"objectName"::STRING = 'REG_AUDIT_DEMO_DB.REPORTING.REG_POSITIONS'
  AND ah.QUERY_START_TIME >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
ORDER BY ah.QUERY_START_TIME;

-- [step:undrop]
-- ============================================================================
-- STEP 10: RECOVER FROM MISTAKES - UNDROP
-- ============================================================================

-- Oops: someone drops the production positions table
DROP TABLE REG_POSITIONS;

-- This now fails with "does not exist":
-- SELECT COUNT(*) FROM REG_POSITIONS;

-- Restore it instantly, with all data and its Time Travel history
UNDROP TABLE REG_POSITIONS;

SELECT COUNT(*) AS positions_after_undrop FROM REG_POSITIONS;

-- History survives the drop: the as-filed view still works
SELECT COUNT(*) AS positions_as_filed FROM REG_POSITIONS AT(TIMESTAMP => $filing_ts);

-- [step:cleanup]
-- ============================================================================
-- STEP 11: CLEANUP (Optional - uncomment to remove demo objects)
-- ============================================================================

-- USE ROLE ACCOUNTADMIN;
-- DROP DATABASE IF EXISTS REG_AUDIT_DEMO_DB;
-- DROP WAREHOUSE IF EXISTS REG_AUDIT_WH;
-- UNSET (filing_ts, fix_qid);
