-- ============================================================
-- Inventory Collector - V2 Phase 3 migration
-- ============================================================
-- Requires Phase 1 + Phase 2 to have run first (RunId / CreatedAt columns
-- present on every fact table, Computers + CollectionRuns populated).
--
-- - Drops UpdateTimeStamp from every snapshot fact table (now redundant).
-- - Tightens RunId to NOT NULL once verified all rows have it.
-- - Adds FK constraints to Computers + CollectionRuns and ON DELETE CASCADE
--   from CollectionRuns - this is what makes retention work.
-- - Adds per-table UNIQUE index on natural key for idempotent append-only
--   inserts.
-- - Recreates InstalledUpdates with the differential model (drops any
--   existing data - it isn't snapshot-compatible with the new shape).
-- - Creates vCurrent* views per fact table for the frontend to read.
--
-- Idempotent and safe to re-run.

SET NOCOUNT ON;
SET XACT_ABORT ON;

PRINT 'V2 Phase 3 migration starting...';

-- ============================================================
-- 1. Restructure InstalledUpdates to differential model
-- ============================================================
-- The differential schema is intentionally incompatible with the V1 snapshot
-- shape, so we drop and recreate. Real data repopulates on the next
-- collection cycle.

IF OBJECT_ID('dbo.InstalledUpdates', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns
                   WHERE object_id = OBJECT_ID('dbo.InstalledUpdates')
                     AND name = 'FirstSeenRunId')
BEGIN
    DROP TABLE dbo.InstalledUpdates;
    PRINT '  Dropped V1-shape InstalledUpdates';
END

IF OBJECT_ID('dbo.InstalledUpdates', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.InstalledUpdates (
        Id               INT IDENTITY(1,1) PRIMARY KEY,
        ComputerName     NVARCHAR(128)    NOT NULL,
        Title            NVARCHAR(512)    NOT NULL,
        InstalledOn      DATE             NULL,
        ServiceID        NVARCHAR(64)     NULL,
        FirstSeenRunId   UNIQUEIDENTIFIER NOT NULL,
        LastSeenRunId    UNIQUEIDENTIFIER NOT NULL,
        FirstSeenAt      DATETIME2(3)     NOT NULL DEFAULT SYSUTCDATETIME(),
        LastSeenAt       DATETIME2(3)     NOT NULL DEFAULT SYSUTCDATETIME(),
        UninstalledAt    DATETIME2(3)     NULL,
        CONSTRAINT FK_InstalledUpdates_Computer FOREIGN KEY (ComputerName) REFERENCES dbo.Computers(ComputerName),
        CONSTRAINT FK_InstalledUpdates_FirstRun FOREIGN KEY (FirstSeenRunId) REFERENCES dbo.CollectionRuns(RunId),
        CONSTRAINT FK_InstalledUpdates_LastRun  FOREIGN KEY (LastSeenRunId)  REFERENCES dbo.CollectionRuns(RunId)
    );
    CREATE UNIQUE INDEX UX_InstalledUpdates_Natural ON dbo.InstalledUpdates (ComputerName, Title);
    PRINT '  Created dbo.InstalledUpdates (differential schema)';
END
ELSE
    PRINT '  dbo.InstalledUpdates already in differential shape';

-- ============================================================
-- 2. Discover snapshot fact tables (have RunId + CreatedAt, V2 shape)
-- ============================================================

DECLARE @FactTables TABLE (TableName NVARCHAR(128) PRIMARY KEY);

INSERT INTO @FactTables (TableName)
SELECT t.name
FROM sys.tables t
INNER JOIN sys.columns c1 ON c1.object_id = t.object_id AND c1.name = 'ComputerName'
INNER JOIN sys.columns c2 ON c2.object_id = t.object_id AND c2.name = 'RunId'
INNER JOIN sys.columns c3 ON c3.object_id = t.object_id AND c3.name = 'CreatedAt'
WHERE t.schema_id = SCHEMA_ID('dbo')
  AND t.name NOT IN ('Computers', 'CollectionRuns', 'InstalledUpdates');

DECLARE @TableCount INT = (SELECT COUNT(*) FROM @FactTables);
PRINT '  Found ' + CAST(@TableCount AS NVARCHAR(10)) + ' V2 snapshot fact table(s) to upgrade';

-- ============================================================
-- 3. Per-table: drop UpdateTimeStamp, tighten RunId, add FKs + UNIQUE indexes
-- ============================================================

-- Natural keys per table. Mirrors $KeyColumnsMap in UpdateSQLTableFromJSON_new.ps1,
-- always prefixed with RunId so idempotent re-runs of the same RunId are
-- caught by the UNIQUE index instead of producing duplicates.
DECLARE @NaturalKeys TABLE (TableName NVARCHAR(128), KeyColumns NVARCHAR(512));
INSERT INTO @NaturalKeys VALUES
    ('SystemInfo',           'RunId, ComputerName'),
    ('DiskSpace',            'RunId, ComputerName, Drive'),
    ('InstalledSoftware',    'RunId, ComputerName, DisplayName, DisplayVersion'),
    ('Services',             'RunId, ComputerName, Name'),
    ('AutoRunInfo',          'RunId, ComputerName, Name'),
    ('LocalUsers',           'RunId, ComputerName, UserName'),
    ('GroupMembers',         'RunId, ComputerName, GroupName'),
    ('ScheduledTasks',       'RunId, ComputerName, TaskPath, TaskName'),
    ('PersonalCertificates', 'RunId, ComputerName, Thumbprint'),
    ('ShareAccessInfo',      'RunId, ComputerName, ShareName'),
    ('UserProfileList',      'RunId, ComputerName, Name'),
    ('MPComputerStatus',     'RunId, ComputerName');

DECLARE @TableName NVARCHAR(128);
DECLARE @sql NVARCHAR(MAX);
DECLARE @defaultConstraint NVARCHAR(256);
DECLARE @nullCount INT;
DECLARE @keyColumns NVARCHAR(512);

DECLARE TableCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName FROM @FactTables ORDER BY TableName;
OPEN TableCursor;
FETCH NEXT FROM TableCursor INTO @TableName;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Drop UpdateTimeStamp + its default constraint
    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName))
                 AND name = 'UpdateTimeStamp')
    BEGIN
        SET @defaultConstraint = NULL;
        SELECT @defaultConstraint = dc.name
        FROM sys.default_constraints dc
        INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
        WHERE dc.parent_object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName))
          AND c.name = 'UpdateTimeStamp';

        IF @defaultConstraint IS NOT NULL
        BEGIN
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) +
                       N' DROP CONSTRAINT ' + QUOTENAME(@defaultConstraint);
            EXEC sp_executesql @sql;
        END

        SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) + N' DROP COLUMN UpdateTimeStamp';
        EXEC sp_executesql @sql;
        PRINT '  Dropped ' + @TableName + '.UpdateTimeStamp';
    END

    -- Tighten RunId to NOT NULL (only if every row already has one)
    IF EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName))
                 AND name = 'RunId' AND is_nullable = 1)
    BEGIN
        SET @nullCount = 0;
        SET @sql = N'SELECT @c = COUNT(*) FROM dbo.' + QUOTENAME(@TableName) + N' WHERE RunId IS NULL';
        EXEC sp_executesql @sql, N'@c INT OUTPUT', @c = @nullCount OUTPUT;
        IF @nullCount = 0
        BEGIN
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) +
                       N' ALTER COLUMN RunId UNIQUEIDENTIFIER NOT NULL';
            EXEC sp_executesql @sql;
            PRINT '  Tightened ' + @TableName + '.RunId to NOT NULL';
        END
        ELSE
            PRINT '  Skipped tightening ' + @TableName + '.RunId (' + CAST(@nullCount AS NVARCHAR(10)) + ' NULL row(s))';
    END

    -- FK on RunId -> CollectionRuns (CASCADE so retention deletes propagate)
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                   WHERE name = 'FK_' + @TableName + '_Run'
                     AND parent_object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName)))
    BEGIN
        BEGIN TRY
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) +
                       N' ADD CONSTRAINT FK_' + @TableName + N'_Run' +
                       N' FOREIGN KEY (RunId) REFERENCES dbo.CollectionRuns(RunId) ON DELETE CASCADE';
            EXEC sp_executesql @sql;
            PRINT '  Added FK_' + @TableName + '_Run (ON DELETE CASCADE)';
        END TRY
        BEGIN CATCH
            PRINT '  FK_' + @TableName + '_Run could not be added: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- FK on ComputerName -> Computers
    IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
                   WHERE name = 'FK_' + @TableName + '_Computer'
                     AND parent_object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName)))
    BEGIN
        BEGIN TRY
            SET @sql = N'ALTER TABLE dbo.' + QUOTENAME(@TableName) +
                       N' ADD CONSTRAINT FK_' + @TableName + N'_Computer' +
                       N' FOREIGN KEY (ComputerName) REFERENCES dbo.Computers(ComputerName)';
            EXEC sp_executesql @sql;
            PRINT '  Added FK_' + @TableName + '_Computer';
        END TRY
        BEGIN CATCH
            PRINT '  FK_' + @TableName + '_Computer could not be added: ' + ERROR_MESSAGE();
        END CATCH
    END

    -- UNIQUE index on natural key (idempotent append-only safety net).
    -- Often fails on existing fact tables because key columns (DisplayName,
    -- ShareName, Name, ...) are NVARCHAR(MAX), which SQL Server forbids as
    -- index key columns. We skip silently when that's the case - the Update
    -- script's INSERT WHERE NOT EXISTS pattern already provides idempotency.
    -- Operators can manually ALTER columns to NVARCHAR(450) and re-run this
    -- migration to add the index where data widths permit.
    SET @keyColumns = (SELECT KeyColumns FROM @NaturalKeys WHERE TableName = @TableName);
    IF @keyColumns IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes
                       WHERE name = 'UX_' + @TableName + '_Natural'
                         AND object_id = OBJECT_ID('dbo.' + QUOTENAME(@TableName)))
    BEGIN
        BEGIN TRY
            SET @sql = N'CREATE UNIQUE INDEX UX_' + @TableName + N'_Natural ON dbo.' +
                       QUOTENAME(@TableName) + N' (' + @keyColumns + N')';
            EXEC sp_executesql @sql;
            PRINT '  Added UX_' + @TableName + '_Natural';
        END TRY
        BEGIN CATCH
            PRINT '  UX_' + @TableName + '_Natural skipped: ' + ERROR_MESSAGE();
        END CATCH
    END

    FETCH NEXT FROM TableCursor INTO @TableName;
