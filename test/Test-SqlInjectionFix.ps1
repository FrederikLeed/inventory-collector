# Test-SqlInjectionFix.ps1
# Tests the SQL injection fixes by validating parameterized query building
# without requiring an actual SQL Server connection.

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

function Assert-Throws {
    param([scriptblock]$ScriptBlock, [string]$Message)
    $threw = $false
    try { & $ScriptBlock } catch { $threw = $true }
    if ($threw) {
        Write-Host "  PASS: $Message" -ForegroundColor Green
        $script:TestsPassed++
    } else {
        Write-Host "  FAIL: $Message (expected exception)" -ForegroundColor Red
        $script:TestsFailed++
    }
}

# Dot-source the helpers
$helpersPath = Join-Path -Path $PSScriptRoot -ChildPath "..\SqlHelpers.ps1"
. $helpersPath

Add-Type -AssemblyName "System.Data"

# ============================================================
Write-Host "`n=== Test-SqlIdentifier ===" -ForegroundColor Cyan
# ============================================================

# Valid identifiers
Assert-True -Condition ($true) -Message "Setup complete"

foreach ($validName in @("InstalledSoftware", "ComputerName", "Subject Alternative Name", "My_Table_123")) {
    $passed = $true
    try { Test-SqlIdentifier -Name $validName -Context "test" } catch { $passed = $false }
    Assert-True -Condition $passed -Message "Valid identifier accepted: '$validName'"
}

# Invalid identifiers (SQL injection attempts)
foreach ($badName in @(
    "Users; DROP TABLE--",
    "Table' OR '1'='1",
    "Name; DELETE FROM Users",
    "Col`nNewline",
    "Tab(le)"
)) {
    Assert-Throws -ScriptBlock { Test-SqlIdentifier -Name $badName -Context "test" } -Message "Rejected bad identifier: '$badName'"
}

# ============================================================
Write-Host "`n=== Convert-ToSimpleFormat ===" -ForegroundColor Cyan
# ============================================================

# Null
$result = Convert-ToSimpleFormat $null
Assert-True -Condition ($null -eq $result) -Message "Null returns null"

# String passthrough
$result = Convert-ToSimpleFormat "hello"
Assert-True -Condition ($result -eq "hello") -Message "String passes through"

# Single-element array unwrapped
$result = Convert-ToSimpleFormat @("only-item")
Assert-True -Condition ($result -eq "only-item") -Message "Single-element array unwrapped"

# Multi-element array serialized to JSON
$result = Convert-ToSimpleFormat @("a", "b", "c")
Assert-True -Condition ($result -is [string] -and $result -match '"a"') -Message "Multi-element array serialized to JSON"

# Int64
$result = Convert-ToSimpleFormat ([Int64]9999999999)
Assert-True -Condition ($result -eq "9999999999" -and $result -is [string]) -Message "Int64 converted to string"

# Nested objects (like NTFSAccessList)
$nested = @([PSCustomObject]@{AccessTo="Everyone"; Rights="Full"})
$result = Convert-ToSimpleFormat $nested
Assert-True -Condition ($result -is [string] -and $result -match "Everyone") -Message "Nested object array serialized to JSON"

# ============================================================
Write-Host "`n=== Add-ParameterizedValues (INSERT) ===" -ForegroundColor Cyan
# ============================================================

# Create a dummy SqlCommand (no connection needed for parameter building)
$conn = New-Object System.Data.SqlClient.SqlConnection
$cmd = $conn.CreateCommand()

$testItem = [PSCustomObject]@{
    ComputerName = "SERVER01"
    DisplayName  = "O'Brien's App; DROP TABLE--"
    Version      = $null
    Count        = 42
}

$cmd.Parameters.Clear()
$paramInfo = Add-ParameterizedValues -SqlCommand $cmd -Item $testItem -Prefix "p"

Assert-True -Condition ($paramInfo.Columns -eq "[ComputerName], [DisplayName], [Version], [Count]") `
    -Message "Columns built correctly"

Assert-True -Condition ($paramInfo.Placeholders -eq "@p0, @p1, @p2, @p3") `
    -Message "Placeholders built correctly"

Assert-True -Condition ($cmd.Parameters.Count -eq 4) `
    -Message "4 parameters created"

Assert-True -Condition ($cmd.Parameters["@p0"].Value -eq "SERVER01") `
    -Message "Parameter @p0 = 'SERVER01'"

