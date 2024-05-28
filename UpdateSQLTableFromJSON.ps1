Param(
    [string]$SqlServer = "sqlsrv01.domain.com", #Specify SQL ServerName
    [string]$Database = "inventory", #Specify DatabaseName
    [string]$JsonFilesPath = "D:\InventoryParsed",  # Update with the path to your JSON files
    [string]$logFilePath = "D:\InventoryParsed\SqlInsertLog.txt"  # Define log file path
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

        # Delete existing records from the table
        $SqlDeleteCommand = "DELETE FROM [$TableName]"
        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = $SqlDeleteCommand
        $SqlCommand.ExecuteNonQuery() | Out-Null

        # Insert new records
        foreach ($Item in $JsonContent) {
            $Columns = ($Item.PSObject.Properties | ForEach-Object { "[$($_.Name)]" }) -join ", "
            $Values = ($Item.PSObject.Properties | ForEach-Object { 
                $Value = Convert-ToSimpleFormat $_.Value
                "'$Value'" 
            }) -join ", "
            $SqlInsertCommand = "INSERT INTO [$TableName] ($Columns) VALUES ($Values)"
            
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