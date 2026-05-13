# Frontend

The frontend contract is **read-only SQL against the `vCurrent*` views.** Power BI, Grafana, Excel, Tableau — anything that speaks T-SQL — is a valid client.

## Connection

```text
Server   = (localdb)\MSSQLLocalDB     # or your real SQL Server host
Database = InventoryTest               # or your real DB name
Auth     = Integrated Security (Windows)
```

For Power BI / Excel users on Windows, double-click `test/inventory-dashboard.pbids` — it opens Power BI Desktop with the connection pre-filled.

## What's exposed

| Object | Purpose |
| --- | --- |
| `dbo.Computers` | Master record per fleet host. PK = `ComputerName`. |
| `dbo.CollectionRuns` | One row per (Computer, RunId) — the history axis. |
| `dbo.vCurrent<TableName>` | Latest snapshot per Computer for each fact table — what most dashboards want. |
| `dbo.vCurrentInstalledUpdates` | KBs currently installed (excludes uninstalled). |
| `dbo.vStaleComputers` | Hosts that haven't reported in > 25h. |
| `dbo.InstalledUpdates` (table) | Full differential history including `UninstalledAt`. |
| `dbo.<TableName>` (raw fact tables) | Full snapshot history. Filter by `RunId` for point-in-time analysis. |

Rule of thumb: a dashboard built on **`vCurrent*` views only** will show the right thing without thinking about time. Drill into the raw tables when you actually want history.

## Starter SQL queries

```sql
-- Fleet KPIs
SELECT
    (SELECT COUNT(*) FROM dbo.Computers)                        AS total_computers,
    (SELECT COUNT(*) FROM dbo.Computers WHERE IsActive = 1)     AS active_computers,
    (SELECT COUNT(*) FROM dbo.vStaleComputers)                  AS stale_computers,
    (SELECT COUNT(*) FROM dbo.CollectionRuns)                   AS total_runs,
    (SELECT COUNT(*) FROM dbo.vCurrentInstalledUpdates)         AS active_kbs;

-- Top 15 most-installed software across the fleet
SELECT TOP 15 DisplayName, COUNT(DISTINCT ComputerName) AS installs
FROM dbo.vCurrentInstalledSoftware
WHERE DisplayName IS NOT NULL AND DisplayName <> ''
GROUP BY DisplayName
ORDER BY installs DESC;

-- Servers running low on disk
SELECT TOP 20 ComputerName, Drive, TotalSize_GB, FreeSpace_GB, FreeSpace_Percentage
FROM dbo.vCurrentDiskSpace
ORDER BY TRY_CAST(FreeSpace_GB AS DECIMAL(18,2)) ASC;

-- KBs installed in the last 7 days
SELECT Title, COUNT(*) AS computers
FROM dbo.vCurrentInstalledUpdates
WHERE FirstSeenAt > DATEADD(DAY, -7, SYSUTCDATETIME())
GROUP BY Title
ORDER BY computers DESC;

-- Runs per day (the history axis for time-series visuals)
SELECT CAST(StartedAt AS DATE) AS day, COUNT(*) AS runs
FROM dbo.CollectionRuns
GROUP BY CAST(StartedAt AS DATE)
ORDER BY day;
```

## Demoing history

To populate the DB with N days of synthetic collection history (useful for testing time-series visuals and retention behavior):

```powershell
.\test\Demo-History.ps1 -Rounds 5 -DaysApart 1 -DropDb
```

What this proves about the schema:

- Snapshot fact tables grow linearly with runs (`InstalledSoftware`, `SystemInfo`, etc.)
- `InstalledUpdates` stays roughly flat — the differential model holds at daily cadence
- `Run-RetentionPolicy.ps1 -RetainRuns 3` then prunes via `ON DELETE CASCADE`
