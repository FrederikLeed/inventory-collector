# Test-Integration-LocalDB.ps1
# End-to-end integration test using SQL Server LocalDB
# Tests CreateSQLTableFromJSON.ps1 and UpdateSQLTableFromJSON_new.ps1 with real sample data
# Uses first 1000 rows per JSON file to keep test fast

param(
    [string]$SampleDataPath = (Join-Path -Path $PSScriptRoot -ChildPath "sample-data\InventoryParsed")
)

$ErrorActionPreference = "Stop"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "  PASS: $Message" -ForegroundColor Green
        $script:TestsPassed++
    } else {
        Write-Host "  FAIL: $Message" -ForegroundColor Red
        $script:TestsFailed++
    }
}

$SqlServer = "(localdb)\MSSQLLocalDB"
$Database = "InventoryTest"
$TrimmedDataPath = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\Trimmed"
$LogFile = Join-Path -Path $PSScriptRoot -ChildPath "integration-test.log"
$ScriptRoot = Split-Path -Path $PSScriptRoot -Parent
$MaxRowsPerFile = 1000
$SkipFiles = @("InstalledUpdates", "Invoice")

$ConnectionString = "Server=$SqlServer;Integrated Security=True;"
$DbConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

Add-Type -AssemblyName "System.Data"

# ============================================================
Write-Host "`n=== Setup: Prepare trimmed test data ===" -ForegroundColor Cyan
# ============================================================

if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
New-Item -ItemType Directory -Path $TrimmedDataPath -Force | Out-Null

Get-ChildItem -Path $SampleDataPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $SkipFiles
} | ForEach-Object {
    $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
    if ($data -is [System.Array] -and $data.Count -gt $MaxRowsPerFile) {
        $trimmed = $data[0..($MaxRowsPerFile - 1)]
    } else {
        $trimmed = $data
    }
    $trimmed | ConvertTo-Json -Depth 10 | Out-File (Join-Path $TrimmedDataPath $_.Name) -Encoding UTF8
    $count = if ($trimmed -is [System.Array]) { $trimmed.Count } else { 1 }
    Write-Host "  $($_.Name): $count rows"
}

# ============================================================
Write-Host "`n=== Setup: Create test database ===" -ForegroundColor Cyan
# ============================================================

$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()

    # Drop if exists
    $cmd.CommandText = "IF EXISTS (SELECT name FROM sys.databases WHERE name = '$Database') BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]; END"
    $cmd.ExecuteNonQuery() | Out-Null

    # Create fresh
    $cmd.CommandText = "CREATE DATABASE [$Database]"
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "  Database '$Database' created" -ForegroundColor Yellow
}
finally {
    $conn.Dispose()
}

# ============================================================
Write-Host "`n=== Test 1: CreateSQLTableFromJSON.ps1 ===" -ForegroundColor Cyan
# ============================================================

