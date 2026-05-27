# Test-Integration-LocalDB.ps1
# End-to-end integration test using SQL Server LocalDB.
# Validates that CreateSQLTableFromJSON.ps1 produces the full schema on a
# fresh install in one step and UpdateSQLTableFromJSON.ps1 loads data into it
# correctly.

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
# The committed fixture has no RunId or CollectionRuns.json, so we trim rows,
# stamp each record with a per-Computer RunId, and build a CollectionRuns.json
# so the fixture mirrors what GetInventory + ParseInventory emit.

if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
New-Item -ItemType Directory -Path $TrimmedDataPath -Force | Out-Null

$fixtureComputers = New-Object System.Collections.Generic.HashSet[string]
$trimmedFiles = @()

Get-ChildItem -Path $SampleDataPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $SkipFiles -and
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -ne 'CollectionRuns'
} | ForEach-Object {
    $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
    if ($data -is [System.Array] -and $data.Count -gt $MaxRowsPerFile) {
        $trimmed = $data[0..($MaxRowsPerFile - 1)]
    } else {
        $trimmed = $data
    }
    if (-not ($trimmed -is [System.Array])) { $trimmed = @($trimmed) }
    foreach ($row in $trimmed) {
        if ($null -ne $row -and $row.ComputerName) {
            [void]$fixtureComputers.Add([string]$row.ComputerName)
        }
    }
    $outPath = Join-Path $TrimmedDataPath $_.Name
    $trimmedFiles += [PSCustomObject]@{ Path = $outPath; Data = $trimmed }
    Write-Host "  $($_.Name): $($trimmed.Count) rows"
}

# One RunId per ComputerName - mirrors real pipeline (one collection per host).
$fixtureRunIds = @{}
foreach ($cn in $fixtureComputers) {
    $fixtureRunIds[$cn] = ([guid]::NewGuid()).ToString()
}
$fixtureStartedAt = (Get-Date).ToUniversalTime().ToString('o')

# Stamp RunId on every record and write the trimmed file.
foreach ($file in $trimmedFiles) {
    foreach ($row in $file.Data) {
        if ($null -eq $row -or -not $row.ComputerName) { continue }
        $rid = $fixtureRunIds[[string]$row.ComputerName]
        if (-not $rid) { continue }
        if ($row.PSObject.Properties.Name -notcontains 'RunId') {
            $row | Add-Member -NotePropertyName 'RunId' -NotePropertyValue $rid -Force
        } else {
            $row.RunId = $rid
        }
    }
    $file.Data | ConvertTo-Json -Depth 10 | Out-File $file.Path -Encoding UTF8
}

# CollectionRuns.json - one entry per Computer/RunId, Status='Loaded' so the
# vCurrent* views pick the rows up in Test 11-equivalent checks.
$runs = foreach ($cn in $fixtureComputers) {
    [PSCustomObject]@{
        RunId            = $fixtureRunIds[$cn]
        ComputerName     = $cn
        StartedAt        = $fixtureStartedAt
        CompletedAt      = $fixtureStartedAt
        Status           = 'Loaded'
        MetricsSucceeded = 1
        MetricsFailed    = 0
        FailedMetrics    = ''
    }
}
$runs | ConvertTo-Json -Depth 5 | Out-File (Join-Path $TrimmedDataPath 'CollectionRuns.json') -Encoding UTF8
Write-Host "  CollectionRuns.json: $($fixtureComputers.Count) run(s) (one per Computer)"

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
Write-Host "`n=== Test 1: CreateSQLTableFromJSON.ps1 produces full schema ===" -ForegroundColor Cyan
# ============================================================

