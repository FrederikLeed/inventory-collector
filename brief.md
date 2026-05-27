# Inventory Collector — solution brief

This document describes what the solution is, how it works, and the constraints
it operates under. It is the source material for end-user documentation.

## Purpose

A pull/push pipeline that:

1. Collects Windows Server inventory data from every host in a fleet (per-host
   PowerShell agent).
2. Drops the data on a central file share as a per-host zip.
3. Aggregates the zips into per-metric JSON files.
4. Loads the JSON into a SQL Server database that keeps daily history,
   exposes a current-state view per metric, and prunes itself on a retention
   policy.

Designed to run unattended on a daily schedule. Tested at 10,000-server scale.

## Components

```text
   Windows Server (endpoint)
   ┌─────────────────────┐
   │  GetInventory.ps1   │  (per-host script, GPO / SCCM / Live Response)
   └──────────┬──────────┘
              │  <ComputerName>.zip
              ▼
   ┌─────────────────────┐
   │   File share        │
   └──────────┬──────────┘
              │
              ▼  (on the SQL host, scheduled task)
   ┌─────────────────────┐
   │   scheduler.ps1     │  reads config.xml, runs each step in order
   └──────────┬──────────┘
              │
              ▼ runs:
     ParseInventory.ps1
     CreateSQLTableFromJSON.ps1
     UpdateSQLTableFromJSON.ps1
     Run-RetentionPolicy.ps1
     Remove-ZipFiles.ps1
              │
              ▼
   ┌─────────────────────┐
   │  SQL Server         │  schema + retention managed by the chain
   └─────────────────────┘
```

## Scripts

### Endpoint (runs on each Windows Server)

| Script | Role |
|---|---|
| `GetInventory.ps1` | Generates one `RunId` per collection, runs a list of `Get-*` functions (SystemInfo, DiskSpace, InstalledSoftware, InstalledUpdates, Services, ScheduledTasks, AutoRunInfo, PersonalCertificates, LocalUsers, GroupMembers, ShareAccessInfo, UserProfileList, MPComputerStatus), stamps each row with the `RunId`, zips the per-metric JSONs plus a `_collection-meta.json` sidecar, copies the outer zip to the file share. |

### Server-side chain (runs on the SQL host)

| Script | Role |
|---|---|
| `scheduler.ps1` | Reads `config.xml`, runs each `<Script>` entry in order with its parameters, logs each step, exits non-zero on the first failure. |
| `ParseInventory.ps1` | Walks the file share, extracts each outer zip + inner per-metric zips, aggregates rows across all hosts into one JSON file per metric in an output folder. Also aggregates `_collection-meta.json` into `CollectionRuns.json`. |
| `CreateSQLTableFromJSON.ps1` | Idempotent. Creates `Computers`, `CollectionRuns`, `InstalledUpdates` infrastructure tables, then one snapshot fact table per JSON file (auto-discovers columns from the union of properties across all rows). Inline FK constraints, `UX_<Table>_Natural` UNIQUE indexes, and a `vCurrent<TableName>` view per fact table. Adds columns via `ALTER TABLE` if a later JSON has properties not seen before. |
| `UpdateSQLTableFromJSON.ps1` | Loads `CollectionRuns.json` first (upserts `Computers`, inserts `CollectionRuns`), then bulk-loads each fact table via SQL Server `SqlBulkCopy` into a `#temp` staging table, deduplicates within staging via `ROW_NUMBER()`, and `INSERT ... WHERE NOT EXISTS` into the target. `InstalledUpdates` uses a single set-based `MERGE` instead. |
| `Run-RetentionPolicy.ps1` | Three idempotent actions: drop `CollectionRuns` older than the most recent N per Computer (FK cascade prunes fact rows), drop `InstalledUpdates` rows whose `UninstalledAt` is older than M days, set `Computers.IsActive = 0` for hosts that haven't reported in K days. |
| `Remove-ZipFiles.ps1` | Deletes processed zips from the share. |

### Shared helpers

| Script | Role |
|---|---|
| `SqlHelpers.ps1` | `Test-SqlIdentifier` (rejects anything outside `[A-Za-z0-9_ ]`), `Convert-ToSimpleFormat` (normalises arrays/objects to JSON-serialisable values), `Add-Parameterized*` helpers (build INSERT/UPDATE/WHERE clauses with `SqlCommand.Parameters` — never string concatenation), `$NaturalKeyMap` + `Get-NaturalKey` (table-to-natural-key mapping). |

