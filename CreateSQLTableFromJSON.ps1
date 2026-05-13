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

# Initialise V2 infrastructure tables (Computers + CollectionRuns) on every run.
# Idempotent: skips when already present. Mirrors docs/migrations/V2_Phase1.sql.
function Initialize-V2InfrastructureTables {
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
        LoadedAt          DATETIME2(3)     NULL
    );
    CREATE INDEX IX_CollectionRuns_Computer_Started
        ON dbo.CollectionRuns (ComputerName, StartedAt DESC);
END
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

# Function to create a SQL table from a JSON schema
function New-SqlTableFromJson {
    param (
        [string]$TableName,
        [PSCustomObject]$FirstJsonItem
    )

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"

        # Start building the SQL CREATE TABLE command
        $SqlCreateTableCommand = "CREATE TABLE [$TableName] ("
        $columnsFromJson = @{}

        # Process each property in the JSON object to create column definitions
        foreach ($Property in $FirstJsonItem.PSObject.Properties) {
            $ColumnName = $Property.Name
            Test-SqlIdentifier -Name $ColumnName -Context "column name"

            # Special-case columns whose semantics are fixed by Schema V2.
            # Everything else keeps the V1 NVARCHAR(MAX) / INT / BIT mapping.
            switch ($ColumnName) {
                'ComputerName' { $DataType = "NVARCHAR(128)" }
                'RunId'        { $DataType = "UNIQUEIDENTIFIER" }
                'CreatedAt'    { $DataType = "DATETIME2(3)" }
                default {
                    $DataType = switch ($Property.TypeNameOfValue) {
                        "System.String" { "NVARCHAR(MAX)" }
                        "System.Int32"  { "INT" }
                        "System.Boolean"{ "BIT" }
                        Default         { "NVARCHAR(MAX)" }
                    }
                }
            }

            $SqlCreateTableCommand += "[$ColumnName] $DataType, "
            $columnsFromJson[$ColumnName] = $true
        }

        # V1 columns: Id PK + UpdateTimeStamp (kept for Phase 1 compatibility,
        # dropped in Phase 3 after the pipeline emits RunId end-to-end).
        $SqlCreateTableCommand += "[Id] INT IDENTITY(1,1) PRIMARY KEY, "
        $SqlCreateTableCommand += "[UpdateTimeStamp] DATETIME DEFAULT GETDATE()"

        # V2 columns: RunId + CreatedAt - only add if the JSON didn't already
        # carry them as properties (Phase 2 pipeline output puts RunId on every
        # record).
        if (-not $columnsFromJson.ContainsKey('RunId')) {
            $SqlCreateTableCommand += ", [RunId] UNIQUEIDENTIFIER NULL"
        }
        if (-not $columnsFromJson.ContainsKey('CreatedAt')) {
            $SqlCreateTableCommand += ", [CreatedAt] DATETIME2(3) NULL"
        }
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
        }
        finally {
            $SqlConnection.Dispose()
        }
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

# Function to update a SQL table based on JSON schema
function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $JsonArray = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        $FirstJsonItem = if ($JsonArray -is [System.Array]) { $JsonArray[0] } else { $JsonArray }
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        if (-not (Test-SqlTableExists -TableName $TableName)) {
            Write-Host "Creating new table: $TableName"
            New-SqlTableFromJson -TableName $TableName -FirstJsonItem $FirstJsonItem
        } else {
            Write-Host "Updating existing table: $TableName"
            $CurrentSchema = Get-SqlTableSchema -TableName $TableName
            $JsonSchema = $FirstJsonItem.PSObject.Properties.Name

            # Add new columns found in JSON but not in SQL table
            foreach ($Column in $JsonSchema) {
                if ($Column -notin $CurrentSchema) {
                    $DataType = switch ($FirstJsonItem.$Column.GetType().Name) {
                        "String" { "NVARCHAR(MAX)" }
                        "Int32" { "INT" }
                        "Boolean" { "BIT" }
                        Default { "NVARCHAR(MAX)" }
                    }
                    Add-SqlColumn -TableName $TableName -ColumnName $Column -DataType $DataType
                }
            }

            # Optionally, remove columns from SQL table not found in JSON
            # Be cautious with this as it can lead to data loss
            # foreach ($Column in $CurrentSchema) {
            #     if ($Column -notin $JsonSchema -and $Column -ne 'Id' -and $Column -ne 'UpdateTimeStamp') {
            #         Remove-SqlColumn -TableName $TableName -ColumnName $Column
            #     }
            # }
        }
    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred while processing $TableName : $_"
    }
}

# Make sure the V2 infrastructure tables exist before processing any JSON
Initialize-V2InfrastructureTables

# Loop through each JSON file in the folder and create/update tables.
# CollectionRuns.json is the per-run metadata aggregated by ParseInventory.ps1
# (Schema V2) and goes into dbo.CollectionRuns directly via the Update script,
# not into a JSON-derived table.
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -ne 'CollectionRuns'
} | ForEach-Object {
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}

if ($script:hasErrors) { exit 1 } else { exit 0 }