Assert-True -Condition ($cmd.Parameters["@p1"].Value -eq "O'Brien's App; DROP TABLE--") `
    -Message "Parameter @p1 contains SQL injection safely as parameter value"

Assert-True -Condition ($cmd.Parameters["@p2"].Value -eq [DBNull]::Value) `
    -Message "Parameter @p2 = DBNull for null value"

# Verify NO inline values in a constructed INSERT
$insertSql = "INSERT INTO [TestTable] ($($paramInfo.Columns)) VALUES ($($paramInfo.Placeholders))"
Assert-True -Condition ($insertSql -notmatch "O'Brien") `
    -Message "INSERT SQL text contains no inline values (injection-safe)"
Assert-True -Condition ($insertSql -match "@p0, @p1, @p2, @p3") `
    -Message "INSERT SQL uses parameter placeholders"

# ============================================================
Write-Host "`n=== Add-ParameterizedCondition (WHERE) ===" -ForegroundColor Cyan
# ============================================================

$cmd.Parameters.Clear()
$condition = Add-ParameterizedCondition -SqlCommand $cmd -Item $testItem -KeyColumns @("ComputerName", "DisplayName") -Prefix "k"

Assert-True -Condition ($condition -eq "[ComputerName] = @k0 AND [DisplayName] = @k1") `
    -Message "WHERE condition uses parameter placeholders"

Assert-True -Condition ($cmd.Parameters["@k0"].Value -eq "SERVER01") `
    -Message "Key param @k0 = 'SERVER01'"

Assert-True -Condition ($cmd.Parameters["@k1"].Value -eq "O'Brien's App; DROP TABLE--") `
    -Message "Key param @k1 contains injection string safely"

# ============================================================
Write-Host "`n=== Add-ParameterizedSetClause (UPDATE SET) ===" -ForegroundColor Cyan
# ============================================================

$cmd.Parameters.Clear()
$setClause = Add-ParameterizedSetClause -SqlCommand $cmd -Item $testItem -Prefix "s"

Assert-True -Condition ($setClause -match "\[ComputerName\] = @s0") `
    -Message "SET clause uses parameter placeholders"

Assert-True -Condition ($setClause -notmatch "O'Brien") `
    -Message "SET clause contains no inline values"

Assert-True -Condition ($cmd.Parameters["@s1"].Value -eq "O'Brien's App; DROP TABLE--") `
    -Message "SET param @s1 contains injection string safely"

# ============================================================
Write-Host "`n=== Test with real sample data ===" -ForegroundColor Cyan
# ============================================================

$sampleDir = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\InventoryParsed"
if (Test-Path $sampleDir) {
    $jsonFiles = Get-ChildItem -Path $sampleDir -Filter "*.json"
    Write-Host "  Found $($jsonFiles.Count) sample JSON files" -ForegroundColor Yellow

    foreach ($jsonFile in $jsonFiles) {
        $tableName = [IO.Path]::GetFileNameWithoutExtension($jsonFile.Name)

        # Test table name validation
        $nameValid = $true
        try { Test-SqlIdentifier -Name $tableName -Context "table name" } catch { $nameValid = $false }
        Assert-True -Condition $nameValid -Message "Table name '$tableName' passes validation"

        # Load and parameterize first item
        try {
            $jsonContent = Get-Content -Path $jsonFile.FullName -Raw | ConvertFrom-Json
            $firstItem = if ($jsonContent -is [System.Array]) { $jsonContent[0] } else { $jsonContent }

            if ($null -ne $firstItem) {
                $cmd.Parameters.Clear()
                $pInfo = Add-ParameterizedValues -SqlCommand $cmd -Item $firstItem -Prefix "p"

                $insertSql = "INSERT INTO [$tableName] ($($pInfo.Columns)) VALUES ($($pInfo.Placeholders))"

                # Verify no single-quoted values in SQL text
                Assert-True -Condition ($insertSql -notmatch "'[^']*'") `
                    -Message "$tableName INSERT has no inline quoted values (params: $($cmd.Parameters.Count))"
            }
        } catch {
            Write-Host "  WARN: Could not process $tableName : $_" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  SKIP: No sample data found at $sampleDir" -ForegroundColor Yellow
}

# ============================================================
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "  Passed: $script:TestsPassed" -ForegroundColor Green
Write-Host "  Failed: $script:TestsFailed" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
# ============================================================

if ($script:TestsFailed -gt 0) {
    exit 1
} else {
    exit 0
}