## Schema

### Infrastructure tables

```sql
dbo.Computers (
    ComputerName    NVARCHAR(128) PK,
    FirstSeenAt     DATETIME2(3),
    LastSeenAt      DATETIME2(3),
    LastRunId       UNIQUEIDENTIFIER,
    IsActive        BIT,
    DeactivatedAt   DATETIME2(3)
)

dbo.CollectionRuns (
    RunId           UNIQUEIDENTIFIER PK,
    ComputerName    NVARCHAR(128) FK → Computers,
    StartedAt       DATETIME2(3),
    CompletedAt     DATETIME2(3),
    Status          NVARCHAR(20),  -- 'Collecting' | 'Parsed' | 'Loaded' | 'Failed'
    MetricsSucceeded INT,
    MetricsFailed   INT,
    FailedMetrics   NVARCHAR(MAX),
    LoadedAt        DATETIME2(3)
)
-- IX_CollectionRuns_Computer_Started (ComputerName, StartedAt DESC)
```

### Snapshot fact tables (one per metric)

Generated from JSON shape by `CreateSQLTableFromJSON.ps1`. Every fact table
gets:

- `Id INT IDENTITY PRIMARY KEY` (clustered, throwaway surrogate)
- `ComputerName NVARCHAR(128) NOT NULL` (FK → Computers)
- `RunId UNIQUEIDENTIFIER NOT NULL` (FK → CollectionRuns, `ON DELETE CASCADE`)
- `CreatedAt DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()`
- Per-JSON-property columns (NVARCHAR(MAX), BIGINT, or BIT inferred from the
  first non-null value seen across all rows)
- `UX_<Table>_Natural` UNIQUE NONCLUSTERED INDEX on
  `(RunId, ComputerName, …natural-key…)` — covers cascade, dedup, and
  `vCurrent` joins. Natural-key string columns are sized down to
  `NVARCHAR(256)` to fit SQL Server's 1700-byte key limit.

Natural keys defined in `$NaturalKeyMap` (in `SqlHelpers.ps1`):

| Table | Natural key beyond `(RunId, ComputerName)` |
|---|---|
| `SystemInfo`, `MPComputerStatus`, `ServerOverview`, `ADServers` | — |
| `DiskSpace` | `Drive` |
| `InstalledSoftware` | `DisplayName`, `DisplayVersion` |
| `Services`, `AutoRunInfo`, `UserProfileList` | `Name` |
| `ScheduledTasks` | `TaskPath`, `TaskName` |
| `PersonalCertificates` | `Thumbprint` |
| `LocalUsers` | `UserName` |
| `GroupMembers`, `ServerAccess` | `GroupName` |
| `ShareAccessInfo` | `ShareName` |
| `ServerList` | `Description` |

### InstalledUpdates (differential, not snapshot)

```sql
dbo.InstalledUpdates (
    Id              INT IDENTITY PRIMARY KEY,
    ComputerName    NVARCHAR(128)    NOT NULL FK → Computers,
    Title           NVARCHAR(512)    NOT NULL,
    InstalledOn     DATE,
    ServiceID       NVARCHAR(64),
    FirstSeenRunId  UNIQUEIDENTIFIER NOT NULL FK → CollectionRuns,
    LastSeenRunId   UNIQUEIDENTIFIER NOT NULL FK → CollectionRuns,
    FirstSeenAt     DATETIME2(3),
    LastSeenAt      DATETIME2(3),
    UninstalledAt   DATETIME2(3)
)
-- UX_InstalledUpdates_Natural (ComputerName, Title) UNIQUE
-- IX_InstalledUpdates_FirstRun (FirstSeenRunId)
-- IX_InstalledUpdates_LastRun  (LastSeenRunId)
```

One row per `(Computer, Title)` for the lifetime of that install. Loader does
a set-based `MERGE`: matched rows get `LastSeenRunId` and `LastSeenAt`
bumped (and `UninstalledAt` cleared if it had been set); unmatched rows
INSERT with `FirstSeenRunId = LastSeenRunId = @RunId`. After the MERGE, any
`(Computer, Title)` not touched by this run gets `UninstalledAt` set —
that's how uninstalls are detected.