END
CLOSE TableCursor; DEALLOCATE TableCursor;

-- ============================================================
-- 4. vCurrent* views per snapshot fact table (latest run per Computer)
-- ============================================================

DECLARE ViewCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT TableName FROM @FactTables ORDER BY TableName;
OPEN ViewCursor;
FETCH NEXT FROM ViewCursor INTO @TableName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'
        CREATE OR ALTER VIEW dbo.vCurrent' + @TableName + N' AS
        WITH LatestRuns AS (
            SELECT r.ComputerName, r.RunId
            FROM dbo.CollectionRuns r
            INNER JOIN (
                SELECT ComputerName, MAX(StartedAt) AS LatestAt
                FROM dbo.CollectionRuns
                WHERE Status = ''Loaded''
                GROUP BY ComputerName
            ) m ON r.ComputerName = m.ComputerName AND r.StartedAt = m.LatestAt
        )
        SELECT s.*
        FROM dbo.' + QUOTENAME(@TableName) + N' s
        INNER JOIN LatestRuns lr ON s.RunId = lr.RunId';
    EXEC sp_executesql @sql;
    PRINT '  Created/refreshed vCurrent' + @TableName;
    FETCH NEXT FROM ViewCursor INTO @TableName;
END
CLOSE ViewCursor; DEALLOCATE ViewCursor;

-- ============================================================
-- 5. Cross-table views the frontend will care about
-- ============================================================

EXEC sp_executesql N'
CREATE OR ALTER VIEW dbo.vCurrentInstalledUpdates AS
SELECT * FROM dbo.InstalledUpdates WHERE UninstalledAt IS NULL';

EXEC sp_executesql N'
CREATE OR ALTER VIEW dbo.vStaleComputers AS
SELECT c.*, DATEDIFF(HOUR, c.LastSeenAt, SYSUTCDATETIME()) AS HoursSinceLastSeen
FROM dbo.Computers c
WHERE c.IsActive = 1 AND c.LastSeenAt < DATEADD(HOUR, -25, SYSUTCDATETIME())';

PRINT '  Created/refreshed vCurrentInstalledUpdates, vStaleComputers';

PRINT 'V2 Phase 3 migration complete.';