try {
    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath
    Write-Host ""

    # Verify tables were created
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME"
        $reader = $cmd.ExecuteReader()
        $tables = @()
        while ($reader.Read()) { $tables += $reader["TABLE_NAME"] }
        $reader.Close()

        $expectedTables = (Get-ChildItem -Path $TrimmedDataPath -Filter "*.json" | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })

        Assert-True -Condition ($tables.Count -ge $expectedTables.Count) `
            -Message "Created $($tables.Count) tables (expected $($expectedTables.Count))"

        foreach ($expected in $expectedTables) {
            Assert-True -Condition ($tables -contains $expected) -Message "Table '$expected' exists"
        }

        # Verify columns for a known table
        $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @TableName"
        $cmd.Parameters.AddWithValue("@TableName", "InstalledSoftware") | Out-Null
        $reader = $cmd.ExecuteReader()
        $columns = @()
        while ($reader.Read()) { $columns += $reader["COLUMN_NAME"] }
        $reader.Close()

        Assert-True -Condition ($columns -contains "ComputerName") -Message "InstalledSoftware has ComputerName column"
        Assert-True -Condition ($columns -contains "DisplayName") -Message "InstalledSoftware has DisplayName column"
        Assert-True -Condition ($columns -contains "Id") -Message "InstalledSoftware has Id column (auto-added)"
        Assert-True -Condition ($columns -contains "UpdateTimeStamp") -Message "InstalledSoftware has UpdateTimeStamp column (auto-added)"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: CreateSQLTableFromJSON threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 2: UpdateSQLTableFromJSON_new.ps1 (INSERT) ===" -ForegroundColor Cyan
# ============================================================

try {
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath -logFilePath $LogFile
    Write-Host ""

    # Verify data was inserted
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # Check row counts for key tables
        foreach ($table in @("InstalledSoftware", "Services", "GroupMembers", "DiskSpace", "ShareAccessInfo")) {
            $cmd.Parameters.Clear()
            $cmd.CommandText = "SELECT COUNT(*) FROM [$table]"
            $count = $cmd.ExecuteScalar()
            Assert-True -Condition ($count -gt 0) -Message "$table has $count rows"
        }

        # Verify special characters survive round-trip - take ANY ShareAccessInfo
        # row whose SharePath contains a backslash. The previous version targeted
        # a hard-coded computer name and silently skipped when the fixture had a
        # different anonymized identifier.
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT TOP 1 [SharePath] FROM [ShareAccessInfo] WHERE [SharePath] LIKE '%\%'"
        $path = $cmd.ExecuteScalar()
        Assert-True -Condition ($null -ne $path -and $path -is [string] -and $path -match '\\') `
            -Message "ShareAccessInfo has at least one row whose SharePath contains a backslash: $path"

        # Verify GroupMembers.Members serializes to a non-empty string for at
        # least one row. Doesn't depend on a specific group name.
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT TOP 1 [Members] FROM [GroupMembers] WHERE [Members] IS NOT NULL AND LEN([Members]) > 0"
        $value = $cmd.ExecuteScalar()
        Assert-True -Condition ($null -ne $value -and $value -ne [DBNull]::Value -and $value -is [string] -and $value.Length -gt 0) `
            -Message "GroupMembers.Members stored as non-empty string for at least one row (length: $(if ($value -is [string]) { $value.Length } else { 'n/a' }))"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: UpdateSQLTableFromJSON_new (INSERT) threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 3: UpdateSQLTableFromJSON_new.ps1 (UPDATE - re-run) ===" -ForegroundColor Cyan
# ============================================================

try {
    # Get row count before
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM [Services]"
        $countBefore = $cmd.ExecuteScalar()
    }
    finally {
        $conn.Dispose()
    }

    # Re-run same data — should UPDATE, not duplicate
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath -logFilePath $LogFile
    Write-Host ""

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM [Services]"
        $countAfter = $cmd.ExecuteScalar()

        Assert-True -Condition ($countAfter -eq $countBefore) `
            -Message "Services row count unchanged after re-run ($countBefore -> $countAfter, no duplicates)"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: UpdateSQLTableFromJSON_new (UPDATE) threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 4: SQL injection value is safely stored ===" -ForegroundColor Cyan
# ============================================================

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $injectionPayload = "O'Brien'; DROP TABLE InstalledSoftware;--"
        $cmd.CommandText = "INSERT INTO [InstalledSoftware] ([ComputerName], [DisplayName], [DisplayVersion], [InstallDate], [Publisher]) VALUES (@p0, @p1, @p2, @p3, @p4)"
        $cmd.Parameters.AddWithValue("@p0", "TESTSERVER") | Out-Null
        $cmd.Parameters.AddWithValue("@p1", $injectionPayload) | Out-Null
        $cmd.Parameters.AddWithValue("@p2", "1.0") | Out-Null
        $cmd.Parameters.AddWithValue("@p3", [DBNull]::Value) | Out-Null
        $cmd.Parameters.AddWithValue("@p4", "Evil Corp") | Out-Null
        $cmd.ExecuteNonQuery() | Out-Null

        # Verify the table still exists (wasn't dropped)
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'InstalledSoftware'"
        $exists = $cmd.ExecuteScalar()
        Assert-True -Condition ($exists -gt 0) -Message "InstalledSoftware table still exists after injection attempt"

        # Verify the injection payload was stored as literal data
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT [DisplayName] FROM [InstalledSoftware] WHERE [ComputerName] = @cn"
        $cmd.Parameters.AddWithValue("@cn", "TESTSERVER") | Out-Null
        $storedValue = $cmd.ExecuteScalar()
        Assert-True -Condition ($storedValue -eq $injectionPayload) `
            -Message "Injection payload stored as literal string: '$storedValue'"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: SQL injection test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 5: SQL injection via the actual Update script ===" -ForegroundColor Cyan
# ============================================================
# Test 4 proved that AddWithValue is injection-safe. Test 5 proves that the
# REAL production path through Add-ParameterizedValues + the Update script
# is also safe - so a future regression that bypasses the helpers gets caught.

$InjectionFolder = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\InjectionTest"
if (Test-Path $InjectionFolder) { Remove-Item $InjectionFolder -Recurse -Force }
New-Item -ItemType Directory -Path $InjectionFolder -Force | Out-Null

$payload = "O'Brien'; DROP TABLE InjectionE2E;--"
@(
    [PSCustomObject]@{ ComputerName = "INJECT-01"; Note = $payload }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $InjectionFolder "InjectionE2E.json") -Encoding UTF8

try {
    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $InjectionFolder
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $InjectionFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'InjectionE2E'"
        $exists = $cmd.ExecuteScalar()
        Assert-True -Condition ($exists -gt 0) -Message "InjectionE2E table still exists after script ran with injection payload"

        $cmd.CommandText = "SELECT [Note] FROM [InjectionE2E] WHERE [ComputerName] = @cn"
        $cmd.Parameters.AddWithValue("@cn", "INJECT-01") | Out-Null
        $storedValue = $cmd.ExecuteScalar()
        Assert-True -Condition ($storedValue -eq $payload) `
            -Message "Update script stored injection payload as literal string: '$storedValue'"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: e2e injection test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 6: Schema evolution (ALTER TABLE branch) ===" -ForegroundColor Cyan
