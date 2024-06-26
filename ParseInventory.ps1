Param(
    [string]$fileSharePath = "\\server\InventoryData",
    [string]$extractPath = "C:\Temp\InventoryExtract",
    [string]$aggregateOutputPath = "C:\AggregatedData"
)

$nestedExtractPath = Join-Path -Path $extractPath -ChildPath "Nested"

# Create directories and suppress the output
New-Item -Path $extractPath, $nestedExtractPath, $aggregateOutputPath -ItemType Directory -Force | Out-Null

# Initialize data storage
$aggregatedData = @{}
$hasErrors = $false

# Function to log messages to a file
function Write-Log {
    param(
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    #"$timestamp - $Message" | Out-File -FilePath $logFilePath -Append
}

# Process each zip file
Get-ChildItem -Path $fileSharePath -Filter "*.zip" | ForEach-Object {
    $zipFile = $_.FullName
    Expand-Archive -Path $zipFile -DestinationPath $extractPath -Force

    Get-ChildItem -Path $extractPath -Filter "*.zip" | ForEach-Object {
        $nestedZipFile = $_.FullName
        Expand-Archive -Path $nestedZipFile -DestinationPath $nestedExtractPath -Force

        # Process all JSON files in the nested directory
        Get-ChildItem -Path $nestedExtractPath -Filter "*.json" -Recurse | ForEach-Object {
            $jsonFilePath = $_.FullName
            $metricName = Split-Path -Path $_.Directory -Leaf

            try {
                $jsonData = Get-Content -Path $jsonFilePath | ConvertFrom-Json
                if ($jsonData) {
                    # Aggregate data based on metric name
                    if (-not $aggregatedData.ContainsKey($metricName)) {
                        $aggregatedData[$metricName] = @()
                    }
                    $aggregatedData[$metricName] += $jsonData
                } else {
                    Write-Host "No data found in file: $jsonFilePath"
                    # Log the occurrence of no data found
                    Write-Log -Message "No data found in file: $jsonFilePath"
                }
            } catch {
                Write-Host "Error reading JSON from $jsonFilePath : $_"
                # Log the error
                Write-Log -Message "Error reading JSON from $jsonFilePath : $_"
                $hasErrors = $true
            }
        }

        Remove-Item -Path $nestedExtractPath -Recurse -Force
    }

    Remove-Item -Path $extractPath -Recurse -Force
}

# Export data
foreach ($metricName in $aggregatedData.Keys) {
    $outputFilePath = Join-Path -Path $aggregateOutputPath -ChildPath "$metricName.json"
    if ($aggregatedData[$metricName].Count -gt 0) {
        $aggregatedData[$metricName] | ConvertTo-Json -Depth 5 | Out-File -FilePath $outputFilePath
    } else {
        Write-Host "No data to write for $metricName"
        # Log the occurrence of no data to write
        Write-Log -Message "No data to write for $metricName"
    }
}

Write-Host "Aggregated data files saved to: $aggregateOutputPath"
Write-Log -Message "Aggregated data files saved to: $aggregateOutputPath"

if ($hasErrors) {
    exit 1
} else {
    exit 0
}
