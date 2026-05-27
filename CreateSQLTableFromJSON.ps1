Param(
    [Parameter(Mandatory=$true)]
    [string]$SqlServer,
    [Parameter(Mandatory=$true)]
    [string]$Database,
    [Parameter(Mandatory=$true)]
    [string]$JsonFilesPath
)

# Dot-source shared SQL helpers
. (Join-Path -Path $PSScriptRoot -ChildPath "SqlHelpers.ps1")

# Define SQL Server connection details
$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

# Script-scoped error flag - any catch below sets this; final exit code uses it
# so the scheduler's step gating actually breaks the chain on failure.
$script:hasErrors = $false

# Initialise the infrastructure tables (Computers, CollectionRuns, the
# differential InstalledUpdates table, and the cross-table views) in one
# idempotent pass. Fact tables are created later by New-SqlTableFromJson with
# their JSON-derived columns plus RunId NOT NULL, FKs, and a vCurrent<Table>
# view.
function Initialize-InfrastructureTables {
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()
        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = @"
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
END

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
        LoadedAt          DATETIME2(3)     NULL,
        CONSTRAINT FK_CollectionRuns_Computer FOREIGN KEY (ComputerName) REFERENCES dbo.Computers(ComputerName)
    );
    CREATE INDEX IX_CollectionRuns_Computer_Started
        ON dbo.CollectionRuns (ComputerName, StartedAt DESC);
END

-- InstalledUpdates: differential model (not snapshot). One row per
-- (ComputerName, Title) with FirstSeenRunId/LastSeenRunId/UninstalledAt.
-- Avoids the ~45M-row daily-snapshot blow-up.
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
        CONSTRAINT FK_InstalledUpdates_Computer  FOREIGN KEY (ComputerName)   REFERENCES dbo.Computers(ComputerName),
        CONSTRAINT FK_InstalledUpdates_FirstRun  FOREIGN KEY (FirstSeenRunId) REFERENCES dbo.CollectionRuns(RunId),
        CONSTRAINT FK_InstalledUpdates_LastRun   FOREIGN KEY (LastSeenRunId)  REFERENCES dbo.CollectionRuns(RunId)
    );
    CREATE UNIQUE INDEX UX_InstalledUpdates_Natural ON dbo.InstalledUpdates (ComputerName, Title);
    -- FK targets: without these, CollectionRuns DELETE would force a full
    -- table scan to validate FK_InstalledUpdates_FirstRun / _LastRun.
    CREATE INDEX IX_InstalledUpdates_FirstRun ON dbo.InstalledUpdates (FirstSeenRunId);
    CREATE INDEX IX_InstalledUpdates_LastRun  ON dbo.InstalledUpdates (LastSeenRunId);
END
"@
        $SqlCommand.ExecuteNonQuery() | Out-Null

        # Cross-table views (CREATE OR ALTER lives outside the IF blocks so
        # each fresh run refreshes them in case the definitions change).
        $SqlCommand.CommandText = @"
CREATE OR ALTER VIEW dbo.vCurrentInstalledUpdates AS
SELECT * FROM dbo.InstalledUpdates WHERE UninstalledAt IS NULL;
"@
        $SqlCommand.ExecuteNonQuery() | Out-Null

        $SqlCommand.CommandText = @"
CREATE OR ALTER VIEW dbo.vStaleComputers AS
SELECT c.*, DATEDIFF(HOUR, c.LastSeenAt, SYSUTCDATETIME()) AS HoursSinceLastSeen
FROM dbo.Computers c
WHERE c.IsActive = 1 AND c.LastSeenAt < DATEADD(HOUR, -25, SYSUTCDATETIME());
"@
        $SqlCommand.ExecuteNonQuery() | Out-Null
    }
    finally {
        $SqlConnection.Dispose()
    }
}

# Function to check if a table exists
function Test-SqlTableExists {
    param (
        [string]$TableName
    )

    Test-SqlIdentifier -Name $TableName -Context "table name"

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()

        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @TableName"
        $SqlCommand.Parameters.AddWithValue("@TableName", $TableName) | Out-Null
        $result = $SqlCommand.ExecuteScalar()

        return $result -gt 0
    }
    finally {
        $SqlConnection.Dispose()
    }
}

# Function to get the current schema of a table
function Get-SqlTableSchema {
    param (
        [string]$TableName
    )

    Test-SqlIdentifier -Name $TableName -Context "table name"

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()

        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @TableName"
        $SqlCommand.Parameters.AddWithValue("@TableName", $TableName) | Out-Null
        $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter $SqlCommand
        $DataSet = New-Object System.Data.DataSet
        $Adapter.Fill($DataSet)

        return $DataSet.Tables[0].Rows | ForEach-Object { $_.COLUMN_NAME }
    }
    finally {
        $SqlConnection.Dispose()
    }
}

