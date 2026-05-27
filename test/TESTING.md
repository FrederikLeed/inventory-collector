# Testing

This folder contains an end-to-end integration test for the SQL chain
(`CreateSQLTableFromJSON.ps1` + `UpdateSQLTableFromJSON.ps1`) plus
helpers for exercising the rest of the pipeline locally.

## Prerequisites

- Windows with PowerShell 5.1 or PowerShell 7+
- Execution policy permits running local scripts (e.g. `RemoteSigned` at
  `CurrentUser` scope is enough)
- SQL Server LocalDB (`MSSQLLocalDB` instance) — install once via
  `Download-SqlLocalDB.ps1` (see below)

## One-time setup

### 1. Install LocalDB

The MSI is ~50 MB and is not committed to the repo. Fetch it from
Microsoft on first run:

```powershell
.\Download-SqlLocalDB.ps1 -Install
sqllocaldb info     # should print MSSQLLocalDB
```

If the default URL has rotted, grab the current link from Microsoft's
LocalDB docs page and pass it as `-Url`:
<https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/sql-server-express-localdb>

### 2. Sample data

A small, **anonymized** customer dataset is shipped as
`sample-data/InventoryParsed.zip`. Extract it:

```powershell
Expand-Archive -Path .\sample-data\InventoryParsed.zip `
               -DestinationPath .\sample-data\InventoryParsed -Force
```

Every `ComputerName`, `UserName`, domain, and IP in the fixture has been
remapped to `CMP0001` / `user0001` / `example.local` / `10.0.0.x` style
placeholders. Cross-file joins are preserved (the same input always maps
to the same output).

## Running the integration test

```powershell
.\Test-Integration-LocalDB.ps1
```

Default `-SampleDataPath` is `.\sample-data\InventoryParsed`. To test
against your own data without copying it into the repo:

```powershell
.\Test-Integration-LocalDB.ps1 -SampleDataPath C:\temp\inventoryparsed
```

What it does:

1. Creates a fresh `InventoryTest` database on `MSSQLLocalDB`
2. Trims each JSON to 1000 rows (skips `InstalledUpdates` and `Invoice`),
   stamps each record with a per-Computer `RunId`, and writes a synthetic
   `CollectionRuns.json` so the fixture matches what the pipeline emits
3. Runs `CreateSQLTableFromJSON.ps1` and asserts the schema lands on a
   fresh DB in one step: `Computers` / `CollectionRuns` /
   `InstalledUpdates` infrastructure tables, fact tables with `RunId NOT
   NULL` + inline FK constraints, `vCurrent<TableName>` views, and the
   cross-table `vCurrentInstalledUpdates` / `vStaleComputers` views
4. Runs `UpdateSQLTableFromJSON.ps1` and asserts non-zero row counts,
   that `Computers` + `CollectionRuns` get populated from the sidecar,
   and that every fact row has a non-NULL `RunId`
5. Re-runs the update and asserts no duplicates (`INSERT WHERE NOT
   EXISTS` is idempotent on same-RunId reload)
6. Inserts an SQL injection payload through a parameterized command and
   asserts the table survives + value is stored as a literal string
7. Drives a JSON injection payload through the actual Update script
   and verifies the row landed as literal data
8. Exercises the schema-evolution branch: adds a column to a JSON,
   re-runs Create, verifies `ALTER TABLE` happened
9. Exercises a fresh-Computer end-to-end load: asserts `Computers` /
   `CollectionRuns` get upserted from the sidecar, fact rows land with
   the correct `RunId`, and idempotency holds on re-run
10. Verifies append-only behaviour: re-loading the same data with a
    new `RunId` adds new rows (snapshot) rather than overwriting;
    same `RunId` again is idempotent
11. Verifies a `vCurrent*` view returns the latest snapshot per
    `ComputerName`
12. Verifies the `InstalledUpdates` differential model: across two
    runs with overlapping but non-identical KB sets, dropped KBs get
    `UninstalledAt` set, returning KBs clear it, new KBs insert with
    `FirstSeenRunId` = `LastSeenRunId`
13. Drops the database and prints a pass/fail summary

Exit code is 0 on green, 1 if any assertion failed.

## Quick visual check

`Show-TableData.ps1` does the same setup but skips the assertions and
prints `SELECT TOP 10 *` from each populated table:

```powershell
.\Show-TableData.ps1
```

Useful when you want to eyeball what landed in SQL after a change.

## End-to-end: GetInventory -> ParseInventory -> SQL

The full pipeline runs on different machines in production (endpoint
agent -> file share -> SQL host), but you can exercise the whole chain
locally:

```powershell
# 1. Collect a real zip from THIS machine
mkdir C:\temp\inv-test
..\GetInventory.ps1 -centralFilesharePath C:\temp\inv-test
# produces C:\temp\inv-test\<COMPUTERNAME>.zip

# 2. Parse the zip into aggregated JSONs
mkdir C:\temp\parse-extract, C:\temp\parse-output
..\ParseInventory.ps1 `
    -fileSharePath        C:\temp\inv-test `
    -extractPath          C:\temp\parse-extract `
    -aggregateOutputPath  C:\temp\parse-output

# 3. Load the JSONs into LocalDB
.\Test-Integration-LocalDB.ps1 -SampleDataPath C:\temp\parse-output
```

Notes:

- Run from an elevated PowerShell if you want clean GPO collection.
  `gpresult /r /scope computer` requires admin; without it the
  `lastApplied` field falls back to `Unknown` (the wrapper handles that
  gracefully, doesn't fail the run).
- Only one endpoint's data ends up in the zip, so `Test-Integration` will
  see ~13 tables instead of the usual fleet-wide ~16.

## Refreshing the anonymized fixture

If you have new customer data and want to regenerate the shipping zip:

```powershell
# 1. Anonymize
.\Anonymize-InventoryData.ps1 `
    -SourcePath      C:\temp\inventoryparsed `
    -DestinationPath C:\temp\anon-output

# 2. Spot-check that no real names leaked
Get-Content C:\temp\anon-output\SystemInfo.json -Raw | Select-String -Pattern '<your-org-name>'

# 3. Re-create the shipping zip
Compress-Archive -Path C:\temp\anon-output\*.json `
                 -DestinationPath .\sample-data\InventoryParsed.zip -Force
```

The anonymizer is property-name driven with a substring sweep for known
identifiers (computer names, user names, domains, AD distinguished
names, certificate subjects, IPs, emails). Drops `Invoice.json` by
default since it's customer-specific financial data, not inventory.

If a new field name should be anonymized, add it to the `$Rules`
hashtable in `Anonymize-InventoryData.ps1`.

## What's NOT covered by the test suite

- `GetInventory.ps1` collection logic — exercised manually by running it
  against this machine (see "End-to-end" above). No assertions.
- `ParseInventory.ps1` zip extraction — same; run it manually against a
  GetInventory output.
- Azure SQL variants (`*_azure.ps1`) — these still have the original SQL
  injection patterns. Deferred for a full rewrite, tracked in
  `../TODO.md`.