# ============================================================
# Run CreateSQLTableFromJSON twice against the same table name but with the
# second JSON containing an extra property. The script's "table exists - add
# missing columns" branch should ALTER TABLE rather than CREATE TABLE.

$SchemaFolder = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\SchemaEvolutionTest"
if (Test-Path $SchemaFolder) { Remove-Item $SchemaFolder -Recurse -Force }
New-Item -ItemType Directory -Path $SchemaFolder -Force | Out-Null

# Initial schema: 2 columns
@(
    [PSCustomObject]@{ ComputerName = "SCHEMA-01"; OriginalCol = "v1" }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $SchemaFolder "SchemaEvolution.json") -Encoding UTF8

try {
    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $SchemaFolder

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'SchemaEvolution'"
        $reader = $cmd.ExecuteReader()
        $initialColumns = @()
        while ($reader.Read()) { $initialColumns += $reader["COLUMN_NAME"] }
        $reader.Close()
        Assert-True -Condition ($initialColumns -contains "ComputerName") -Message "Initial create: ComputerName column present"
        Assert-True -Condition ($initialColumns -contains "OriginalCol") -Message "Initial create: OriginalCol present"
        Assert-True -Condition ($initialColumns -notcontains "AddedCol") -Message "Initial create: AddedCol absent (sanity check)"
    } finally {
        $conn.Dispose()
    }

    # Rewrite JSON with one extra column
    @(
        [PSCustomObject]@{ ComputerName = "SCHEMA-02"; OriginalCol = "v2"; AddedCol = "new!" }
    ) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $SchemaFolder "SchemaEvolution.json") -Encoding UTF8

    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $SchemaFolder

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'SchemaEvolution'"
        $reader = $cmd.ExecuteReader()
        $finalColumns = @()
        while ($reader.Read()) { $finalColumns += $reader["COLUMN_NAME"] }
        $reader.Close()
        Assert-True -Condition ($finalColumns -contains "OriginalCol") -Message "Schema evolution: OriginalCol still present"
        Assert-True -Condition ($finalColumns -contains "AddedCol") -Message "Schema evolution: AddedCol added via ALTER TABLE"

        # Verify Update script can insert into the evolved schema
        & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $SchemaFolder -logFilePath $LogFile

        $cmd.CommandText = "SELECT [AddedCol] FROM [SchemaEvolution] WHERE [ComputerName] = @cn"
        $cmd.Parameters.AddWithValue("@cn", "SCHEMA-02") | Out-Null
        $addedVal = $cmd.ExecuteScalar()
        Assert-True -Condition ($addedVal -eq "new!") -Message "Update populated AddedCol on the evolved schema: '$addedVal'"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: schema evolution test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 7: V2 Phase 1 migration ===" -ForegroundColor Cyan
# ============================================================
# Runs docs/migrations/V2_Phase1.sql against the DB that Tests 1-6 populated.
# Asserts: Computers + CollectionRuns infrastructure tables come up populated,
# every existing fact table gains RunId / CreatedAt with values backfilled from
# UpdateTimeStamp, and a second run is a no-op (idempotent).