# Creates the vCurrent<TableName> view: latest-Loaded-run snapshot per
# ComputerName.
function New-VCurrentView {
    param ([string]$TableName)

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"

        $sql = @"
CREATE OR ALTER VIEW dbo.vCurrent$TableName AS
WITH LatestRuns AS (
    SELECT r.ComputerName, r.RunId
    FROM dbo.CollectionRuns r
    INNER JOIN (
        SELECT ComputerName, MAX(StartedAt) AS LatestAt
        FROM dbo.CollectionRuns
        WHERE Status = 'Loaded'
        GROUP BY ComputerName
    ) m ON r.ComputerName = m.ComputerName AND r.StartedAt = m.LatestAt
)
SELECT s.*
FROM dbo.[$TableName] s
INNER JOIN LatestRuns lr ON s.RunId = lr.RunId;
"@

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()
            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $sql
            $SqlCommand.ExecuteNonQuery() | Out-Null
            Write-Host "View vCurrent$TableName created/refreshed."
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred while creating vCurrent$TableName : $_"
    }
}

# Function to create a SQL table from a JSON schema
function New-SqlTableFromJson {
    param (
        [string]$TableName,
        [PSCustomObject]$FirstJsonItem
    )

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"

        # Natural-key string columns must fit SQL Server's 1700-byte index
        # key limit. NVARCHAR(MAX) can't be in an index key at all, so cap any
        # column that appears in the natural key to NVARCHAR(256).
        $naturalKeyCols = Get-NaturalKey -TableName $TableName
        $indexedStringCols = @{}
        foreach ($k in $naturalKeyCols) {
            if ($k -ne 'RunId' -and $k -ne 'ComputerName') { $indexedStringCols[$k] = $true }
        }

        # Start building the SQL CREATE TABLE command
        $SqlCreateTableCommand = "CREATE TABLE [$TableName] ("
        $columnsFromJson = @{}

        # Process each property in the JSON object to create column definitions
        foreach ($Property in $FirstJsonItem.PSObject.Properties) {
            $ColumnName = $Property.Name
            Test-SqlIdentifier -Name $ColumnName -Context "column name"

            # Special-case columns whose semantics are fixed by the schema.
            # Everything else takes the default NVARCHAR(MAX) / INT / BIT mapping.
            switch ($ColumnName) {
                'ComputerName' { $DataType = "NVARCHAR(128) NOT NULL" }
                'RunId'        { $DataType = "UNIQUEIDENTIFIER NOT NULL" }
                'CreatedAt'    { $DataType = "DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()" }
                default {
                    $DataType = switch ($Property.TypeNameOfValue) {
                        "System.String"  { if ($indexedStringCols.ContainsKey($ColumnName)) { "NVARCHAR(256)" } else { "NVARCHAR(MAX)" } }
                        "System.Int32"   { "BIGINT" }
                        "System.Int64"   { "BIGINT" }
                        "System.Boolean" { "BIT" }
                        Default          { if ($indexedStringCols.ContainsKey($ColumnName)) { "NVARCHAR(256)" } else { "NVARCHAR(MAX)" } }
                    }
                }
            }

            $SqlCreateTableCommand += "[$ColumnName] $DataType, "
            $columnsFromJson[$ColumnName] = $true
        }

        # Surrogate PK for backwards-compat with any tooling that joins on Id.
        $SqlCreateTableCommand += "[Id] INT IDENTITY(1,1) PRIMARY KEY"

        # RunId + CreatedAt are always present on every fact table. Add them
        # if the JSON didn't supply them (the pipeline always supplies RunId;
        # the CreatedAt clause covers data flowing in via other entry points).
        if (-not $columnsFromJson.ContainsKey('RunId')) {
            $SqlCreateTableCommand += ", [RunId] UNIQUEIDENTIFIER NOT NULL"
            $columnsFromJson['RunId'] = $true
        }
        if (-not $columnsFromJson.ContainsKey('CreatedAt')) {
            $SqlCreateTableCommand += ", [CreatedAt] DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()"
        }

        # FK constraints inline. Retention's ON DELETE CASCADE on RunId is the
        # whole reason this works as a single DELETE FROM CollectionRuns.
        if ($columnsFromJson.ContainsKey('ComputerName')) {
            $SqlCreateTableCommand += ", CONSTRAINT [FK_${TableName}_Computer] FOREIGN KEY ([ComputerName]) REFERENCES dbo.Computers([ComputerName])"
        }
        $SqlCreateTableCommand += ", CONSTRAINT [FK_${TableName}_Run] FOREIGN KEY ([RunId]) REFERENCES dbo.CollectionRuns([RunId]) ON DELETE CASCADE"

        $SqlCreateTableCommand += ")"

        # Create and open SQL connection
        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()

            # Execute the SQL command
            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $SqlCreateTableCommand
            $SqlCommand.ExecuteNonQuery()

            Write-Host "Table $TableName created successfully."

            # UNIQUE index on (RunId, ...natural key...). Leftmost RunId makes
            # cascade deletes seek instead of scan; the full natural key makes
            # the WHERE NOT EXISTS dedup a covering seek too. UNIQUE doubles
            # as a defense-in-depth idempotency guarantee.
            $naturalKey = Get-NaturalKey -TableName $TableName
            $keyCols    = ($naturalKey | ForEach-Object { "[$_]" }) -join ', '
            $SqlCommand.CommandText = "CREATE UNIQUE NONCLUSTERED INDEX [UX_${TableName}_Natural] ON [$TableName] ($keyCols)"
            $SqlCommand.ExecuteNonQuery() | Out-Null
            Write-Host "Index UX_${TableName}_Natural created on ($($naturalKey -join ', '))."
        }
        finally {
            $SqlConnection.Dispose()
        }

        New-VCurrentView -TableName $TableName
    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred while creating $TableName : $_"
    }
}

