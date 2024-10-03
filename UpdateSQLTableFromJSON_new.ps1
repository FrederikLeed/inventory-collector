Param(
    [string]$SqlServer = "server.domain.com", # Specify SQL ServerName
    [string]$Database = "Inventory", # Specify DatabaseName
    [string]$JsonFilesPath = "D:\InventoryParsed",  # Update with the path to your JSON files
    [string]$logFilePath = "D:\Logs\InventorySQLlog.log"  # Define log file path
)

# PowerShell Script to Update SQL Tables from JSON Files

# Import required assembly for SQL Server connectivity
Add-Type -AssemblyName "System.Data"

$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

    # Define a dictionary mapping table names to key columns
    $KeyColumnsMap = @{
        "PersonalCertificates" = @("ComputerName", "Thumbprint")
        "OtherTable" = @("ComputerName", "SomeOtherKey")
    }

function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $JsonContent = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        $SqlConnection.Open()

        # Create SQL command
        $SqlCommand = $SqlConnection.CreateCommand()

        foreach ($Item in $JsonContent) {
            $Columns = ($Item.PSObject.Properties | ForEach-Object { "[$($_.Name)]" }) -join ", "
            $Values = ($Item.PSObject.Properties | ForEach-Object { 
                $Value = Convert-ToSimpleFormat $_.Value
                "'$Value'"
            }) -join ", "

            # Dynamically construct the condition based on the key columns for the table
            if ($KeyColumnsMap.ContainsKey($TableName)) {
                $KeyColumns = $KeyColumnsMap[$TableName]
                $Condition = ($KeyColumns | ForEach-Object { "$_ = '$($Item.$_)" }) -join " AND "
            } else {
                # Fallback or error handling if table is not mapped
                $Condition = "ComputerName = '$($Item.ComputerName)'"
            }

            # Build the SQL command to check if the record exists
            $SqlCheckExistsCommand = "SELECT COUNT(*) FROM [$TableName] WHERE $Condition"
            $SqlCommand.CommandText = $SqlCheckExistsCommand
            $RecordExists = $SqlCommand.ExecuteScalar()

            if ($RecordExists -gt 0) {
                # If record exists, perform an UPDATE
                $SetColumns = ($Item.PSObject.Properties | ForEach-Object {
                    "$($_.Name) = '" + (Convert-ToSimpleFormat $_.Value) + "'"
                }) -join ", "

                $SqlUpdateCommand = "UPDATE [$TableName] SET $SetColumns WHERE $Condition"
                $SqlCommand.CommandText = $SqlUpdateCommand
                try {
                    $SqlCommand.ExecuteNonQuery() | Out-Null
                } catch {
                    $errorMessage = "Error updating table $TableName : $($_.Exception.Message)`nSQL Command: $SqlUpdateCommand"
                    $errorMessage | Out-File -FilePath $logFilePath -Append
                }

            } else {
                # If no record exists, perform an INSERT
                $SqlInsertCommand = "INSERT INTO [$TableName] ($Columns) VALUES ($Values)"
                $SqlCommand.CommandText = $SqlInsertCommand
                try {
                    $SqlCommand.ExecuteNonQuery() | Out-Null
                } catch {
                    $errorMessage = "Error inserting into table $TableName : $($_.Exception.Message)`nSQL Command: $SqlInsertCommand"
                    $errorMessage | Out-File -FilePath $logFilePath -Append
                }
            }
        }

        # Customized output message
        $ComputerName = $JsonContent.ComputerName | Select-Object -Unique
        Write-Host "Table $TableName updated for $ComputerName"

        $SqlConnection.Close()

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

    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [String]) {
        return ($Value | ConvertTo-Json -Compress)
    }
    elseif ($Value -is [Int64]) {
        return $Value.ToString()
    }
    return $Value
}

# Iterate over each JSON file and update the corresponding table
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | ForEach-Object {
    ($(get-Date) + " Updating table from file: " + $($_.FullName)) | Out-File -FilePath $logFilePath -Append
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}
exit 0