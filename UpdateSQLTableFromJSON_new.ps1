Param(
    [Parameter(Mandatory=$true)]
    [string]$SqlServer,
    [Parameter(Mandatory=$true)]
    [string]$Database,
    [Parameter(Mandatory=$true)]
    [string]$JsonFilesPath,
    [Parameter(Mandatory=$true)]
    [string]$logFilePath
)

# PowerShell Script to Update SQL Tables from JSON Files

# Dot-source shared SQL helpers
. (Join-Path -Path $PSScriptRoot -ChildPath "SqlHelpers.ps1")

$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

# Script-scoped error flag - any per-record or outer catch below sets this;
# final exit code uses it so the scheduler's step gating actually breaks the
# chain on failure instead of always returning success.
$script:hasErrors = $false

# Define a dictionary mapping table names to key columns
$KeyColumnsMap = @{
    "PersonalCertificates" = @("ComputerName", "Thumbprint")
    "LocalUsers" = @("ComputerName", "UserName")
    "GroupMembers" = @("ComputerName", "GroupName")
    "AutoRunInfo" = @("ComputerName", "Name")
    "DiskSpace" = @("ComputerName", "Drive")
    "InstalledUpdates" = @("ComputerName", "Title")
    "InstalledSoftware" = @("ComputerName", "DisplayName","DisplayVersion")
    "UserProfileList" = @("ComputerName", "Name")
    "ShareAccessInfo" = @("ComputerName", "ShareName")
    "Services" = @("ComputerName", "Name")
}


# Schema V2: load the per-run metadata aggregated by ParseInventory.ps1.
# Upserts dbo.Computers (LastSeenAt, LastRunId) and inserts new rows into
# dbo.CollectionRuns, skipping RunIds that already exist (idempotent).
function Import-CollectionRunsJson {
    param (
        [string]$JsonFilePath
    )

    if (-not (Test-Path $JsonFilePath)) { return }

    try {
        $runs = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        if (-not ($runs -is [System.Array])) { $runs = @($runs) }

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()
            $SqlCommand = $SqlConnection.CreateCommand()

            foreach ($run in $runs) {
                if (-not $run.RunId -or -not $run.ComputerName) { continue }

                # Upsert Computers
                $SqlCommand.Parameters.Clear()
                $SqlCommand.CommandText = @"
MERGE dbo.Computers AS target
USING (SELECT @cn AS ComputerName, @rid AS RunId, @loadedAt AS LoadedAt) AS source
ON (target.ComputerName = source.ComputerName)
WHEN MATCHED THEN
    UPDATE SET LastSeenAt = source.LoadedAt, LastRunId = source.RunId, IsActive = 1, DeactivatedAt = NULL
WHEN NOT MATCHED THEN
    INSERT (ComputerName, FirstSeenAt, LastSeenAt, LastRunId)
    VALUES (source.ComputerName, source.LoadedAt, source.LoadedAt, source.RunId);
"@
                $SqlCommand.Parameters.AddWithValue('@cn',  $run.ComputerName) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@rid', [System.Guid]::Parse([string]$run.RunId)) | Out-Null
                $loadedAt = if ($run.CompletedAt) { [DateTime]::Parse([string]$run.CompletedAt) } else { [DateTime]::UtcNow }
                $SqlCommand.Parameters.AddWithValue('@loadedAt', $loadedAt) | Out-Null
                $SqlCommand.ExecuteNonQuery() | Out-Null

                # Insert into CollectionRuns if RunId is new
                $SqlCommand.Parameters.Clear()
                $SqlCommand.CommandText = @"
IF NOT EXISTS (SELECT 1 FROM dbo.CollectionRuns WHERE RunId = @rid)
INSERT INTO dbo.CollectionRuns
    (RunId, ComputerName, StartedAt, CompletedAt, Status, MetricsSucceeded, MetricsFailed, FailedMetrics, LoadedAt)
VALUES
    (@rid, @cn, @started, @completed, 'Loaded', @ms, @mf, @fm, SYSUTCDATETIME());
"@
                $SqlCommand.Parameters.AddWithValue('@rid', [System.Guid]::Parse([string]$run.RunId)) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@cn',  $run.ComputerName) | Out-Null
                $started   = if ($run.StartedAt)   { [DateTime]::Parse([string]$run.StartedAt) }   else { [DateTime]::UtcNow }
                $completed = if ($run.CompletedAt) { [DateTime]::Parse([string]$run.CompletedAt) } else { $started }
                $SqlCommand.Parameters.AddWithValue('@started',   $started)   | Out-Null
                $SqlCommand.Parameters.AddWithValue('@completed', $completed) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@ms', $(if ($null -ne $run.MetricsSucceeded) { [int]$run.MetricsSucceeded } else { [DBNull]::Value })) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@mf', $(if ($null -ne $run.MetricsFailed)    { [int]$run.MetricsFailed }    else { [DBNull]::Value })) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@fm', $(if ($run.FailedMetrics) { [string]$run.FailedMetrics } else { [DBNull]::Value })) | Out-Null
                $SqlCommand.ExecuteNonQuery() | Out-Null
            }

            Write-Host "CollectionRuns imported: $($runs.Count) run(s)"
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        $script:hasErrors = $true
        Write-Error "Error importing CollectionRuns from $JsonFilePath : $_"
    }
}

