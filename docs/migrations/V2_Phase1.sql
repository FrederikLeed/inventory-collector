-- ============================================================
-- Inventory Collector - V2 Phase 1 migration
-- ============================================================
-- Safe to run multiple times. No behavior change for V1 scripts.
--
-- Adds Computers + CollectionRuns infrastructure tables, augments every
-- existing fact table with RunId / CreatedAt columns, widens ComputerName
-- to NVARCHAR(128), and backfills the new columns from existing data.
--
-- Does NOT add FK constraints, UNIQUE indexes, or drop UpdateTimeStamp -
-- those come in Phase 3 after the pipeline has been validated to emit
-- RunId end-to-end. See ../SCHEMA_V2.md for the full plan.

SET NOCOUNT ON;
SET XACT_ABORT ON;

PRINT 'V2 Phase 1 migration starting...';

-- ============================================================
-- 1. Infrastructure tables
-- ============================================================

IF OBJECT_ID('dbo.Computers', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Computers (
        ComputerName   NVARCHAR(128)    NOT NULL PRIMARY KEY,
        FirstSeenAt    DATETIME2(3)     NOT NULL DEFAULT SYSUTCDATETIME(),
        LastSeenAt     DATETIME2(3)     NOT NULL DEFAULT SYSUTCDATETIME(),
        LastRunId      UNIQUEIDENTIFIER NULL,
        IsActive       BIT              NOT NULL DEFAULT 1,
        DeactivatedAt  DATETIME2(3)     NULL
    );
    PRINT '  Created dbo.Computers';
END
ELSE PRINT '  dbo.Computers already exists';

IF OBJECT_ID('dbo.CollectionRuns', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CollectionRuns (
        RunId             UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        ComputerName      NVARCHAR(128)    NOT NULL,
        StartedAt         DATETIME2(3)     NOT NULL,
        CompletedAt       DATETIME2(3)     NULL,
        Status            NVARCHAR(20)     NOT NULL,
        MetricsSucceeded  INT              NULL,
        MetricsFailed     INT              NULL,
        FailedMetrics     NVARCHAR(MAX)    NULL,
        LoadedAt          DATETIME2(3)     NULL
    );
    CREATE INDEX IX_CollectionRuns_Computer_Started
        ON dbo.CollectionRuns (ComputerName, StartedAt DESC);
    PRINT '  Created dbo.CollectionRuns';
END
ELSE PRINT '  dbo.CollectionRuns already exists';

-- ============================================================
-- 2. Discover fact tables (have ComputerName + UpdateTimeStamp)
-- ============================================================

DECLARE @FactTables TABLE (TableName NVARCHAR(128) PRIMARY KEY);
INSERT INTO @FactTables (TableName)
SELECT t.name
FROM sys.tables t
INNER JOIN sys.columns c1 ON c1.object_id = t.object_id AND c1.name = 'ComputerName'
INNER JOIN sys.columns c2 ON c2.object_id = t.object_id AND c2.name = 'UpdateTimeStamp'
WHERE t.schema_id = SCHEMA_ID('dbo')
  AND t.name NOT IN ('Computers', 'CollectionRuns');

DECLARE @TableCount INT = (SELECT COUNT(*) FROM @FactTables);
PRINT '  Found ' + CAST(@TableCount AS NVARCHAR(10)) + ' V1 fact table(s) to migrate';

-- ============================================================
-- 3. ALTER each fact table: widen ComputerName, add RunId + CreatedAt
-- ============================================================

DECLARE @TableName NVARCHAR(128);
DECLARE @sql NVARCHAR(MAX);

DECLARE TableCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName FROM @FactTables ORDER BY TableName;

OPEN TableCursor;
FETCH NEXT FROM TableCursor INTO @TableName;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Widen ComputerName to NVARCHAR(128) if currently MAX or smaller
    IF EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName))
          AND name = 'ComputerName'
          AND (max_length = -1 OR max_length / 2 <> 128)
    )
    BEGIN
        SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) +
                   N' ALTER COLUMN ComputerName NVARCHAR(128) NOT NULL';
        EXEC sp_executesql @sql;
        PRINT '  Resized ' + @TableName + '.ComputerName to NVARCHAR(128)';
    END

    -- Add RunId (NULLable for Phase 1 - tightened in Phase 3)
    IF NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName))
          AND name = 'RunId'
    )
    BEGIN
        SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) +
                   N' ADD RunId UNIQUEIDENTIFIER NULL';
        EXEC sp_executesql @sql;
        PRINT '  Added ' + @TableName + '.RunId';
    END

    -- Add CreatedAt (NULLable for Phase 1; backfilled below from UpdateTimeStamp)
    IF NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName))
          AND name = 'CreatedAt'
    )
    BEGIN
        SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) +
                   N' ADD CreatedAt DATETIME2(3) NULL';
        EXEC sp_executesql @sql;
        PRINT '  Added ' + @TableName + '.CreatedAt';
    END

    -- Backfill CreatedAt from UpdateTimeStamp for rows missing it
    SET @sql = N'UPDATE dbo.' + QUOTENAME(@TableName) +
               N' SET CreatedAt = UpdateTimeStamp WHERE CreatedAt IS NULL AND UpdateTimeStamp IS NOT NULL';
    EXEC sp_executesql @sql;

    FETCH NEXT FROM TableCursor INTO @TableName;
