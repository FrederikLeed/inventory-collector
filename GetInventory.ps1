# Define parameters for the computer name
param(
    [string]$ComputerName = $env:computerName
)

# Set the groups and other metrics to query
$groups = "Administrators", "Remote Desktop Users"
$metrics = "GroupMembers", "SystemInfo", "DiskSpace", "InstalledSoftware"

# Define base folder paths
$baseFolderPath = "C:\InventoryData"
$zipFolderPath = "C:\InventoryData\Zipped"
$centralFilesharePath = "\\DESKTOP-8Q45UIR\InventoryData"

# Final zip file path
$finalZipFile = Join-Path -Path $zipFolderPath -ChildPath "$ComputerName.zip"
$destinationZipFile = Join-Path -Path $centralFilesharePath -ChildPath "$ComputerName.zip"

# Check if the destination zip file already exists
if (Test-Path $destinationZipFile) {
    #Write-Host "The file '$destinationZipFile' already exists. Exiting script."
    exit
}

# Ensure the base and zip folder paths exist
if (-not (Test-Path $baseFolderPath)) {
    New-Item -Path $baseFolderPath -ItemType Directory
}
if (-not (Test-Path $zipFolderPath)) {
    New-Item -Path $zipFolderPath -ItemType Directory
}


# Function to log messages
function Write-Log {
    param (
        [string]$Message,
        [string]$LogFilePath
    )
    # Add timestamp to each log entry
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')): $Message" | Out-File -FilePath $LogFilePath -Append
}

# Function to collect group members
function Get-GroupMembers {
    param(
        [string[]]$groups,
        [string]$ComputerName,
        [string]$LogFilePath
    )

    # Initialize an array to hold the output data
    $groupMembersData = @()

    try {
        # Initialize ADSI connection
        $adsi = [ADSI]"WinNT://$ComputerName"

        foreach ($group in $groups) {
            # Attempt to retrieve the group object
            $groupObject = $adsi.Children | Where-Object { $_.SchemaClassName -eq 'group' -and $_.Name -eq $group }

            if ($groupObject) {
                # Retrieve group members
                $members = @($groupObject.Invoke("Members")) | ForEach-Object {
                    $adsPath = $_.GetType().InvokeMember("ADsPath", 'GetProperty', $null, $_, $null)
                    $adsPath.Replace("WinNT://", "")
                }
                Write-Log "Group '$group' members collected on $ComputerName" $LogFilePath
            } else {
                Write-Log "Group '$group' not found on $ComputerName" $LogFilePath
                $members = @()
            }

            # Add the data to the output array
            $groupMembersData += [PSCustomObject] @{
                PSComputerName = $ComputerName
                GroupName = $group
                Members = $members
            }
        }
    } catch {
        # Log and rethrow any exceptions
        Write-Log "Error encountered in Get-GroupMembers: $_" $LogFilePath
        throw $_
    }

    # Return the collected data
    return $groupMembersData
}


# Function to collect system information
function Get-SystemInfo {
    param($ComputerName, $LogFilePath)
    # ... [Logic to collect system info] ...
    # Returns collected data
}

# Function to collect disk space information
function Get-DiskSpace {
    param($ComputerName, $LogFilePath)
    # ... [Logic to collect disk space info] ...
    # Returns collected data
}

# Function to collect installed software information
function Get-InstalledSoftware {
    param($ComputerName, $LogFilePath)
    # ... [Logic to collect installed software info] ...
    # Returns collected data
}

# Function to export data to JSON
function Export-ToJson {
    param($Data, $FilePath)
    $Data | ConvertTo-Json | Out-File -FilePath $FilePath
}

# Main script block for querying metrics
$scriptBlock = {
    param($metrics, $ComputerName, $baseFolderPath, $zipFolderPath)

    foreach ($metric in $metrics) {
        # Define file paths
        $folderPath = Join-Path -Path $baseFolderPath -ChildPath $metric
        $OutputFilePath = Join-Path -Path $folderPath -ChildPath "$metric_$ComputerName.json"
        $LogFilePath = Join-Path -Path $folderPath -ChildPath "$metric_$ComputerName.log"

        # Ensure folder exists
        if (-not (Test-Path $folderPath)) {
            New-Item -Path $folderPath -ItemType Directory
        }

        # Call respective function based on metric
        switch ($metric) {
            "GroupMembers" { $data = Get-GroupMembers -groups $groups -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "SystemInfo" { $data = Get-SystemInfo -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "DiskSpace" { $data = Get-DiskSpace -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "InstalledSoftware" { $data = Get-InstalledSoftware -ComputerName $ComputerName -LogFilePath $LogFilePath }
        }

        # Export data to JSON
        Export-ToJson -Data $data -FilePath $OutputFilePath
    }

    # Ensure that the zip folder path is clear
    Get-ChildItem -Path $zipFolderPath | Remove-Item -Force

    # Zip each metric folder individually and then combine them
    Get-ChildItem -Path $baseFolderPath -Directory | Where-Object { $_.Name -ne "Zipped" } | ForEach-Object {
        $metricZipPath = Join-Path -Path $zipFolderPath -ChildPath "$($_.Name).zip"
        Compress-Archive -Path $_.FullName -DestinationPath $metricZipPath
    }

    # Combine all individual zips into one
    $finalZipFile = Join-Path -Path $zipFolderPath -ChildPath "$ComputerName.zip"
    Compress-Archive -Path (Get-ChildItem -Path $zipFolderPath -File).FullName -DestinationPath $finalZipFile

    # Move the combined zip file to a central fileshare location
    Move-Item -Path $finalZipFile -Destination $centralFilesharePath

    # Cleanup: Delete the entire base folder after moving the zip file
    Remove-Item -Path $baseFolderPath -Recurse -Force
}

# Invoke the script block
Invoke-Command -ScriptBlock $scriptBlock -ArgumentList $metrics, $ComputerName, $baseFolderPath, $zipFolderPath