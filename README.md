# Regulatory Reporting with Time Travel and Audit Trail

**Owner:** Janet Cho · **Last reviewed:** November 2026 · **License:** [Apache 2.0](LICENSE)

A customer-facing, step-by-step guide for financial services teams. It shows how to prove what your data said on a filing date, what changed afterwards and who changed it, using built-in Snowflake features:

- **Time Travel**: `AT(TIMESTAMP => ...)` and `BEFORE(STATEMENT => ...)`, plus explicit data retention
- **Zero-copy cloning**: freeze the as-filed state permanently
- **Streams**: capture every insert, update and delete with old and new values
- **Query and access history**: who made each change, and which columns it touched
- **UNDROP**: instant recovery from an accidental drop

**Live guide:** https://sfc-gh-jacho.github.io/sfguide-regulatory-audit-time-travel/

The site is fully static and doesn't connect to any Snowflake account. Its result tables come from a real end-to-end run of the script on synthetic data, with user names replaced by `<YOUR_USER>`.

## Prerequisites

- **Enterprise Edition or higher** for the 7-day retention the script sets and for `ACCESS_HISTORY` (Step 9b).
  - On **Standard Edition**, change `DATA_RETENTION_TIME_IN_DAYS = 7` to `1` in Step 1. Everything else works.
- **A role to run it.** ACCOUNTADMIN is simplest in a sandbox. For regulated environments, use the least-privilege option below.

### Least-privilege option (no ACCOUNTADMIN)

The script starts with `SET demo_role = 'ACCOUNTADMIN';`. To run without ACCOUNTADMIN, an administrator runs the commented block at the top of Step 1 once:

```sql
USE ROLE ACCOUNTADMIN;
CREATE ROLE IF NOT EXISTS REG_DEMO_ROLE;
GRANT CREATE DATABASE  ON ACCOUNT TO ROLE REG_DEMO_ROLE;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE REG_DEMO_ROLE;               -- or USAGE on an existing warehouse
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE REG_DEMO_ROLE; -- ACCESS_HISTORY, Step 9b only
GRANT ROLE REG_DEMO_ROLE TO USER <YOUR_USER>;
```

Then change the first line to `SET demo_role = 'REG_DEMO_ROLE';`. The role owns everything it creates, so it needs no other grants. This path was tested end to end and produced identical results.

## Run the demo in Snowsight

1. Download [`sql/reg_audit_time_travel.sql`](sql/reg_audit_time_travel.sql).
2. In Snowsight, open **Projects → Worksheets** and create a new SQL worksheet.
3. Paste the script and run it **top to bottom in the same worksheet**. Later steps use session variables (`$filing_ts`, `$fix_qid`) set in earlier steps. No find-and-replace is needed.
4. Step 9b (`ACCESS_HISTORY`) fills in after up to about 3 hours. Re-run it later to see the account-wide record.
5. When you're done, uncomment and run Step 11 (Cleanup).

## What gets created

| Object | Name |
|---|---|
| Database | `REG_AUDIT_DEMO_DB` (schema `REPORTING`, 7-day retention) |
| Warehouse | `REG_AUDIT_WH` (XSMALL, 60 s auto-suspend) |
| Tables | `REG_POSITIONS`, `REG_LEGAL_ENTITIES`, `REG_RISK_WEIGHTS`, `REG_AUDIT_LOG`, `REG_POSITIONS_Q3_FILED` (clone) |
| View | `REG_CAPITAL_REPORT` |
| Stream | `REG_POSITIONS_CHANGES` |

A full run uses a small fraction of one credit on an XSMALL warehouse.

## Repository layout

```
LICENSE                          Apache License 2.0
vendor/prism/                    Prism.js (MIT), served locally
index.html                       Single-page guide
styles.css                       Styling (Snowflake palette)
script.js                        Loads SQL steps, Prism highlighting, copy buttons, results tables
sql/reg_audit_time_travel.sql    Full demo script (split into steps by "-- [step:<id>]" markers)
data/sample_results.json         Results captured from a real run (user names redacted)
```

To preview locally, serve the folder over HTTP:

```
python3 -m http.server 8000
```

## Customize with Cortex Code

[Cortex Code](https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code) can adapt this guide to your own data. Open the repo folder in Cortex Code and try prompts like:

- "Map my positions table to REG_POSITIONS and propose a validation plan before changing anything."
- "Replace the illustrative capital view with my risk-weight table, then compare as-filed vs. corrected results for last quarter-end."
- "Set up a quarter-end task that clones my reporting tables at filing time and tags each clone as a regulatory snapshot."

Ask it to review the plan with you before it creates or changes any objects in your account.

## License

Licensed under the [Apache License, Version 2.0](LICENSE). Prism.js, used for syntax highlighting, is bundled in `vendor/prism/` under its own MIT license, so the pages make no third-party requests.

## Disclaimer

All legal entities, positions and figures are synthetic. The capital calculation is simplified and illustrative: it is not a regulatory methodology, and this guide is not compliance advice. The repository contains no credentials, account identifiers or connection details.