Justification: at 10k servers × ~1,300 KBs × 90-day retention, a snapshot
model would be 1.2 billion rows. The differential model collapses that to
~13 million while preserving "currently installed" semantics.

### Views

| View | Returns |
|---|---|
| `vCurrent<TableName>` | Latest-RunId snapshot per Computer for each snapshot fact table. |
| `vCurrentInstalledUpdates` | `InstalledUpdates WHERE UninstalledAt IS NULL`. |
| `vStaleComputers` | Active Computers whose `LastSeenAt` is older than 25 hours. |

Consumers (Power BI, Grafana, Excel, etc.) read the `vCurrent*` views by
default. Trend visuals read the raw fact tables and filter by `RunId` or
join on `CollectionRuns`.

## Idempotency

The chain is safe to re-run with the same data:

- `ParseInventory.ps1` overwrites the aggregated JSONs each run.
- `CreateSQLTableFromJSON.ps1` uses `IF OBJECT_ID(...) IS NULL` guards and
  `CREATE OR ALTER VIEW`; re-runs are no-ops on an unchanged schema.
  Schema-evolution path uses `ALTER TABLE ADD` only for columns the existing
  table doesn't have.
- `UpdateSQLTableFromJSON.ps1` uses `INSERT WHERE NOT EXISTS` against the
  natural-key UNIQUE index. Same `RunId` re-load inserts zero rows. NULL key
  values are matched with NULL-safe equality so they don't slip past.
- `InstalledUpdates` MERGE is naturally idempotent on the same input.
- `Run-RetentionPolicy.ps1` deletes by predicate; if there's nothing to
  delete, nothing happens.

## Performance characteristics (measured)

Benchmarked end-to-end on LocalDB, single-machine, modest hardware:

| Scale | Update step | Peak RAM | Notes |
|---|---:|---:|---|
| 1k servers / 13k rows | 15 s | ~200 MB | full chain incl. Parse |
| 10k servers / 196k rows | 125 s | ~700 MB | snapshot tables only |
| 10k servers + 5.3M InstalledUpdates rows | 156 s | ~700 MB | streaming reader for IU |
| 10k servers at real customer density (~13M IU rows, projected) | ~7 min | ~700 MB | linear in row count |

Two things keep the loader scaling cleanly:

1. **`SqlBulkCopy` + staging table + set-based dedup** replaces per-row
   `INSERT` (~3-4 ms/row round-trip on LocalDB). 4-5× throughput at any
   scale, dominant cost moves from network round-trips to index
   maintenance.
2. **Compiled C# `IDataReader` over a streaming JSON tokeniser** for
   InstalledUpdates. The full JSON is never materialised in memory; rows
   are yielded one at a time straight into `SqlBulkCopy.WriteToServer`.
   Peak RAM stays flat regardless of input file size — at 100k servers
   the loader still runs in <1 GB.

For storage at 10k servers, 90-day retention, real customer density:

| Table | Estimated rows | Estimated size |
|---|---:|---:|
| `InstalledSoftware` | ~90 M | ~20 GB |
| `Services` | ~180 M | ~30 GB |
| `ScheduledTasks` | ~90 M | ~15 GB |
| `InstalledUpdates` (differential) | ~13 M | ~2.7 GB |
| Everything else combined | ~30 M | ~7 GB |
| **Total** | **~400 M** | **~75 GB** |

Tighter per-table retention is the obvious lever if storage matters.

## Deployment

### SQL host (single Windows Server box)

1. Install SQL Server (Standard or Express; LocalDB works for testing).
2. Create the target database, no schema required — the load chain creates
   it.
3. Copy the script chain to a folder on the SQL host.
4. Edit `config.xml` paths and `SqlServer` / `Database` values.
5. Register `scheduler.ps1` as a Scheduled Task with daily trigger.

### Endpoints

1. Deploy `GetInventory.ps1` via GPO Scheduled Task (sample GPO included),
   SCCM, Live Response, or any other agent push mechanism.
2. The endpoint script writes its zip to the file share configured in its
   `$centralFilesharePath` parameter.

### Security

All SQL operations use parameterised `SqlCommand.Parameters` via the
`SqlHelpers.ps1` module — values are never string-concatenated into SQL
text. Table and column names go through `Test-SqlIdentifier`, which rejects
anything outside `[A-Za-z0-9_ ]`. Tested with explicit SQL-injection
payloads in the integration suite.

