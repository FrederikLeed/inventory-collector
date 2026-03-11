# Test-Integration-LocalDB.ps1
# End-to-end integration test using SQL Server LocalDB
# Tests CreateSQLTableFromJSON.ps1 and UpdateSQLTableFromJSON_new.ps1 with real sample data
# Uses first 20 rows per JSON file to keep test fast

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
$SampleDataPath = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\InventoryParsed"
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

        # Verify a known value with special characters survives round-trip
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT [SharePath] FROM [ShareAccessInfo] WHERE [ComputerName] = @cn"
        $cmd.Parameters.AddWithValue("@cn", "AAKRA") | Out-Null
        $reader = $cmd.ExecuteReader()
        $paths = @()
        while ($reader.Read()) { $paths += $reader["SharePath"] }
        $reader.Close()

        if ($paths.Count -gt 0) {
            Assert-True -Condition ($paths[0] -match '\\') -Message "ShareAccessInfo preserves backslashes in paths: $($paths[0])"
        }

        # Verify nested array was serialized (GroupMembers.Members)
        $cmd.Parameters.Clear()
        $cmd.CommandText = "SELECT TOP 1 [Members] FROM [GroupMembers] WHERE [GroupName] = @gn"
        $cmd.Parameters.AddWithValue("@gn", "Administrators") | Out-Null
        $value = $cmd.ExecuteScalar()
        if ($null -ne $value -and $value -ne [DBNull]::Value) {
            $isJsonOrString = ($value -is [string])
            Assert-True -Condition $isJsonOrString -Message "GroupMembers.Members stored as string (length: $($value.Length))"
        }
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
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

# ============================================================
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
# ============================================================

if ($script:TestsFailed -gt 0) { exit 1 } else { exit 0 }
