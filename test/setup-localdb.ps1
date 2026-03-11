# Creates and populates InventoryTest database on LocalDB (no cleanup)
Add-Type -AssemblyName "System.Data"
$SqlServer = "(localdb)\MSSQLLocalDB"
$Database = "InventoryTest"
$SampleDataPath = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\InventoryParsed"
$TrimmedDataPath = Join-Path -Path $PSScriptRoot -ChildPath "sample-data\Trimmed"
$ScriptRoot = Split-Path -Path $PSScriptRoot -Parent
$MaxRows = 100
$SkipFiles = @("InstalledUpdates", "Invoice")
$ConnStr = "Server=$SqlServer;Integrated Security=True;"
$DbConnStr = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

# Drop + recreate DB
$conn = New-Object System.Data.SqlClient.SqlConnection($ConnStr)
$conn.Open()
$cmd = $conn.CreateCommand()
$cmd.CommandText = "IF EXISTS (SELECT name FROM sys.databases WHERE name = '$Database') BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]; END"
$cmd.ExecuteNonQuery() | Out-Null
$cmd.CommandText = "CREATE DATABASE [$Database]"
$cmd.ExecuteNonQuery() | Out-Null
$conn.Dispose()
Write-Host "Database '$Database' created"

# Trim data
if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
New-Item -ItemType Directory -Path $TrimmedDataPath -Force | Out-Null
Get-ChildItem -Path $SampleDataPath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $SkipFiles
} | ForEach-Object {
    $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
    if ($data -is [System.Array] -and $data.Count -gt $MaxRows) { $trimmed = $data[0..($MaxRows-1)] } else { $trimmed = $data }
    $trimmed | ConvertTo-Json -Depth 10 | Out-File (Join-Path $TrimmedDataPath $_.Name) -Encoding UTF8
    $count = if ($trimmed -is [System.Array]) { $trimmed.Count } else { 1 }
    Write-Host "  $($_.Name): $count rows"
}

# Create tables + insert data
& "$ScriptRoot\CreateSQLTableFromJSON.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath
& "$ScriptRoot\UpdateSQLTableFromJSON_new.ps1" -SqlServer $SqlServer -Database $Database -JsonFilesPath $TrimmedDataPath -logFilePath (Join-Path $PSScriptRoot "setup.log")

# Show summary
Write-Host "`nDatabase ready. Connect with:" -ForegroundColor Green
Write-Host "  Server: (localdb)\MSSQLLocalDB" -ForegroundColor Yellow
Write-Host "  Database: InventoryTest" -ForegroundColor Yellow
Write-Host "  Auth: Windows Authentication" -ForegroundColor Yellow

# Cleanup temp
if (Test-Path $TrimmedDataPath) { Remove-Item $TrimmedDataPath -Recurse -Force }
if (Test-Path (Join-Path $PSScriptRoot "setup.log")) { Remove-Item (Join-Path $PSScriptRoot "setup.log") -Force }