## Testing

`test/Run-AllTests.ps1` runs two suites:

- `Test-Integration-LocalDB.ps1` — 10 end-to-end tests against a real
  LocalDB instance using an anonymised customer fixture. Covers schema
  creation, idempotent re-loads, schema evolution, SQL-injection payloads,
  the InstalledUpdates differential model, and `vCurrent*` views.
- `Test-SqlInjectionFix.ps1` — 64 unit tests for `SqlHelpers.ps1`.

`test/Build-Zips.ps1` converts an aggregated JSON fixture into per-server
zips in the GetInventory layout, for exercising `ParseInventory.ps1` end to
end. `test/Demo-History.ps1` simulates N days of collection history to
populate the DB with time-series data.

Fixture: `test/sample-data/InventoryZips.zip` (1,059 anonymised per-server
zips, ~1.7 MB). Drop into a folder and feed straight to ParseInventory.

## Known constraints and open items

1. **`ServerAccess`, `ServerList`, `ServerOverview`, `ADServers` are not
   produced by `GetInventory.ps1`** — a customer-specific external collector
   drops them into the file share alongside the standard metrics. Their
   `ComputerName` column carries OU / server-class names, not real computer
   identifiers, so the FK to `Computers` is conceptually wrong for those
   four tables. The current load handles them defensively (UNIQUE on natural
   key deduplicates duplicates that would otherwise reject the batch) but
   the underlying schema mismatch should be fixed in the external collector.

2. **Azure SQL variants `*_azure.ps1`** still use the legacy
   string-concatenated query pattern (vulnerable to SQL injection) and the
   old per-row INSERT path. Slated for a full rewrite under Managed Identity
   auth using `SqlConnection` with `AccessToken`, reusing `SqlHelpers.ps1`.
   Tracked in `TODO.md`.

3. **PowerShell version**: production target is Windows PowerShell 5.1 (the
   default shell on Windows Server). The `InstalledUpdates` streaming reader
   is compiled via `Add-Type` against .NET Framework references; under
   PowerShell 7+ those references resolve differently and the C# helper
   falls back to a slower in-PowerShell `DataTable` build. Tests pass under
   both shells.

4. **LocalDB `tempdb` pressure** on 5M+ row `MERGE` operations during
   `InstalledUpdates` re-runs — observed in benchmarks. Production SQL
   Server with appropriately sized tempdb is unaffected. If it ever becomes
   an issue at scale, the fix is to chunk the MERGE by Computer.

5. **`ON DELETE CASCADE` retention cost** grows linearly with fact-table
   size. At ~90M-row `InstalledSoftware` plus 10k RunIds pruned per day,
   cascade deletes are the heaviest part of the daily chain. Replacing the
   cascade with explicit `DELETE FROM <Table> WHERE RunId IN (...)` per
   table is a possible optimisation if retention becomes the bottleneck.

## Code layout

```text
.
├── GetInventory.ps1                 endpoint collector
├── ParseInventory.ps1               zip → aggregated JSON
├── CreateSQLTableFromJSON.ps1       schema + indexes + views
├── UpdateSQLTableFromJSON.ps1       bulk load + differential MERGE
├── Run-RetentionPolicy.ps1          prune + deactivate
├── Remove-ZipFiles.ps1              file-share cleanup
├── scheduler.ps1                    runs config.xml chain
├── config.xml                       script chain definition
├── SqlHelpers.ps1                   parameterisation + natural keys
├── NewCentralFileShare.ps1          one-time file-share setup
├── *_azure.ps1                      Azure SQL variants (deferred rewrite)
├── README.md
├── TODO.md
├── test/
│   ├── Run-AllTests.ps1
│   ├── Test-Integration-LocalDB.ps1
│   ├── Test-SqlInjectionFix.ps1
│   ├── Build-Zips.ps1
│   ├── Demo-History.ps1
│   ├── Show-TableData.ps1
│   ├── setup-localdb.ps1
│   ├── Download-SqlLocalDB.ps1
│   ├── Anonymize-InventoryData.ps1
│   ├── TESTING.md
│   └── sample-data/
└── Device - Deploy Inventory Collector/    sample GPO for endpoint deploy
```
