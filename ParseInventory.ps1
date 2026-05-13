Param(
    [Parameter(Mandatory=$true)]
    [string]$fileSharePath,
    [Parameter(Mandatory=$true)]
    [string]$extractPath,
    [Parameter(Mandatory=$true)]
    [string]$aggregateOutputPath
)

$nestedExtractPath = Join-Path -Path $extractPath -ChildPath "Nested"

New-Item -Path $extractPath, $nestedExtractPath, $aggregateOutputPath -ItemType Directory -Force | Out-Null

# Script-scoped so writes from inside ForEach-Object script blocks propagate.
$script:aggregatedData = @{}
$script:collectionRuns = @()   # Schema V2: one entry per _collection-meta.json found
$script:hasErrors      = $false
$script:zipsProcessed  = 0
$script:zipsFailed     = 0
$script:jsonProcessed  = 0
$script:jsonFailed     = 0

Get-ChildItem -Path $fileSharePath -Filter "*.zip" | ForEach-Object {
    $zipFile = $_.FullName

    try {
        Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force -ErrorAction Stop
    } catch {
        Write-Host "Error extracting outer zip $zipFile : $_"
        $script:hasErrors = $true
        $script:zipsFailed++
        return
    }

    # Schema V2: pick up the per-run metadata sidecar if present at the top
    # level of the outer zip. GetInventory >= V2 writes this; older zips
    # without it are silently skipped (the SQL loader can fall back).
    $metaPath = Join-Path -Path $extractPath -ChildPath '_collection-meta.json'
    if (Test-Path $metaPath) {
        try {
            $metaData = Get-Content -Path $metaPath -Raw | ConvertFrom-Json
            $script:collectionRuns += $metaData
        } catch {
            Write-Host "Error reading collection meta from $metaPath : $_"
            $script:hasErrors = $true
        }
    }

    Get-ChildItem -Path $extractPath -Filter "*.zip" | ForEach-Object {
        $nestedZipFile = $_.FullName

        try {
            Expand-Archive -Path $nestedZipFile -DestinationPath $nestedExtractPath -Force -ErrorAction Stop
        } catch {
            Write-Host "Error extracting nested zip $nestedZipFile : $_"
            $script:hasErrors = $true
            return
        }

        Get-ChildItem -Path $nestedExtractPath -Filter "*.json" -Recurse | ForEach-Object {
            $jsonFilePath = $_.FullName
            $metricName   = Split-Path -Path $_.Directory -Leaf

            try {
                $jsonData = Get-Content -Path $jsonFilePath | ConvertFrom-Json
                if ($jsonData) {
                    if (-not $script:aggregatedData.ContainsKey($metricName)) {
                        $script:aggregatedData[$metricName] = @()
                    }
                    $script:aggregatedData[$metricName] += $jsonData
                    $script:jsonProcessed++
                } else {
                    Write-Host "No data found in file: $jsonFilePath"
                }
            } catch {
                Write-Host "Error reading JSON from $jsonFilePath : $_"
                $script:hasErrors = $true
                $script:jsonFailed++
            }
        }

        try {
            Remove-Item -Path $nestedExtractPath -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Host "Error cleaning up nested extract path $nestedExtractPath : $_"
            $script:hasErrors = $true
        }
    }

    try {
        Remove-Item -Path $extractPath -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host "Error cleaning up extract path $extractPath : $_"
        $script:hasErrors = $true
    }

    $script:zipsProcessed++
}

foreach ($metricName in $script:aggregatedData.Keys) {
    $outputFilePath = Join-Path -Path $aggregateOutputPath -ChildPath "$metricName.json"
    if ($script:aggregatedData[$metricName].Count -gt 0) {
        $script:aggregatedData[$metricName] | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputFilePath
    } else {
        Write-Host "No data to write for $metricName"
    }
}

# Schema V2: aggregate the per-run metadata into CollectionRuns.json. The SQL
# loader picks this up and writes to dbo.CollectionRuns + dbo.Computers.
if ($script:collectionRuns.Count -gt 0) {
    $runsPath = Join-Path -Path $aggregateOutputPath -ChildPath 'CollectionRuns.json'
    $script:collectionRuns | ConvertTo-Json -Depth 5 | Out-File -FilePath $runsPath -Encoding UTF8
    Write-Host "CollectionRuns aggregated: $($script:collectionRuns.Count) run(s)"
}

Write-Host "Aggregated data files saved to: $aggregateOutputPath"
Write-Host "Summary: zips processed=$($script:zipsProcessed), zips failed=$($script:zipsFailed), json processed=$($script:jsonProcessed), json failed=$($script:jsonFailed), runs=$($script:collectionRuns.Count)"

if ($script:hasErrors) {
    exit 1
} else {
    exit 0
}
