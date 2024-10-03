Param(
    [string]$SqlServer = "sqlserver01.domain.com", # Specify SQL Server Name
    [string]$Database = "Inventory", # Specify Database Name
    [string]$JsonFilesPath = "F:\InventoryOutput",  # Update with the path to your JSON files
    [string]$logFilePath = "f:\Logs\InventorySQLlog.log"  # Define log file path
)


# Install required modules (if not already installed)
# Install-Module -Name Az -AllowClobber -Force
# Install-Module -Name SqlServer -AllowClobber -Force

# Sign in to your Azure account
Connect-AzAccount -Identity

# Get the access token from Azure AD
$accessToken = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token

# Define a dictionary mapping table names to key columns
$KeyColumnsMap = @{
    "PersonalCertificates" = @("ComputerName", "Thumbprint")
    "LocalUsers" = @("ComputerName", "UserName")
    "GroupMembers" = @("ComputerName", "GroupName")
    "AutoRunInfo" = @("ComputerName", "Name")
    "DiskSpace" = @("ComputerName", "Drive")   
    "InstalledUpdates" = @("ComputerName", "Title")
    "InstalledSoftware" = @("ComputerName", "DisplayName","DisplayVersion")    
    "UserProfileList" = @("ComputerName", "Name")
    "ShareAccessInfo" = @("ComputerName", "ShareName")
    "Services" = @("ComputerName", "Name")    
}

# Function to update or insert SQL records from a JSON file
function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $JsonContent = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        foreach ($Item in $JsonContent) {
            $Columns = ($Item.PSObject.Properties | ForEach-Object { "[$($_.Name)]" }) -join ", "
            $Values = ($Item.PSObject.Properties | ForEach-Object { 
                $Value = Convert-ToSimpleFormat $_.Value
                "'$Value'"
            }) -join ", "

            # Dynamically construct the condition based on the key columns for the table
            if ($KeyColumnsMap.ContainsKey($TableName)) {
                $KeyColumns = $KeyColumnsMap[$TableName]
                $Condition = ($KeyColumns | ForEach-Object { "$_ = '$($Item.$_)'" }) -join " AND "
            } else {
                # Fallback or error handling if table is not mapped
                $Condition = "ComputerName = '$($Item.ComputerName)'"
            }

            # Build the SQL command to check if the record exists
            $SqlCheckExistsCommand = "SELECT COUNT(*) FROM [$TableName] WHERE $Condition"
            $RecordExists = Invoke-SqlCmd -ServerInstance $SqlServer -Database $Database -AccessToken $accessToken -Query $SqlCheckExistsCommand | Select-Object -ExpandProperty Column1

            if ($RecordExists -gt 0) {
                # If record exists, perform an UPDATE
                $SetColumns = ($Item.PSObject.Properties | ForEach-Object {
                    "$($_.Name) = '" + (Convert-ToSimpleFormat $_.Value) + "'"
                }) -join ", "

                $SqlUpdateCommand = "UPDATE [$TableName] SET $SetColumns WHERE $Condition"
                try {
                    Invoke-SqlCmd -ServerInstance $SqlServer -Database $Database -AccessToken $accessToken -Query $SqlUpdateCommand
                } catch {
                    $errorMessage = "Error updating table $TableName : $($_.Exception.Message)`nSQL Command: $SqlUpdateCommand"
                    $errorMessage | Out-File -FilePath $logFilePath -Append
                }

            } else {
                # If no record exists, perform an INSERT
                $SqlInsertCommand = "INSERT INTO [$TableName] ($Columns) VALUES ($Values)"
                try {
                    Invoke-SqlCmd -ServerInstance $SqlServer -Database $Database -AccessToken $accessToken -Query $SqlInsertCommand
                } catch {
                    $errorMessage = "Error inserting into table $TableName : $($_.Exception.Message)`nSQL Command: $SqlInsertCommand"
                    $errorMessage | Out-File -FilePath $logFilePath -Append
                }
            }
        }

        # Customized output message
        $ComputerName = $JsonContent.ComputerName | Select-Object -Unique
        Write-Host "Table $TableName updated for $ComputerName"

    }
    catch {
        Write-Error "An error occurred: $_"
    }
}

# Utility function to convert complex objects to a simple format
function Convert-ToSimpleFormat {
    param (
        [Object]$Value
    )

    # Handle array values
    if ($Value -is [System.Array] -and $Value.Count -eq 1) {
        # If it's a single-element array, return that single element
        return $Value[0]
    }
    elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [String]) {
        # If it's a complex array, return it as a compressed JSON string
        return ($Value | ConvertTo-Json -Compress)
    }
    elseif ($Value -is [Int64]) {
        # If it's a long integer, convert to string
        return $Value.ToString()
    }
    return $Value
}


# Iterate over each JSON file and update the corresponding table
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | ForEach-Object {
    Write-output ((get-Date).ToString() + " Updating table from file: " + $($_.FullName))
    ((get-Date).ToString() + " Updating table from file: " + $($_.FullName)) | Out-File -FilePath $logFilePath -Append
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}

exit 0