# Function to add a new column to an existing table
function Add-SqlColumn {
    param (
        [string]$TableName,
        [string]$ColumnName,
        [string]$DataType
    )

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"
        Test-SqlIdentifier -Name $ColumnName -Context "column name"

        $SqlAddColumnCommand = "ALTER TABLE [$TableName] ADD [$ColumnName] $DataType"

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()

            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $SqlAddColumnCommand
            $SqlCommand.ExecuteNonQuery()

            Write-Host "Column $ColumnName added to $TableName."
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred while adding column $ColumnName to $TableName : $_"
    }
}

# Function to remove a column from an existing table
function Remove-SqlColumn {
    param (
        [string]$TableName,
        [string]$ColumnName
    )

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"
        Test-SqlIdentifier -Name $ColumnName -Context "column name"

        $SqlRemoveColumnCommand = "ALTER TABLE [$TableName] DROP COLUMN [$ColumnName]"

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()

            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $SqlRemoveColumnCommand
            $SqlCommand.ExecuteNonQuery()

            Write-Host "Column $ColumnName removed from $TableName."
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred while removing column $ColumnName from $TableName : $_"
    }
}

# Builds one PSCustomObject whose property set is the UNION of every row's
# properties. For each property the first non-null value seen wins, falling
# back to $null if it's null everywhere. Heterogeneous JSON (some servers
# expose extra Defender fields, properties that are null fleet-wide on this
# snapshot, etc.) needs this so every column makes it into the CREATE/ALTER.
function Get-MergedJsonItem {
    param ([Parameter(Mandatory)]$JsonArray)
    if (-not ($JsonArray -is [System.Array])) { $JsonArray = @($JsonArray) }

    $merged = [ordered]@{}
    foreach ($row in $JsonArray) {
        if ($null -eq $row) { continue }
        foreach ($prop in $row.PSObject.Properties) {
            if (-not $merged.Contains($prop.Name)) {
                $merged[$prop.Name] = $prop.Value
            } elseif ($null -eq $merged[$prop.Name] -and $null -ne $prop.Value) {
                $merged[$prop.Name] = $prop.Value
            }
        }
    }
    return [PSCustomObject]$merged
}

# Function to update a SQL table based on JSON schema
function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $JsonArray = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        $MergedItem = Get-MergedJsonItem -JsonArray $JsonArray
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        if (-not (Test-SqlTableExists -TableName $TableName)) {
            Write-Host "Creating new table: $TableName"
            New-SqlTableFromJson -TableName $TableName -FirstJsonItem $MergedItem
        } else {
            Write-Host "Updating existing table: $TableName"
            $CurrentSchema = Get-SqlTableSchema -TableName $TableName
            $JsonSchema = $MergedItem.PSObject.Properties.Name

            # Add new columns found in JSON but not in SQL table
            foreach ($Column in $JsonSchema) {
                if ($Column -notin $CurrentSchema) {
                    $val = $MergedItem.$Column
                    $DataType = if ($null -eq $val) { "NVARCHAR(MAX)" }
                        else { switch ($val.GetType().Name) {
                            "String"  { "NVARCHAR(MAX)" }
                            "Int32"   { "BIGINT" }
                            "Int64"   { "BIGINT" }
                            "Boolean" { "BIT" }
                            Default   { "NVARCHAR(MAX)" }
                        } }
                    Add-SqlColumn -TableName $TableName -ColumnName $Column -DataType $DataType
                }
            }
        }
    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred while processing $TableName : $_"
    }
}

# Make sure the infrastructure (Computers, CollectionRuns, InstalledUpdates,
# cross-table views) exists before processing any JSON. Idempotent.
Initialize-InfrastructureTables

# CollectionRuns + InstalledUpdates are loaded by the Update script, not
# created from JSON shape.
$SkipTables = @('CollectionRuns', 'InstalledUpdates')
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $SkipTables
} | ForEach-Object {
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}

if ($script:hasErrors) { exit 1 } else { exit 0 }