function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $JsonContent = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        Test-SqlIdentifier -Name $TableName -Context "table name"

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()

            # Create SQL command
            $SqlCommand = $SqlConnection.CreateCommand()

            foreach ($Item in $JsonContent) {
                $SqlCommand.Parameters.Clear()

                # Determine key columns for this table
                if ($KeyColumnsMap.ContainsKey($TableName)) {
                    $KeyColumns = $KeyColumnsMap[$TableName]
                } else {
                    $KeyColumns = @("ComputerName")
                }

                # Build parameterized WHERE condition for existence check
                $Condition = Add-ParameterizedCondition -SqlCommand $SqlCommand -Item $Item -KeyColumns $KeyColumns -Prefix "k"

                # Check if the record exists
                $SqlCommand.CommandText = "SELECT COUNT(*) FROM [$TableName] WHERE $Condition"
                $RecordExists = $SqlCommand.ExecuteScalar()

                if ($RecordExists -gt 0) {
                    # Record exists: perform parameterized UPDATE
                    $SqlCommand.Parameters.Clear()

                    $SetClause = Add-ParameterizedSetClause -SqlCommand $SqlCommand -Item $Item -Prefix "s"
                    $Condition = Add-ParameterizedCondition -SqlCommand $SqlCommand -Item $Item -KeyColumns $KeyColumns -Prefix "k"

                    $SqlCommand.CommandText = "UPDATE [$TableName] SET $SetClause WHERE $Condition"
                    try {
                        $SqlCommand.ExecuteNonQuery() | Out-Null
                    } catch {
                        $script:hasErrors = $true
                        $errorMessage = "Error updating table $TableName : $($_.Exception.Message)"
                        $errorMessage | Out-File -FilePath $logFilePath -Append
                    }

                } else {
                    # No record exists: perform parameterized INSERT
                    $SqlCommand.Parameters.Clear()

                    $paramInfo = Add-ParameterizedValues -SqlCommand $SqlCommand -Item $Item -Prefix "p"

                    $SqlCommand.CommandText = "INSERT INTO [$TableName] ($($paramInfo.Columns)) VALUES ($($paramInfo.Placeholders))"
                    try {
                        $SqlCommand.ExecuteNonQuery() | Out-Null
                    } catch {
                        $script:hasErrors = $true
                        $errorMessage = "Error inserting into table $TableName : $($_.Exception.Message)"
                        $errorMessage | Out-File -FilePath $logFilePath -Append
                    }
                }
            }

            # Customized output message
            $ComputerName = $JsonContent.ComputerName | Select-Object -Unique
            Write-Host "Table $TableName updated for $ComputerName"
        }
        finally {
            $SqlConnection.Dispose()
        }

    }
    catch {
        $script:hasErrors = $true
        Write-Error "An error occurred: $_"
    }
}

# Schema V2: ingest CollectionRuns + Computers metadata FIRST so the FK targets
# are in place before any fact rows reference them. The file is optional - old
# zips lacking _collection-meta.json simply skip this step and rely on Phase 1
# migration / fallback to populate the run identity later.
$collectionRunsPath = Join-Path -Path $JsonFilesPath -ChildPath 'CollectionRuns.json'
if (Test-Path $collectionRunsPath) {
    Import-CollectionRunsJson -JsonFilePath $collectionRunsPath
}

# Iterate over each JSON file and update the corresponding table.
# CollectionRuns.json is handled above; skip it here so it doesn't get fed
# through the generic table loader.
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -ne 'CollectionRuns'
} | ForEach-Object {
    Write-Output ((Get-Date).ToString() + " Updating table from file: " + $($_.FullName))
    ((Get-Date).ToString() + " Updating table from file: " + $($_.FullName)) | Out-File -FilePath $logFilePath -Append
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}

if ($script:hasErrors) { exit 1 } else { exit 0 }
