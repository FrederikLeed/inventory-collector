﻿Param(
    [string]$SqlServer = "server.domain.com", # Specify SQL ServerName
    [string]$Database = "Inventory", # Specify DatabaseName
    [string]$JsonFilesPath = "D:\InventoryParsed",  # Update with the path to your JSON files
    [string]$logFilePath = "D:\Logs\InventorySQLlog.log"  # Define log file path
)

# PowerShell Script to Update SQL Tables from JSON Files

# Import required assembly for SQL Server connectivity
Add-Type -AssemblyName "System.Data"

$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

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

        # Delete existing records from the table unless the table is 'SecurityLogEvent4624Summary'
        if ($TableName -ne 'SecurityLogEvent4624Summary') {
            $SqlDeleteCommand = "DELETE FROM [$TableName]"
            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $SqlDeleteCommand
            $SqlCommand.ExecuteNonQuery() | Out-Null
        }
        #Create SQL command object
            $SqlCommand = $SqlConnection.CreateCommand()

        # Insert new records with uniqueness check
        foreach ($Item in $JsonContent) {
            $Columns = ($Item.PSObject.Properties | ForEach-Object { "[$($_.Name)]" }) -join ", "
            $Values = ($Item.PSObject.Properties | ForEach-Object { 
                $Value = Convert-ToSimpleFormat $_.Value
                "'$Value'" 
            }) -join ", "

            if ($TableName -eq 'SecurityLogEvent4624Summary') {
                # Construct the unique key check query
                $CheckExistsQuery = @"
                    SELECT COUNT(1) FROM [$TableName]
                    WHERE 
                        [ComputerName] = '$($Item.ComputerName)' AND
                        [TargetUserName] = '$($Item.TargetUserName)' AND
                        [TargetDomainName] = '$($Item.TargetDomainName)' AND
                        [LogonType] = '$($Item.LogonType)' AND
                        [IpAddress] = '$($Item.IpAddress)' AND
                        [LogonTypeName] = '$($Item.LogonTypeName)' AND
                        [LatestLogonTimeStamp] = '$($Item.LatestLogonTimeStamp.value)'
"@

                $SqlCommand.CommandText = $CheckExistsQuery
                $RecordExists = $SqlCommand.ExecuteScalar()

                if ($RecordExists -eq 0) {
                    # Insert if the record does not exist
                    $SqlInsertCommand = "INSERT INTO [$TableName] ($Columns) VALUES ($Values)"
                }
                else {
                    continue # Skip if the record already exists
                }
            }
            else {
                # Default insert for other tables
                $SqlInsertCommand = "INSERT INTO [$TableName] ($Columns) VALUES ($Values)"
            }
            
            $SqlCommand.CommandText = $SqlInsertCommand
            try {
                $SqlCommand.ExecuteNonQuery() | Out-Null
            } catch {
                # Log the error and the SQL command that caused it
                $errorMessage = "Error in table $TableName : $($_.Exception.Message)`nSQL Command: $SqlInsertCommand"
                $errorMessage | Out-File -FilePath $logFilePath -Append
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
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}
exit 0
