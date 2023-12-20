Param(
    [string]$SqlServer = "sqlsrv01.domain.com", #Specify SQL ServerName
    [string]$Database = "inventory", #Specify DatabaseName
    [string]$JsonFilesPath = "D:\InventoryParsed"  # Update with the path to your JSON files
)

# Import required assembly for SQL Server connectivity
Add-Type -AssemblyName "System.Data"

# Define SQL Server connection details
$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

# Function to create a SQL table from a JSON schema
function Create-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        # Read and convert the JSON file
        $JsonArray = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json

        # Check if JSON content is an array and take the first element
        $FirstJsonItem = if ($JsonArray -is [System.Array]) { $JsonArray[0] } else { $JsonArray }

        # Generate the table name (you can customize this)
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        # Start building the SQL CREATE TABLE command
        $SqlCreateTableCommand = "CREATE TABLE [$TableName] ("

        # Process each property in the first JSON object to create column definitions
        foreach ($Property in $FirstJsonItem.PSObject.Properties) {
            $ColumnName = $Property.Name
            $DataType = switch ($Property.TypeNameOfValue) {
                "System.String" { "NVARCHAR(MAX)" }
                "System.Int32" { "INT" }
                "System.Boolean" { "BIT" }
                Default { "NVARCHAR(MAX)" }
            }

            $SqlCreateTableCommand += "[$ColumnName] $DataType, "
        }

        # Add the Id and UpdateTimeStamp columns
        $SqlCreateTableCommand += "[Id] INT IDENTITY(1,1) PRIMARY KEY, "
        $SqlCreateTableCommand += "[UpdateTimeStamp] DATETIME DEFAULT GETDATE())"

        # Create and open SQL connection
        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        $SqlConnection.Open()

        # Execute the SQL command
        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = $SqlCreateTableCommand
        $SqlCommand.ExecuteNonQuery()

        # Close the SQL connection
        $SqlConnection.Close()

        Write-Host "Table $TableName created successfully."
    }
    catch {
        Write-Error "An error occurred: $_"
    }
}

# Loop through each JSON file in the folder and create a table
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | ForEach-Object {
    Create-SqlTableFromJson -JsonFilePath $_.FullName
}