try {
    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath
    Write-Host ""

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # Infrastructure tables exist
        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME IN ('Computers','CollectionRuns','InstalledUpdates')"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 3) -Message "Infrastructure: Computers + CollectionRuns + InstalledUpdates all exist"

        # Cross-table views exist
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.views WHERE name IN ('vCurrentInstalledUpdates','vStaleComputers')"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 2) -Message "Infrastructure: vCurrentInstalledUpdates + vStaleComputers views exist"

        # Fact tables created from JSON
        $cmd.CommandText = "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME"
        $reader = $cmd.ExecuteReader()
        $tables = @()
        while ($reader.Read()) { $tables += $reader["TABLE_NAME"] }
        $reader.Close()

        $expectedFactTables = (Get-ChildItem -Path $TrimmedDataPath -Filter "*.json" | ForEach-Object {
            [IO.Path]::GetFileNameWithoutExtension($_.Name)
        } | Where-Object { $_ -ne 'CollectionRuns' })

        foreach ($expected in $expectedFactTables) {
            Assert-True -Condition ($tables -contains $expected) -Message "Table '$expected' exists"
        }

        # Fact-table shape: ComputerName, RunId, CreatedAt present
        $cmd.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @TableName"
        $cmd.Parameters.AddWithValue("@TableName", "InstalledSoftware") | Out-Null
        $reader = $cmd.ExecuteReader()
        $columns = @()
        while ($reader.Read()) { $columns += $reader["COLUMN_NAME"] }
        $reader.Close()

        Assert-True -Condition ($columns -contains "ComputerName") -Message "InstalledSoftware has ComputerName column"
        Assert-True -Condition ($columns -contains "DisplayName") -Message "InstalledSoftware has DisplayName column"
        Assert-True -Condition ($columns -contains "Id") -Message "InstalledSoftware has Id column (auto-added)"
        Assert-True -Condition ($columns -contains "RunId") -Message "InstalledSoftware has RunId column"
        Assert-True -Condition ($columns -contains "CreatedAt") -Message "InstalledSoftware has CreatedAt column"

        # FK constraints exist
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.foreign_keys WHERE name = 'FK_InstalledSoftware_Run'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "FK_InstalledSoftware_Run created inline"
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.foreign_keys WHERE name = 'FK_InstalledSoftware_Computer'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "FK_InstalledSoftware_Computer created inline"

        # vCurrent<TableName> view created inline
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.views WHERE name = 'vCurrentInstalledSoftware'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "vCurrentInstalledSoftware view created inline by Create script"

        # InstalledUpdates differential shape
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID('dbo.InstalledUpdates') AND name IN ('FirstSeenRunId','LastSeenRunId','UninstalledAt')"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 3) -Message "InstalledUpdates has differential columns (FirstSeenRunId/LastSeenRunId/UninstalledAt)"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: CreateSQLTableFromJSON threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 2: UpdateSQLTableFromJSON.ps1 (INSERT) ===" -ForegroundColor Cyan
# ============================================================

try {
    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath -logFilePath $LogFile
    Write-Host ""

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

        # Computers + CollectionRuns populated by Import-CollectionRunsJson
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Computers"
        $computersCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($computersCount -ge $fixtureComputers.Count) -Message "Computers populated by Update script ($computersCount rows, fixture had $($fixtureComputers.Count) distinct ComputerNames)"

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns"
        $runsCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($runsCount -ge $fixtureComputers.Count) -Message "CollectionRuns populated by Update script ($runsCount rows)"

        # Verify special characters survive round-trip
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT TOP 1 [SharePath] FROM [ShareAccessInfo] WHERE [SharePath] LIKE '%\%'"
        $path = $cmd.ExecuteScalar()
        Assert-True -Condition ($null -ne $path -and $path -is [string] -and $path -match '\\') `
            -Message "ShareAccessInfo has at least one row whose SharePath contains a backslash: $path"

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT TOP 1 [Members] FROM [GroupMembers] WHERE [Members] IS NOT NULL AND LEN([Members]) > 0"
        $value = $cmd.ExecuteScalar()
        Assert-True -Condition ($null -ne $value -and $value -ne [DBNull]::Value -and $value -is [string] -and $value.Length -gt 0) `
            -Message "GroupMembers.Members stored as non-empty string for at least one row (length: $(if ($value -is [string]) { $value.Length } else { 'n/a' }))"

        # Every fact row has a non-NULL RunId (schema enforces NOT NULL)
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM [InstalledSoftware] WHERE RunId IS NULL"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 0) -Message "Every InstalledSoftware row has RunId (NOT NULL)"
    }
    finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: UpdateSQLTableFromJSON (INSERT) threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 3: UpdateSQLTableFromJSON.ps1 (idempotent re-run) ===" -ForegroundColor Cyan
# ============================================================
# Same RunId on every record - INSERT WHERE NOT EXISTS via the natural key
# blocks duplication.

try {
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

    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath -logFilePath $LogFile
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
    Write-Host "  FAIL: UpdateSQLTableFromJSON (re-run) threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 4: SQL injection value is safely stored ===" -ForegroundColor Cyan
# ============================================================
# Direct parameterized insert. With FKs we need an existing Computer +
# CollectionRun to reference - use the first one from the fixture.

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT TOP 1 ComputerName FROM dbo.Computers"
        $cn = [string]$cmd.ExecuteScalar()
        $cmd.CommandText = "SELECT TOP 1 RunId FROM dbo.CollectionRuns WHERE ComputerName = @cn"
        $cmd.Parameters.AddWithValue('@cn', $cn) | Out-Null
        $rid = $cmd.ExecuteScalar()
        $cmd.Parameters.Clear()

        $injectionPayload = "O'Brien'; DROP TABLE InstalledSoftware;--"
        $cmd.CommandText = "INSERT INTO [InstalledSoftware] ([ComputerName], [DisplayName], [DisplayVersion], [InstallDate], [Publisher], [RunId]) VALUES (@p0, @p1, @p2, @p3, @p4, @p5)"
        $cmd.Parameters.AddWithValue("@p0", $cn) | Out-Null
        $cmd.Parameters.AddWithValue("@p1", $injectionPayload) | Out-Null
        $cmd.Parameters.AddWithValue("@p2", "1.0") | Out-Null
        $cmd.Parameters.AddWithValue("@p3", [DBNull]::Value) | Out-Null
        $cmd.Parameters.AddWithValue("@p4", "Evil Corp") | Out-Null
        $cmd.Parameters.AddWithValue("@p5", $rid) | Out-Null
        $cmd.ExecuteNonQuery() | Out-Null

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'InstalledSoftware'"
        Assert-True -Condition ($cmd.ExecuteScalar() -gt 0) -Message "InstalledSoftware table still exists after injection attempt"

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT [DisplayName] FROM [InstalledSoftware] WHERE [DisplayName] = @dn"
        $cmd.Parameters.AddWithValue("@dn", $injectionPayload) | Out-Null
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
# Test 4 proved AddWithValue is injection-safe. Test 5 proves the REAL
# production path through Add-ParameterizedValues + the Update script is also
# safe - so a regression that bypasses the helpers gets caught.

$InjectionFolder = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\InjectionTest"
if (Test-Path $InjectionFolder) { Remove-Item $InjectionFolder -Recurse -Force }
New-Item -ItemType Directory -Path $InjectionFolder -Force | Out-Null

$payload = "O'Brien'; DROP TABLE InjectionE2E;--"
$injectRunId = ([guid]::NewGuid()).ToString()
$injectStartedAt = (Get-Date).ToUniversalTime().ToString('o')

@(
    [PSCustomObject]@{ ComputerName = "INJECT-01"; Note = $payload; RunId = $injectRunId }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $InjectionFolder "InjectionE2E.json") -Encoding UTF8

@(
    [PSCustomObject]@{
        RunId = $injectRunId; ComputerName = 'INJECT-01'; StartedAt = $injectStartedAt
        CompletedAt = $injectStartedAt; Status = 'Loaded'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $InjectionFolder 'CollectionRuns.json') -Encoding UTF8

try {
    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $InjectionFolder
    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $InjectionFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'InjectionE2E'"
        Assert-True -Condition ($cmd.ExecuteScalar() -gt 0) -Message "InjectionE2E table still exists after script ran with injection payload"

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
# Run CreateSQLTableFromJSON twice against the same table name with the
# second JSON containing an extra property. The script's "table exists - add
# missing columns" branch should ALTER TABLE rather than CREATE TABLE.

$SchemaFolder = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\SchemaEvolutionTest"
if (Test-Path $SchemaFolder) { Remove-Item $SchemaFolder -Recurse -Force }
New-Item -ItemType Directory -Path $SchemaFolder -Force | Out-Null

$schemaRun1 = ([guid]::NewGuid()).ToString()
$schemaRun2 = ([guid]::NewGuid()).ToString()
$schemaStartedAt = (Get-Date).ToUniversalTime().ToString('o')

# Initial schema: 2 columns + RunId + CreatedAt
@(
    [PSCustomObject]@{ ComputerName = "SCHEMA-01"; OriginalCol = "v1"; RunId = $schemaRun1 }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $SchemaFolder "SchemaEvolution.json") -Encoding UTF8

@(
    [PSCustomObject]@{
        RunId = $schemaRun1; ComputerName = 'SCHEMA-01'; StartedAt = $schemaStartedAt
        CompletedAt = $schemaStartedAt; Status = 'Loaded'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $SchemaFolder 'CollectionRuns.json') -Encoding UTF8

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

    # Rewrite JSON with one extra column + a new RunId
    @(
        [PSCustomObject]@{ ComputerName = "SCHEMA-02"; OriginalCol = "v2"; AddedCol = "new!"; RunId = $schemaRun2 }
    ) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $SchemaFolder "SchemaEvolution.json") -Encoding UTF8

    @(
        [PSCustomObject]@{
            RunId = $schemaRun2; ComputerName = 'SCHEMA-02'; StartedAt = $schemaStartedAt
            CompletedAt = $schemaStartedAt; Status = 'Loaded'
            MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
        }
    ) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $SchemaFolder 'CollectionRuns.json') -Encoding UTF8

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
        & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $SchemaFolder -logFilePath $LogFile

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
Write-Host "`n=== Test 7: Fresh-Computer end-to-end load ===" -ForegroundColor Cyan
# ============================================================
# Simulates GetInventory -> ParseInventory -> SQL load for a fresh Computer:
# every record carries a RunId, CollectionRuns.json holds per-run metadata.
# Asserts Computers + CollectionRuns get upserted and fact rows land with
# RunId populated.

$FreshLoadFolder = Join-Path -Path $PSScriptRoot -ChildPath 'sample-data\FreshLoad'
if (Test-Path $FreshLoadFolder) { Remove-Item $FreshLoadFolder -Recurse -Force }
New-Item -ItemType Directory -Path $FreshLoadFolder -Force | Out-Null

$freshRun1 = ([guid]::NewGuid()).ToString()
$freshRun2 = ([guid]::NewGuid()).ToString()
$freshStarted = (Get-Date).ToUniversalTime().ToString('o')

@(
    [PSCustomObject]@{ ComputerName = 'FRESH-A'; Note = 'first';  RunId = $freshRun1 }
    [PSCustomObject]@{ ComputerName = 'FRESH-B'; Note = 'second'; RunId = $freshRun2 }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $FreshLoadFolder 'FreshLoadDemo.json') -Encoding UTF8

@(
    [PSCustomObject]@{
        RunId = $freshRun1; ComputerName = 'FRESH-A'; StartedAt = $freshStarted
        CompletedAt = $freshStarted; Status = 'Loaded'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
    [PSCustomObject]@{
        RunId = $freshRun2; ComputerName = 'FRESH-B'; StartedAt = $freshStarted
        CompletedAt = $freshStarted; Status = 'Loaded'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $FreshLoadFolder 'CollectionRuns.json') -Encoding UTF8

try {
    & "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $FreshLoadFolder
    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $FreshLoadFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns WHERE RunId IN (@r1, @r2)"
        $cmd.Parameters.AddWithValue('@r1', [Guid]::Parse($freshRun1)) | Out-Null
        $cmd.Parameters.AddWithValue('@r2', [Guid]::Parse($freshRun2)) | Out-Null
        $runsLoaded = $cmd.ExecuteScalar()
        Assert-True -Condition ($runsLoaded -eq 2) -Message "Fresh load: CollectionRuns has both new RunIds ($runsLoaded/2)"

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.Computers WHERE ComputerName IN ('FRESH-A', 'FRESH-B')"
        $newComputers = $cmd.ExecuteScalar()
        Assert-True -Condition ($newComputers -eq 2) -Message "Fresh load: both Computers upserted ($newComputers/2)"

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT RunId FROM dbo.FreshLoadDemo WHERE ComputerName = @cn"
        $cmd.Parameters.AddWithValue('@cn', 'FRESH-A') | Out-Null
        $factRunId = $cmd.ExecuteScalar()
        Assert-True -Condition ($factRunId -is [Guid] -and $factRunId.ToString() -eq $freshRun1) `
            -Message "Fresh load: FreshLoadDemo[FRESH-A].RunId = expected ($factRunId)"

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT LastRunId FROM dbo.Computers WHERE ComputerName = 'FRESH-B'"
        $lastRunId = $cmd.ExecuteScalar()
        Assert-True -Condition ($lastRunId -is [Guid] -and $lastRunId.ToString() -eq $freshRun2) `
            -Message "Fresh load: Computers[FRESH-B].LastRunId points at the new run"
    } finally {
        $conn.Dispose()
    }

    # Idempotency: re-running the same load doesn't duplicate
    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $FreshLoadFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.CollectionRuns WHERE RunId IN (@r1, @r2)"
        $cmd.Parameters.AddWithValue('@r1', [Guid]::Parse($freshRun1)) | Out-Null
        $cmd.Parameters.AddWithValue('@r2', [Guid]::Parse($freshRun2)) | Out-Null
        $runsAfter = $cmd.ExecuteScalar()
        Assert-True -Condition ($runsAfter -eq 2) -Message "Fresh load: CollectionRuns unchanged on re-run ($runsAfter still 2)"

        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.FreshLoadDemo"
        $factCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($factCount -eq 2) -Message "Fresh load: FreshLoadDemo unchanged on re-run ($factCount still 2)"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: Fresh load test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 8: Append-only behaviour (snapshot grows with new RunId) ===" -ForegroundColor Cyan
# ============================================================
# Push another collection for the same Computers as Test 7 but with a NEW
# RunId. Snapshot tables append rather than upsert, so the row count grows.
# Same RunId again is idempotent (INSERT WHERE NOT EXISTS blocks dupes).

$AppendOnlyFolder = Join-Path -Path $PSScriptRoot -ChildPath 'sample-data\AppendOnly'
if (Test-Path $AppendOnlyFolder) { Remove-Item $AppendOnlyFolder -Recurse -Force }
New-Item -ItemType Directory -Path $AppendOnlyFolder -Force | Out-Null

$appendRunA = ([guid]::NewGuid()).ToString()
$appendRunB = ([guid]::NewGuid()).ToString()
$appendStarted = (Get-Date).ToUniversalTime().ToString('o')

@(
    [PSCustomObject]@{ ComputerName = 'FRESH-A'; Note = 'updated-A'; RunId = $appendRunA }
    [PSCustomObject]@{ ComputerName = 'FRESH-B'; Note = 'updated-B'; RunId = $appendRunB }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $AppendOnlyFolder 'FreshLoadDemo.json') -Encoding UTF8

@(
    [PSCustomObject]@{
        RunId = $appendRunA; ComputerName = 'FRESH-A'; StartedAt = $appendStarted
        CompletedAt = $appendStarted; Status = 'Loaded'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
    [PSCustomObject]@{
        RunId = $appendRunB; ComputerName = 'FRESH-B'; StartedAt = $appendStarted
        CompletedAt = $appendStarted; Status = 'Loaded'
        MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
    }
) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $AppendOnlyFolder 'CollectionRuns.json') -Encoding UTF8

try {
    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $AppendOnlyFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # 4 rows total: 2 from Test 7 + 2 from Test 8
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.FreshLoadDemo"
        $appendCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($appendCount -eq 4) -Message "Append-only: FreshLoadDemo grew (4 rows total: 2 old + 2 new)"

        $cmd.CommandText = "SELECT COUNT(DISTINCT RunId) FROM dbo.FreshLoadDemo WHERE ComputerName = 'FRESH-A'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 2) -Message "Append-only: FRESH-A has 2 distinct RunIds in FreshLoadDemo"

        # Same-RunId re-run: idempotent
        & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $AppendOnlyFolder -logFilePath $LogFile

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.FreshLoadDemo"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 4) -Message "Append-only: same-RunId re-run is idempotent (still 4)"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: Append-only test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 9: vCurrent* view returns latest snapshot ===" -ForegroundColor Cyan
# ============================================================

try {
    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        # vCurrentFreshLoadDemo was created inline when FreshLoadDemo table was created
        $cmd.CommandText = "SELECT COUNT(*) FROM sys.views WHERE name = 'vCurrentFreshLoadDemo'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 1) -Message "vCurrentFreshLoadDemo view exists (created inline by Create script)"

        # The view returns exactly 2 rows (latest snapshot per ComputerName)
        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.vCurrentFreshLoadDemo"
        $viewCount = $cmd.ExecuteScalar()
        Assert-True -Condition ($viewCount -eq 2) -Message "vCurrentFreshLoadDemo returns 1 row per Computer ($viewCount rows)"

        # Those rows are the second-run versions (latest)
        $cmd.CommandText = "SELECT Note FROM dbo.vCurrentFreshLoadDemo WHERE ComputerName = 'FRESH-A'"
        $note = $cmd.ExecuteScalar()
        Assert-True -Condition ($note -eq 'updated-A') -Message "vCurrentFreshLoadDemo shows latest Note for FRESH-A ('$note')"
    } finally {
        $conn.Dispose()
    }
} catch {
    Write-Host "  FAIL: vCurrent view test threw: $_" -ForegroundColor Red
    $script:TestsFailed++
}

# ============================================================
Write-Host "`n=== Test 10: InstalledUpdates differential model ===" -ForegroundColor Cyan
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
            CompletedAt = $diffStarted; Status = 'Loaded'
            MetricsSucceeded = 1; MetricsFailed = 0; FailedMetrics = ''
        }
    ) | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $Folder 'CollectionRuns.json') -Encoding UTF8
}

try {
    Write-DiffRun -RunId $diffRunA -Titles @('KB1', 'KB2', 'KB3') -Folder $DiffFolder
    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $DiffFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 3) -Message "Differential: 3 rows after Run A (KB1, KB2, KB3)"

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01' AND UninstalledAt IS NULL"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 3) -Message "Differential: all 3 are active after Run A"
    } finally {
        $conn.Dispose()
    }

    # Run B: KB1, KB2, KB4 (no KB3)
    Write-DiffRun -RunId $diffRunB -Titles @('KB1', 'KB2', 'KB4') -Folder $DiffFolder
    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $DiffFolder -logFilePath $LogFile

    $conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()

        $cmd.CommandText = "SELECT COUNT(*) FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01'"
        Assert-True -Condition ($cmd.ExecuteScalar() -eq 4) -Message "Differential: 4 rows after Run B (3 + new KB4)"

        $cmd.CommandText = "SELECT UninstalledAt FROM dbo.InstalledUpdates WHERE ComputerName = 'DIFF-01' AND Title = 'KB3'"
        $kb3Uninstall = $cmd.ExecuteScalar()
        Assert-True -Condition ($null -ne $kb3Uninstall -and $kb3Uninstall -ne [DBNull]::Value) -Message "Differential: KB3 has UninstalledAt set after Run B"

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

if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
if (Test-Path $InjectionFolder) { Remove-Item $InjectionFolder -Recurse -Force }
if (Test-Path $SchemaFolder)    { Remove-Item $SchemaFolder    -Recurse -Force }
if (Test-Path $FreshLoadFolder)    { Remove-Item $FreshLoadFolder    -Recurse -Force }
if (Test-Path $AppendOnlyFolder)    { Remove-Item $AppendOnlyFolder    -Recurse -Force }
if (Test-Path $DiffFolder)      { Remove-Item $DiffFolder      -Recurse -Force }
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

# ============================================================
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
# ============================================================

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