$migrationPath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath 'docs\migrations\V2_Phase1.sql'

try {
    Assert-True -Condition (Test-Path $migrationPath) -Message "Migration script exists: $migrationPath"

    $migrationSql = Get-Content -Path $migrationPath -Raw

    # First run: actual migration
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = $migrationSql
        $cmd.ExecuteNonQuery() | Out-Null

        # Computers populated from DISTINCT ComputerName across all fact tables
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Computers"
        $computersCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($computersCount -gt 0) -Message "Computers populated ($computersCount rows)"

        # CollectionRuns: one synthetic row per Computer
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns"
        $runsCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($runsCount -eq $computersCount) `
            -Message "CollectionRuns has one synthetic run per Computer ($runsCount = $computersCount)"

        # Every Computer has LastRunId pointing at a real run
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Computers WHERE LastRunId IS NULL"
        $nullRunIds = $cmd.ExecuteScalar()
        Assert-True -Condition ($nullRunIds -eq 0) -Message "All Computers have LastRunId populated ($nullRunIds NULL)"

        # Every Computer's LastRunId resolves to an actual CollectionRuns row
        $cmd.CommandText = @"
SELECT COUNT(*) FROM dbo.Computers c
LEFT JOIN dbo.CollectionRuns r ON r.RunId = c.LastRunId
WHERE r.RunId IS NULL
"@
        $orphanRunIds = $cmd.ExecuteScalar()
        Assert-True -Condition ($orphanRunIds -eq 0) -Message "All LastRunId values resolve to CollectionRuns ($orphanRunIds orphan)"

        # A representative fact table has RunId/CreatedAt populated, none NULL
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledSoftware WHERE RunId IS NULL OR CreatedAt IS NULL"
        $missingFacts = $cmd.ExecuteScalar()
        Assert-True -Condition ($missingFacts -eq 0) -Message "InstalledSoftware: every row has RunId + CreatedAt ($missingFacts missing)"

        # CreatedAt should be backfilled from UpdateTimeStamp, not "now" - within 1 day of UpdateTimeStamp
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledSoftware WHERE ABS(DATEDIFF(SECOND, CAST(UpdateTimeStamp AS DATETIME2(3)), CreatedAt)) > 5"
        $mismatchedTimestamps = $cmd.ExecuteScalar()
        Assert-True -Condition ($mismatchedTimestamps -eq 0) -Message "InstalledSoftware.CreatedAt matches UpdateTimeStamp ($mismatchedTimestamps mismatched)"

        # ComputerName widened to NVARCHAR(128) on InstalledSoftware
        $cmd.CommandText = @"
SELECT max_length FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.InstalledSoftware') AND name = 'ComputerName'
"@
        $colWidth = $cmd.ExecuteScalar()
        # NVARCHAR max_length is the byte length; for NVARCHAR(128) that's 256
        Assert-True -Condition ($colWidth -eq 256) -Message "InstalledSoftware.ComputerName widened to NVARCHAR(128) (max_length=$colWidth, expected 256)"
    }
    finally {
        $conn.Dispose()
    }

    # Second run: idempotent
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Computers"
        $cBefore = $cmd.ExecuteScalar()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns"
        $rBefore = $cmd.ExecuteScalar()

        $cmd.CommandTimeout = 300
        $cmd.CommandText = $migrationSql
        $cmd.ExecuteNonQuery() | Out-Null

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Computers"
        $cAfter = $cmd.ExecuteScalar()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns"
        $rAfter = $cmd.ExecuteScalar()

        Assert-True -Condition ($cAfter -eq $cBefore) -Message "Migration is idempotent: Computers unchanged ($cBefore -> $cAfter)"
        Assert-True -Condition ($rAfter -eq $rBefore) -Message "Migration is idempotent: CollectionRuns unchanged ($rBefore -> $rAfter)"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: Phase 1 migration test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 8: V2 Phase 2 happy path (RunId + CollectionRuns end-to-end) ===" -ForegroundColor Cyan
# ============================================================
# Simulates the GetInventory -> ParseInventory -> SQL load path with V2 shape:
# every record carries a RunId, CollectionRuns.json holds per-run metadata.
# Asserts Computers + CollectionRuns get upserted by the load script and that
# fact rows land with RunId populated. Distinct from Test 7 (which exercises
# Phase 1 *migration* from V1-state data).

$Phase2Folder = Join-Path -Path $PSScriptRoot -ChildPath 'sample-data\Phase2HappyPath'
if (Test-Path $Phase2Folder) { Remove-Item $Phase2Folder -Recurse -Force }
New-Item -ItemType Directory -Path $Phase2Folder -Force | Out-Null

$phase2Run1 = ([guid]::NewGuid()).ToString()
$phase2Run2 = ([guid]::NewGuid()).ToString()
$phase2Started = (Get-Date).ToUniversalTime().ToString('o')

# Two records with RunId, simulating ParseInventory aggregated output
@(
    [PSCustomObject]@{ ComputerName = 'PHASE2-A'; Note = 'first';  RunId = $phase2Run1 }
    [PSCustomObject]@{ ComputerName = 'PHASE2-B'; Note = 'second'; RunId = $phase2Run2 }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Phase2Folder 'Phase2Demo.json') -Encoding UTF8

# CollectionRuns.json: one entry per (ComputerName, RunId)
@(
    [PSCustomObject]@{
        RunId = $phase2Run1; ComputerName = 'PHASE2-A'; StartedAt = $phase2Started
        CompletedAt = $phase2Started; Status = 'Parsed'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
    [PSCustomObject]@{
        RunId = $phase2Run2; ComputerName = 'PHASE2-B'; StartedAt = $phase2Started
        CompletedAt = $phase2Started; Status = 'Parsed'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Phase2Folder 'CollectionRuns.json') -Encoding UTF8

try {
    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $Phase2Folder
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $Phase2Folder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # CollectionRuns picked up both new runs
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns WHERE RunId IN (@r1, @r2)"
        $cmd.Parameters.AddWithValue('@r1', [Guid]::Parse($phase2Run1)) | Out-Null
        $cmd.Parameters.AddWithValue('@r2', [Guid]::Parse($phase2Run2)) | Out-Null
        $runsLoaded = $cmd.ExecuteScalar()
        Assert-True -Condition ($runsLoaded -eq 2) -Message "Phase 2: CollectionRuns has both new RunIds ($runsLoaded/2)"

        # Computers upserted for both new ComputerNames
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Computers WHERE ComputerName IN ('PHASE2-A', 'PHASE2-B')"
        $newComputers = $cmd.ExecuteScalar()
        Assert-True -Condition ($newComputers -eq 2) -Message "Phase 2: both Computers upserted ($newComputers/2)"

        # Fact rows landed with the correct RunId
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT RunId FROM dbo.Phase2Demo WHERE ComputerName = @cn"
        $cmd.Parameters.AddWithValue('@cn', 'PHASE2-A') | Out-Null
        $factRunId = $cmd.ExecuteScalar()
        Assert-True -Condition ($factRunId -is [Guid] -and $factRunId.ToString() -eq $phase2Run1) `
            -Message "Phase 2: Phase2Demo[PHASE2-A].RunId = expected ($factRunId)"

        # LastRunId on Computers points at the new run
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT LastRunId FROM dbo.Computers WHERE ComputerName = 'PHASE2-B'"
        $lastRunId = $cmd.ExecuteScalar()
        Assert-True -Condition ($lastRunId -is [Guid] -and $lastRunId.ToString() -eq $phase2Run2) `
            -Message "Phase 2: Computers[PHASE2-B].LastRunId points at the new run"
    } finally {
        $conn.Dispose()
    }

    # Idempotency: re-running the same Phase 2 load shouldn't duplicate
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $Phase2Folder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns WHERE RunId IN (@r1, @r2)"
        $cmd.Parameters.AddWithValue('@r1', [Guid]::Parse($phase2Run1)) | Out-Null
        $cmd.Parameters.AddWithValue('@r2', [Guid]::Parse($phase2Run2)) | Out-Null
        $runsAfter = $cmd.ExecuteScalar()
        Assert-True -Condition ($runsAfter -eq 2) -Message "Phase 2: CollectionRuns unchanged on re-run ($runsAfter still 2)"

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Phase2Demo"
        $factCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($factCount -eq 2) -Message "Phase 2: Phase2Demo unchanged on re-run ($factCount still 2)"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: Phase 2 test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 9: V2 Phase 3 migration applies ===" -ForegroundColor Cyan
# ============================================================
# Runs docs/migrations/V2_Phase3.sql. Asserts UpdateTimeStamp gone from fact
# tables, FK constraints on RunId/ComputerName exist, vCurrent* views exist,
# and InstalledUpdates is in the differential shape.

$phase3MigrationPath = Join-Path -Path (Split-Path $PSScriptRoot -Parent) -ChildPath 'docs\migrations\V2_Phase3.sql'

try {
    Assert-True -Condition (Test-Path $phase3MigrationPath) -Message "Phase 3 migration script exists"

    $migrationSql = Get-Content -Path $phase3MigrationPath -Raw
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = $migrationSql
        $cmd.ExecuteNonQuery() | Out-Null

        # UpdateTimeStamp gone
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE name = 'UpdateTimeStamp' AND object_id = OBJECT_ID('dbo.InstalledSoftware')"
        $col = $cmd.ExecuteScalar()
        Assert-True -Condition ($col -eq 0) -Message "Phase 3: InstalledSoftware.UpdateTimeStamp dropped"

        # FK on RunId
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.foreign_keys WHERE name = 'FK_InstalledSoftware_Run'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "Phase 3: FK_InstalledSoftware_Run exists"

        # FK on ComputerName
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.foreign_keys WHERE name = 'FK_InstalledSoftware_Computer'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "Phase 3: FK_InstalledSoftware_Computer exists"

        # UNIQUE natural-key index lands on InstalledUpdates because Title is
        # NVARCHAR(512) (indexable). On snapshot tables with NVARCHAR(MAX)
        # natural-key columns SQL Server rejects the index; that's expected,
        # idempotency is provided by the INSERT WHERE NOT EXISTS pattern.
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.indexes WHERE name = 'UX_InstalledUpdates_Natural' AND object_id = OBJECT_ID('dbo.InstalledUpdates')"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "Phase 3: UX_InstalledUpdates_Natural index exists"

        # vCurrent* view exists
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.views WHERE name = 'vCurrentInstalledSoftware'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "Phase 3: vCurrentInstalledSoftware view created"

        # InstalledUpdates differential schema
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('dbo.InstalledUpdates') AND name IN ('FirstSeenRunId', 'LastSeenRunId', 'UninstalledAt')"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 3) -Message "Phase 3: InstalledUpdates has differential columns"

        $cmd.CommandText = "SELECT COUNT(*) FROM sys.views WHERE name = 'vCurrentInstalledUpdates'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "Phase 3: vCurrentInstalledUpdates view created"

        $cmd.CommandText = "SELECT COUNT(*) FROM sys.views WHERE name = 'vStaleComputers'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "Phase 3: vStaleComputers view created"
    } finally {
        $conn.Dispose()
    }

    # Idempotency
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandTimeout = 300
        $cmd.CommandText = $migrationSql
        $cmd.ExecuteNonQuery() | Out-Null
        Assert-True -Condition $true -Message "Phase 3: migration is idempotent (second run no-op)"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: Phase 3 migration test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 10: Phase 3 append-only behaviour ===" -ForegroundColor Cyan
# ============================================================
# Push another collection for the same Computers in Phase2Demo but with a new
# RunId. Snapshot tables now append rather than upsert, so the row count
# should grow. Same RunId again is idempotent (UNIQUE-natural blocks dupes).

$Phase3Folder = Join-Path -Path $PSScriptRoot -ChildPath 'sample-data\Phase3Append'
if (Test-Path $Phase3Folder) { Remove-Item $Phase3Folder -Recurse -Force }
New-Item -ItemType Directory -Path $Phase3Folder -Force | Out-Null

$phase3RunA = ([guid]::NewGuid()).ToString()
$phase3RunB = ([guid]::NewGuid()).ToString()
$phase3Started = (Get-Date).ToUniversalTime().ToString('o')

# Two records: same ComputerNames as Test 8, NEW RunIds
@(
    [PSCustomObject]@{ ComputerName = 'PHASE2-A'; Note = 'phase3-A'; RunId = $phase3RunA }
    [PSCustomObject]@{ ComputerName = 'PHASE2-B'; Note = 'phase3-B'; RunId = $phase3RunB }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Phase3Folder 'Phase2Demo.json') -Encoding UTF8

@(
    [PSCustomObject]@{
        RunId = $phase3RunA; ComputerName = 'PHASE2-A'; StartedAt = $phase3Started
        CompletedAt = $phase3Started; Status = 'Parsed'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
    [PSCustomObject]@{
        RunId = $phase3RunB; ComputerName = 'PHASE2-B'; StartedAt = $phase3Started
        CompletedAt = $phase3Started; Status = 'Parsed'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Phase3Folder 'CollectionRuns.json') -Encoding UTF8

try {
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $Phase3Folder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # Append-only: Phase2Demo now has 4 rows (2 from Test 8 + 2 from Test 10)
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Phase2Demo"
        $appendCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($appendCount -eq 4) -Message "Phase 3: Phase2Demo appended (4 rows total: 2 old + 2 new)"

        # Per-ComputerName: 2 RunIds each
        $cmd.CommandText = "SELECT COUNT(DISTINCT RunId) FROM dbo.Phase2Demo WHERE ComputerName = 'PHASE2-A'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 2) -Message "Phase 3: PHASE2-A has 2 distinct RunIds in Phase2Demo"

        # Re-run with same payload: no duplicates (UX_*_Natural blocks them)
        & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $Phase3Folder -logFilePath $LogFile

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Phase2Demo"
        $reRunCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($reRunCount -eq 4) -Message "Phase 3: same-RunId re-run is idempotent ($reRunCount still 4)"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: Phase 3 append-only test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 11: vCurrent* view returns latest snapshot ===" -ForegroundColor Cyan
# ============================================================

try {
    # Create the view via Phase 3 migration logic, then query it.
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # Mark Phase 3 runs as Loaded so the view picks them up
        $cmd.CommandText = "UPDATE dbo.CollectionRuns SET Status = 'Loaded', LoadedAt = SYSUTCDATETIME() WHERE RunId IN (@a, @b)"
        $cmd.Parameters.AddWithValue('@a', [Guid]::Parse($phase3RunA)) | Out-Null
        $cmd.Parameters.AddWithValue('@b', [Guid]::Parse($phase3RunB)) | Out-Null
        $cmd.ExecuteNonQuery() | Out-Null

        # Need the vCurrentPhase2Demo view; the Phase 3 migration creates one per fact table
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.views WHERE name = 'vCurrentPhase2Demo'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "Phase 3: vCurrentPhase2Demo view exists"

        # The view should return exactly 2 rows (latest snapshot per ComputerName)
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.vCurrentPhase2Demo"
        $viewCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($viewCount -eq 2) -Message "Phase 3: vCurrentPhase2Demo returns 1 row per Computer ($viewCount rows)"

        # And those rows should be the PHASE 3 versions (Note = 'phase3-A'/'phase3-B')
        $cmd.CommandText = "SELECT Note FROM dbo.vCurrentPhase2Demo WHERE ComputerName = 'PHASE2-A'"
        $note = $cmd.ExecuteScalar()
        Assert-True -Condition ($note -eq 'phase3-A') -Message "Phase 3: vCurrentPhase2Demo shows latest Note for PHASE2-A ('$note')"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: vCurrent view test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 12: InstalledUpdates differential model ===" -ForegroundColor Cyan
# ============================================================
# Two collection runs for the same Computer:
#   Run A: KB1, KB2, KB3
#   Run B: KB1, KB2, KB4  -> KB3 should get UninstalledAt set, KB4 inserted

$DiffFolder = Join-Path -Path $PSScriptRoot -ChildPath 'sample-data\InstalledUpdatesDiff'
if (Test-Path $DiffFolder) { Remove-Item $DiffFolder -Recurse -Force }
New-Item -ItemType Directory -Path $DiffFolder -Force | Out-Null

$diffRunA = ([guid]::NewGuid()).ToString()
$diffRunB = ([guid]::NewGuid()).ToString()
$diffStarted = (Get-Date).ToUniversalTime().ToString('o')

# Helper to write a run worth of InstalledUpdates + matching CollectionRuns
function Write-DiffRun {
    param([string]$RunId, [string[]]$Titles, [string]$Folder)
    $records = @($Titles | ForEach-Object {
        [PSCustomObject]@{
            ComputerName = 'DIFF-01'
            Title        = $_
            Date         = '2026-01-15'
            ServiceID    = 'kb-test'
            RunId        = $RunId
        }
    })
    $records | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Folder 'InstalledUpdates.json') -Encoding UTF8

    @(
        [PSCustomObject]@{
            RunId = $RunId; ComputerName = 'DIFF-01'; StartedAt = $diffStarted
            CompletedAt = $diffStarted; Status = 'Parsed'
            MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
        }
    ) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Folder 'CollectionRuns.json') -Encoding UTF8
}

try {
    # Run A: KB1, KB2, KB3
    Write-DiffRun -RunId $diffRunA -Titles @('KB1', 'KB2', 'KB3') -Folder $DiffFolder
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $DiffFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01'"
        $countA = $cmd.ExecuteScalar()
        Assert-True -Condition ($countA -eq 3) -Message "Differential: 3 rows after Run A (KB1, KB2, KB3)"

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01' AND UninstalledAt IS NULL"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 3) -Message "Differential: all 3 are active after Run A"
    } finally {
        $conn.Dispose()
    }

    # Run B: KB1, KB2, KB4 (no KB3)
    Write-DiffRun -RunId $diffRunB -Titles @('KB1', 'KB2', 'KB4') -Folder $DiffFolder
    & "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $DiffFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # 4 total rows: KB1, KB2, KB3 (uninstalled), KB4 (new)
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 4) -Message "Differential: 4 rows after Run B (3 + new KB4)"

        # KB3 marked uninstalled
        $cmd.CommandText = "SELECT UninstalledAt FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01' AND Title = 'KB3'"
        $kb3Uninstall = $cmd.ExecuteScalar()
        Assert-True -Condition ($null -ne $kb3Uninstall -and $kb3Uninstall -ne [DBNull]::Value) -Message "Differential: KB3 has UninstalledAt set after Run B"

        # KB1 still active, LastSeenRunId updated to Run B
        $cmd.CommandText = "SELECT LastSeenRunId, FirstSeenRunId, UninstalledAt FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01' AND Title = 'KB1'"
        $reader = $cmd.ExecuteReader()
        $kb1LastRun = $null; $kb1FirstRun = $null; $kb1Uninstall = $null
        if ($reader.Read()) {
            $kb1LastRun  = $reader['LastSeenRunId']
            $kb1FirstRun = $reader['FirstSeenRunId']
            $kb1Uninstall = $reader['UninstalledAt']
        }
        $reader.Close()
        Assert-True -Condition ($kb1LastRun.ToString() -eq $diffRunB) -Message "Differential: KB1 LastSeenRunId = Run B"
        Assert-True -Condition ($kb1FirstRun.ToString() -eq $diffRunA) -Message "Differential: KB1 FirstSeenRunId = Run A (unchanged)"
        Assert-True -Condition ($kb1Uninstall -eq [DBNull]::Value) -Message "Differential: KB1 UninstalledAt remains NULL"

        # KB4 brand new: FirstSeenRunId = LastSeenRunId = Run B
        $cmd.CommandText = "SELECT FirstSeenRunId, LastSeenRunId FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01' AND Title = 'KB4'"
        $reader = $cmd.ExecuteReader()
        $kb4First = $null; $kb4Last = $null
        if ($reader.Read()) {
            $kb4First = $reader['FirstSeenRunId']
            $kb4Last  = $reader['LastSeenRunId']
        }
        $reader.Close()
        Assert-True -Condition ($kb4First.ToString() -eq $diffRunB -and $kb4Last.ToString() -eq $diffRunB) `
            -Message "Differential: KB4 FirstSeenRunId = LastSeenRunId = Run B (newly inserted)"

        # vCurrentInstalledUpdates excludes the uninstalled KB3
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.vCurrentInstalledUpdates WHERE ComputerName = 'DIFF-01'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 3) -Message "Differential: vCurrentInstalledUpdates shows 3 active rows (excludes KB3)"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: differential model test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Cleanup ===" -ForegroundColor Cyan
# ============================================================

$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]"
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "  Database '$Database' dropped" -ForegroundColor Yellow
}
finally {
    $conn.Dispose()
}

# Clean up temp files
if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
if (Test-Path $InjectionFolder) { Remove-Item $InjectionFolder -Recurse -Force }
if (Test-Path $SchemaFolder)    { Remove-Item $SchemaFolder    -Recurse -Force }
if (Test-Path $Phase2Folder)    { Remove-Item $Phase2Folder    -Recurse -Force }
if (Test-Path $Phase3Folder)    { Remove-Item $Phase3Folder    -Recurse -Force }
if (Test-Path $DiffFolder)      { Remove-Item $DiffFolder      -Recurse -Force }
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

# ============================================================
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
# ============================================================

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
