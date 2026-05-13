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

# Schema V2 Phase 3: load InstalledUpdates as a differential set per
# (ComputerName, Title). Each row is MERGEd - existing pairs get their
# LastSeenRunId / LastSeenAt refreshed (and UninstalledAt cleared if they
# had been marked uninstalled); new pairs INSERT with First = Last = @RunId.
# After the per-row pass, any (Computer, Title) we previously had but
# didn't see in this run gets UninstalledAt set.
function Import-InstalledUpdatesDifferential {
    param([Parameter(Mandatory)]$JsonContent)

    if (-not $JsonContent) { return }
    if (-not ($JsonContent -is [System.Array])) { $JsonContent = @($JsonContent) }

    # Group by (ComputerName, RunId) - typically one RunId per Computer
    $groups = @{}
    foreach ($Item in $JsonContent) {
        if (-not $Item -or -not $Item.ComputerName -or -not $Item.RunId) { continue }
        $key = "$($Item.ComputerName)|$($Item.RunId)"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = @{
                ComputerName = [string]$Item.ComputerName
                RunId        = [string]$Item.RunId
                Items        = New-Object System.Collections.Generic.List[object]
            }
        }
        $groups[$key].Items.Add($Item)
    }

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()
        $SqlCommand = $SqlConnection.CreateCommand()

        foreach ($group in $groups.Values) {
            $cn = $group.ComputerName
            $runIdGuid = [Guid]::Parse($group.RunId)

            foreach ($Item in $group.Items) {
                if (-not $Item.Title) { continue }
                $SqlCommand.Parameters.Clear()
                $SqlCommand.CommandText = @"
MERGE dbo.InstalledUpdates AS t
USING (SELECT @cn AS ComputerName, @title AS Title, @rid AS RunId,
              @installedOn AS InstalledOn, @serviceId AS ServiceID) AS s
ON (t.ComputerName = s.ComputerName AND t.Title = s.Title)
WHEN MATCHED THEN
    UPDATE SET LastSeenRunId = s.RunId,
               LastSeenAt    = SYSUTCDATETIME(),
               UninstalledAt = NULL,
               InstalledOn   = COALESCE(t.InstalledOn, s.InstalledOn),
               ServiceID     = COALESCE(t.ServiceID,   s.ServiceID)
WHEN NOT MATCHED THEN
    INSERT (ComputerName, Title, InstalledOn, ServiceID, FirstSeenRunId, LastSeenRunId)
    VALUES (s.ComputerName, s.Title, s.InstalledOn, s.ServiceID, s.RunId, s.RunId);
"@
                $SqlCommand.Parameters.AddWithValue('@cn',    $cn)            | Out-Null
                $SqlCommand.Parameters.AddWithValue('@title', [string]$Item.Title) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@rid',   $runIdGuid)     | Out-Null

                $installedOn = [DBNull]::Value
                if ($Item.Date) {
                    try { $installedOn = [DateTime]::Parse([string]$Item.Date).Date } catch { }
                } elseif ($Item.InstalledOn) {
                    try { $installedOn = [DateTime]::Parse([string]$Item.InstalledOn).Date } catch { }
                }
                $SqlCommand.Parameters.AddWithValue('@installedOn', $installedOn) | Out-Null
                $SqlCommand.Parameters.AddWithValue('@serviceId',
                    $(if ($Item.ServiceID) { [string]$Item.ServiceID } else { [DBNull]::Value })) | Out-Null

                try {
                    $SqlCommand.ExecuteNonQuery() | Out-Null
                } catch {
                    $script:hasErrors = $true
                    "Error MERGE InstalledUpdates ($cn / $($Item.Title)): $($_.Exception.Message)" |
                        Out-File -FilePath $logFilePath -Append
                }
            }

            # Sweep: anything for this Computer not touched by this RunId is gone
            $SqlCommand.Parameters.Clear()
            $SqlCommand.CommandText = @"
UPDATE dbo.InstalledUpdates
SET    UninstalledAt = SYSUTCDATETIME()
WHERE  ComputerName    = @cn
   AND LastSeenRunId  <> @rid
   AND UninstalledAt  IS NULL
"@
            $SqlCommand.Parameters.AddWithValue('@cn',  $cn)        | Out-Null
            $SqlCommand.Parameters.AddWithValue('@rid', $runIdGuid) | Out-Null
            $SqlCommand.ExecuteNonQuery() | Out-Null
        }

        Write-Host "InstalledUpdates differential: $($groups.Count) (Computer, RunId) group(s)"
    }
    finally {
        $SqlConnection.Dispose()
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

        # Schema V2 Phase 3: InstalledUpdates uses the differential model.
        if ($TableName -eq 'InstalledUpdates') {
            Import-InstalledUpdatesDifferential -JsonContent $JsonContent
            return
        }

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()
            $SqlCommand = $SqlConnection.CreateCommand()

            # Natural key for idempotent append-only inserts: always (RunId, ...)
            # so re-running the same RunId is a no-op via NOT EXISTS, but a new
            # RunId for the same logical row creates a new snapshot.
            $NaturalKey = if ($KeyColumnsMap.ContainsKey($TableName)) {
                @('RunId') + $KeyColumnsMap[$TableName]
            } else {
                @('RunId', 'ComputerName')
            }

            foreach ($Item in $JsonContent) {
                $SqlCommand.Parameters.Clear()

                # Build WHERE for the NOT EXISTS guard, then INSERT VALUES.
                $Condition = Add-ParameterizedCondition -SqlCommand $SqlCommand -Item $Item -KeyColumns $NaturalKey -Prefix 'k'
                $paramInfo = Add-ParameterizedValues   -SqlCommand $SqlCommand -Item $Item -Prefix 'p'

                $SqlCommand.CommandText = @"
INSERT INTO [$TableName] ($($paramInfo.Columns))
SELECT $($paramInfo.Placeholders)
WHERE NOT EXISTS (SELECT 1 FROM [$TableName] WHERE $Condition);
"@
                try {
                    $SqlCommand.ExecuteNonQuery() | Out-Null
                } catch {
                    $script:hasErrors = $true
                    $errorMessage = "Error inserting into table $TableName : $($_.Exception.Message)"
                    $errorMessage | Out-File -FilePath $logFilePath -Append
                }
            }

            $ComputerName = $JsonContent.ComputerName | Select-Object -Unique
            Write-Host "Table ${TableName}: appended snapshot for $ComputerName"
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
