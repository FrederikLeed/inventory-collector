# One-shot: convert aggregated post-ParseInventory JSON (the fixture at
# test/sample-data/InventoryParsed) into per-Computer zips in the shape
# GetInventory emits. Used as a fixture builder for integration tests and for
# emulating multi-day history (see Demo-History.ps1).
#
#   <SourcePath>\<Metric>.json (rows for all servers concatenated)
#     ->
#   <OutPath>\<ComputerName>.zip
#       _collection-meta.json
#       <Metric>.zip
#         <Metric>/<Metric>_<ComputerName>.json (this Computer's rows only,
#                                                each stamped with the run's
#                                                RunId)
#
# After running, point ParseInventory.ps1 at <OutPath> and the rest of the
# production pipeline runs unchanged.

param(
    [string]$SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath 'sample-data\InventoryParsed'),
    [string]$OutPath    = 'C:\temp\inv-share-anon',
    [string[]]$SkipMetrics = @('Invoice'),
    # StartedAt / CompletedAt to bake into _collection-meta.json. Pass a
    # backdated ISO 8601 string to emulate a past collection (history demo).
    [string]$StartedAt  = (Get-Date).ToUniversalTime().ToString('o')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $OutPath) { Remove-Item $OutPath -Recurse -Force }
New-Item -ItemType Directory -Path $OutPath -Force | Out-Null

$workRoot = Join-Path $OutPath '_work'
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

# Bucket rows by (Metric, ComputerName), minting one RunId per Computer.
$perComputer = @{}
$runIds      = @{}

Get-ChildItem -Path $SourcePath -Filter "*.json" | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $SkipMetrics
} | ForEach-Object {
    $metric = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    Write-Host "Reading $metric ..."
    $data = Get-Content $_.FullName -Raw | ConvertFrom-Json
    if (-not ($data -is [System.Array])) { $data = @($data) }

    foreach ($row in $data) {
        if ($null -eq $row -or -not $row.ComputerName) { continue }
        $cn = [string]$row.ComputerName
        # Drop dirty data: anything that looks like a description / path
        # rather than a hostname. NetBIOS-safe charset only.
        if ($cn -notmatch '^[A-Za-z0-9_-]{1,64}$') { continue }

        if (-not $runIds.ContainsKey($cn)) {
            $runIds[$cn] = ([guid]::NewGuid()).ToString()
        }
        if (-not $perComputer.ContainsKey($cn)) {
            $perComputer[$cn] = @{}
        }
        if (-not $perComputer[$cn].ContainsKey($metric)) {
            $perComputer[$cn][$metric] = New-Object System.Collections.Generic.List[object]
        }
        if ($row.PSObject.Properties.Name -notcontains 'RunId') {
            $row | Add-Member -NotePropertyName 'RunId' -NotePropertyValue $runIds[$cn] -Force
        } else {
            $row.RunId = $runIds[$cn]
        }
        $perComputer[$cn][$metric].Add($row)
    }
}

Write-Host "`nServers discovered: $($perComputer.Count)"

# Write one outer zip per Computer in the GetInventory layout
$progress = 0
foreach ($cn in $perComputer.Keys) {
    $progress++
    if ($progress % 100 -eq 0 -or $progress -eq $perComputer.Count) {
        Write-Host "  Zipping $progress / $($perComputer.Count) ..."
    }

    $serverWork = Join-Path $workRoot $cn
    New-Item -ItemType Directory -Path $serverWork -Force | Out-Null

    $meta = [PSCustomObject]@{
        RunId            = $runIds[$cn]
        ComputerName     = $cn
        StartedAt        = $StartedAt
        CompletedAt      = $StartedAt
        Status           = 'Parsed'
        MetricsSucceeded = $perComputer[$cn].Count
        MetricsFailed    = 0
        FailedMetrics    = ''
    }
    $meta | ConvertTo-Json -Depth 5 | Out-File -FilePath (Join-Path $serverWork '_collection-meta.json') -Encoding UTF8

    foreach ($metric in $perComputer[$cn].Keys) {
        $metricDir = Join-Path $serverWork "_$metric"
        $innerDir  = Join-Path $metricDir $metric
        New-Item -ItemType Directory -Path $innerDir -Force | Out-Null

        $perComputer[$cn][$metric] |
            ConvertTo-Json -Depth 10 |
            Out-File -FilePath (Join-Path $innerDir ("${metric}_${cn}.json")) -Encoding UTF8

        $innerZipPath = Join-Path $serverWork "${metric}.zip"
        if (Test-Path $innerZipPath) { Remove-Item $innerZipPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($metricDir, $innerZipPath)
        Remove-Item $metricDir -Recurse -Force
    }

    $outerZipPath = Join-Path $OutPath "${cn}.zip"
    if (Test-Path $outerZipPath) { Remove-Item $outerZipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($serverWork, $outerZipPath)
    Remove-Item $serverWork -Recurse -Force
}

Remove-Item $workRoot -Recurse -Force
Write-Host "`nDone. $($perComputer.Count) zips written to $OutPath (StartedAt=$StartedAt)"