END
CLOSE TableCursor;
DEALLOCATE TableCursor;

-- ============================================================
-- 4. Backfill Computers from DISTINCT ComputerName across fact tables
-- ============================================================

DECLARE @backfillSql NVARCHAR(MAX);

IF @TableCount > 0
BEGIN
    -- Build UNION ALL across all fact tables: (ComputerName, UpdateTimeStamp)
    SELECT @backfillSql = STRING_AGG(
        N'SELECT ComputerName, UpdateTimeStamp FROM dbo.' + QUOTENAME(TableName),
        N' UNION ALL '
    )
    FROM @FactTables;

    SET @backfillSql = N'
        WITH Sightings AS (' + @backfillSql + N')
        INSERT INTO dbo.Computers (ComputerName, FirstSeenAt, LastSeenAt)
        SELECT s.ComputerName, MIN(s.UpdateTimeStamp), MAX(s.UpdateTimeStamp)
        FROM Sightings s
        WHERE s.ComputerName IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM dbo.Computers c WHERE c.ComputerName = s.ComputerName
          )
        GROUP BY s.ComputerName;';

    EXEC sp_executesql @backfillSql;
    PRINT '  Computers backfilled: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' new row(s)';

    -- Update LastSeenAt for existing Computers rows where fact tables have newer data
    SET @backfillSql = N'
        WITH Sightings AS (' + (
            SELECT STRING_AGG(
                N'SELECT ComputerName, UpdateTimeStamp FROM dbo.' + QUOTENAME(TableName),
                N' UNION ALL '
            ) FROM @FactTables
        ) + N')
        UPDATE c
        SET LastSeenAt = sm.LastSeen
        FROM dbo.Computers c
        INNER JOIN (
            SELECT ComputerName, MAX(UpdateTimeStamp) AS LastSeen
            FROM Sightings WHERE ComputerName IS NOT NULL
            GROUP BY ComputerName
        ) sm ON sm.ComputerName = c.ComputerName
        WHERE sm.LastSeen > c.LastSeenAt;';

    EXEC sp_executesql @backfillSql;
END

-- ============================================================
-- 5. Generate one synthetic CollectionRuns row per Computer (idempotent)
-- ============================================================

INSERT INTO dbo.CollectionRuns
    (RunId, ComputerName, StartedAt, Status, LoadedAt)
SELECT NEWID(), c.ComputerName, c.LastSeenAt, 'Loaded', SYSUTCDATETIME()
FROM dbo.Computers c
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.CollectionRuns r
    WHERE r.ComputerName = c.ComputerName
      AND r.StartedAt    = c.LastSeenAt
);
PRINT '  CollectionRuns rows added: ' + CAST(@@ROWCOUNT AS NVARCHAR(20));

-- Point Computers.LastRunId at the synthetic run
UPDATE c
SET LastRunId = r.RunId
FROM dbo.Computers c
INNER JOIN dbo.CollectionRuns r
    ON  r.ComputerName = c.ComputerName
    AND r.StartedAt    = c.LastSeenAt
WHERE c.LastRunId IS NULL OR c.LastRunId <> r.RunId;

-- ============================================================
-- 6. Backfill RunId on each fact table
-- ============================================================

DECLARE BackfillCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName FROM @FactTables ORDER BY TableName;

OPEN BackfillCursor;
FETCH NEXT FROM BackfillCursor INTO @TableName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        UPDATE t SET RunId = c.LastRunId
        FROM dbo.' + QUOTENAME(@TableName) + N' t
        INNER JOIN dbo.Computers c ON c.ComputerName = t.ComputerName
        WHERE t.RunId IS NULL AND c.LastRunId IS NOT NULL;';
    EXEC sp_executesql @sql;

    FETCH NEXT FROM BackfillCursor INTO @TableName;
END
CLOSE BackfillCursor;
DEALLOCATE BackfillCursor;

PRINT 'V2 Phase 1 migration complete.';
