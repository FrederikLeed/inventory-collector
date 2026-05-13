$SqlServer = "(localdb)\MSSQLLocalDB"
$Database = "InventoryTest"
$SampleDataPath = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\InventoryParsed"
$TrimmedDataPath = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\Trimmed"
$LogFile = Join-Path -Path $PSScriptRoot -ChildPath "show-test.log"
$ScriptRoot = Split-Path -Path $PSScriptRoot -Parent
$MaxRowsPerFile = 1000
$SkipFiles = @("InstalledUpdates", "Invoice")

Add-Type -AssemblyName "System.Data"

$ConnectionString = "Server=$SqlServer;Integrated Security=True;"
$DbConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

# Setup: create DB, tables, insert data
Write-Host "=== Setting up database ===" -ForegroundColor Cyan

$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "IF EXISTS (SELECT name FROM sys.databases WHERE name = '$Database') BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]; END"
    $cmd.ExecuteNonQuery() | Out-Null
    $cmd.CommandText = "CREATE DATABASE [$Database]"
    $cmd.ExecuteNonQuery() | Out-Null
} finally { $conn.Dispose() }

# Prepare trimmed data
if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
New-Item -ItemType Directory -Path $TrimmedDataPath -Force | Out-Null
Get-ChildItem -Path $SampleDataPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $SkipFiles
} | ForEach-Object {
    $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
    if ($data -is [System.Array] -and $data.Count -gt $MaxRowsPerFile) {
        $trimmed = $data[0..($MaxRowsPerFile - 1)]
    } else { $trimmed = $data }
    $trimmed | ConvertTo-Json -Depth 10 | Out-File (Join-Path $TrimmedDataPath $_.Name) -Encoding UTF8
}

# Create tables + insert
& "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath 2>&1 | Out-Null
& "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath -logFilePath $LogFile 2>&1 | Out-Null

Write-Host "`n=== SELECT TOP 10 from each table ===`n" -ForegroundColor Cyan

$conn = New-Object System.Data.SqlClient.SqlConnection($DbConnectionString)
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()

    # Get all tables
    $cmd.CommandText = "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_NAME"
    $reader = $cmd.ExecuteReader()
    $tables = @()
    while ($reader.Read()) { $tables += $reader["TABLE_NAME"] }
    $reader.Close()

    foreach ($table in $tables) {
        # Get row count
        $cmd.CommandText = "SELECT COUNT(*) FROM [$table]"
        $totalRows = $cmd.ExecuteScalar()

        Write-Host "--- $table ($totalRows total rows) ---" -ForegroundColor Yellow

        $cmd.CommandText = "SELECT TOP 10 * FROM [$table]"
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        $adapter.Fill($dt) | Out-Null

        $dt | Format-Table -AutoSize -Wrap | Out-String -Width 200 | Write-Host
    }
} finally { $conn.Dispose() }

# Cleanup
Write-Host "=== Cleanup ===" -ForegroundColor Cyan
$conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = "ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]"
    $cmd.ExecuteNonQuery() | Out-Null
    Write-Host "  Database dropped" -ForegroundColor Yellow
} finally { $conn.Dispose() }

if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }
