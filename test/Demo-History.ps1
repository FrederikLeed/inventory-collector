# Demo helper: emulates N days of inventory collection history against the
# anonymized test fixture so the append-only / differential machinery can be
# exercised at realistic scale.
#
# Each round:
#   1. Calls Build-Zips.ps1 with a backdated StartedAt
#   2. Runs ParseInventory.ps1 over the resulting zips
#   3. Runs UpdateSQLTableFromJSON.ps1 to load
#
# CreateSQLTableFromJSON.ps1 is run once at the top; subsequent rounds reuse
# the same tables (Update appends snapshots, InstalledUpdates differential
# refreshes LastSeenRunId/LastSeenAt).

param(
    [string]$SqlServer  = '(localdb)\MSSQLLocalDB',
    [string]$Database   = 'InventoryTest',
    [string]$SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath 'sample-data\InventoryParsed'),
    [int]   $Rounds     = 5,
    [int]   $DaysApart  = 1,
    [switch]$DropDb
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Data

$ScriptRoot     = Split-Path -Path $PSScriptRoot -Parent
$ZipPath        = 'C:\temp\inv-share-history'
$ExtractPath    = 'C:\temp\inv-extract-history'
$AggPath        = 'C:\temp\inv-agg-history'
$LoadLog        = 'C:\temp\inv-history-load.log'
$BuildScript    = Join-Path $PSScriptRoot 'Build-Zips.ps1'

$ConnectionString = "Server=$SqlServer;Integrated Security=True;"

if ($DropDb) {
    Write-Host "=== Dropping + recreating $Database ===" -ForegroundColor Cyan
    $c = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    $c.Open()
    $cmd = $c.CreateCommand()
    $cmd.CommandText = "IF EXISTS (SELECT name FROM sys.databases WHERE name = '$Database') BEGIN ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$Database]; END; CREATE DATABASE [$Database];"
    $cmd.ExecuteNonQuery() | Out-Null
    $c.Dispose()
}

if (Test-Path $LoadLog) { Remove-Item $LoadLog -Force }

for ($r = 1; $r -le $Rounds; $r++) {
    $daysAgo   = ($Rounds - $r) * $DaysApart
    $startedAt = (Get-Date).AddDays(-$daysAgo).ToUniversalTime().ToString('o')

    Write-Host "`n=== Round $r / $Rounds  (StartedAt = $startedAt) ===" -ForegroundColor Cyan

    & $BuildScript -SourcePath $SourcePath -OutPath $ZipPath -StartedAt $startedAt | Out-Null

    if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force }
    if (Test-Path $AggPath)     { Remove-Item $AggPath     -Recurse -Force }
    New-Item -ItemType Directory -Path $ExtractPath -Force | Out-Null
    New-Item -ItemType Directory -Path $AggPath     -Force | Out-Null

    & "$ScriptRoot\ParseInventory.ps1" `
        -fileSharePath $ZipPath `
        -extractPath $ExtractPath `
        -aggregateOutputPath $AggPath | Select-Object -Last 2

    # Run CreateSQLTableFromJSON once on round 1 to land the schema; later
    # rounds reuse the tables. (Subsequent runs are idempotent so calling it
    # every round also works but is wasteful.)
    if ($r -eq 1) {
        & "$ScriptRoot\CreateSQLTableFromJSON.ps1" `
            -SqlServer $SqlServer -Database $Database -JsonFilesPath $AggPath | Out-Null
    }

    & "$ScriptRoot\UpdateSQLTableFromJSON.ps1" `
        -SqlServer $SqlServer -Database $Database -JsonFilesPath $AggPath -logFilePath $LoadLog | Out-Null

    $db = New-Object System.Data.SqlClient.SqlConnection("Server=$SqlServer;Database=$Database;Integrated Security=True;")
    $db.Open()
    $cmd = $db.CreateCommand()
    $cmd.CommandText = "SELECT (SELECT COUNT(*) FROM dbo.CollectionRuns) AS Runs, (SELECT COUNT(*) FROM dbo.Computers) AS Computers, (SELECT COUNT(*) FROM dbo.InstalledSoftware) AS Sw, (SELECT COUNT(*) FROM dbo.InstalledUpdates) AS Upd, (SELECT COUNT(*) FROM dbo.SystemInfo) AS Sys"
    $r2 = $cmd.ExecuteReader()
    if ($r2.Read()) {
        Write-Host ("  After round {0}: Runs={1}  Computers={2}  InstalledSoftware={3}  InstalledUpdates={4}  SystemInfo={5}" -f $r, $r2['Runs'], $r2['Computers'], $r2['Sw'], $r2['Upd'], $r2['Sys']) -ForegroundColor Yellow
    }
    $r2.Close()
    $db.Dispose()
}

Remove-Item $ZipPath, $ExtractPath, $AggPath -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "`nHistory emulation complete. $Rounds round(s) loaded into $Database." -ForegroundColor Green
