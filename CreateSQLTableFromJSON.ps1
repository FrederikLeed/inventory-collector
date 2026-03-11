Param(
    [string]$SqlServer = "sqlsrv01.domain.com", # Specify SQL ServerName
    [string]$Database = "inventory", # Specify DatabaseName
    [string]$JsonFilesPath = "D:\InventoryParsed"  # Update with the path to your JSON files
)

# Dot-source shared SQL helpers
. (Join-Path -Path $PSScriptRoot -ChildPath "SqlHelpers.ps1")

# Define SQL Server connection details
$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

# Function to check if a table exists
function Test-SqlTableExists {
    param (
        [string]$TableName
    )

    Test-SqlIdentifier -Name $TableName -Context "table name"

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()

        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = @TableName"
        $SqlCommand.Parameters.AddWithValue("@TableName", $TableName) | Out-Null
        $result = $SqlCommand.ExecuteScalar()

        return $result -gt 0
    }
    finally {
        $SqlConnection.Dispose()
    }
}

# Function to get the current schema of a table
function Get-SqlTableSchema {
    param (
        [string]$TableName
    )

    Test-SqlIdentifier -Name $TableName -Context "table name"

    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    try {
        $SqlConnection.Open()

        $SqlCommand = $SqlConnection.CreateCommand()
        $SqlCommand.CommandText = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = @TableName"
        $SqlCommand.Parameters.AddWithValue("@TableName", $TableName) | Out-Null
        $Adapter = New-Object System.Data.SqlClient.SqlDataAdapter $SqlCommand
        $DataSet = New-Object System.Data.DataSet
        $Adapter.Fill($DataSet)

        return $DataSet.Tables[0].Rows | ForEach-Object { $_.COLUMN_NAME }
    }
    finally {
        $SqlConnection.Dispose()
    }
}

# Function to create a SQL table from a JSON schema
function Create-SqlTableFromJson {
    param (
        [string]$TableName,
        [PSCustomObject]$FirstJsonItem
    )

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"

        # Start building the SQL CREATE TABLE command
        $SqlCreateTableCommand = "CREATE TABLE [$TableName] ("

        # Process each property in the JSON object to create column definitions
        foreach ($Property in $FirstJsonItem.PSObject.Properties) {
            $ColumnName = $Property.Name
            Test-SqlIdentifier -Name $ColumnName -Context "column name"

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
        try {
            $SqlConnection.Open()

            # Execute the SQL command
            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $SqlCreateTableCommand
            $SqlCommand.ExecuteNonQuery()

            Write-Host "Table $TableName created successfully."
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        Write-Error "An error occurred while creating $TableName : $_"
    }
}

# Function to add a new column to an existing table
function Add-SqlColumn {
    param (
        [string]$TableName,
        [string]$ColumnName,
        [string]$DataType
    )

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"
        Test-SqlIdentifier -Name $ColumnName -Context "column name"

        $SqlAddColumnCommand = "ALTER TABLE [$TableName] ADD [$ColumnName] $DataType"

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()

            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $SqlAddColumnCommand
            $SqlCommand.ExecuteNonQuery()

            Write-Host "Column $ColumnName added to $TableName."
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        Write-Error "An error occurred while adding column $ColumnName to $TableName : $_"
    }
}

# Function to remove a column from an existing table
function Remove-SqlColumn {
    param (
        [string]$TableName,
        [string]$ColumnName
    )

    try {
        Test-SqlIdentifier -Name $TableName -Context "table name"
        Test-SqlIdentifier -Name $ColumnName -Context "column name"

        $SqlRemoveColumnCommand = "ALTER TABLE [$TableName] DROP COLUMN [$ColumnName]"

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()

            $SqlCommand = $SqlConnection.CreateCommand()
            $SqlCommand.CommandText = $SqlRemoveColumnCommand
            $SqlCommand.ExecuteNonQuery()

            Write-Host "Column $ColumnName removed from $TableName."
        }
        finally {
            $SqlConnection.Dispose()
        }
    }
    catch {
        Write-Error "An error occurred while removing column $ColumnName from $TableName : $_"
    }
}

# Function to update a SQL table based on JSON schema
function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $JsonArray = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        $FirstJsonItem = if ($JsonArray -is [System.Array]) { $JsonArray[0] } else { $JsonArray }
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        if (-not (Test-SqlTableExists -TableName $TableName)) {
            Write-Host "Creating new table: $TableName"
            Create-SqlTableFromJson -TableName $TableName -FirstJsonItem $FirstJsonItem
        } else {
            Write-Host "Updating existing table: $TableName"
            $CurrentSchema = Get-SqlTableSchema -TableName $TableName
            $JsonSchema = $FirstJsonItem.PSObject.Properties.Name

            # Add new columns found in JSON but not in SQL table
            foreach ($Column in $JsonSchema) {
                if ($Column -notin $CurrentSchema) {
                    $DataType = switch ($FirstJsonItem.$Column.GetType().Name) {
                        "String" { "NVARCHAR(MAX)" }
                        "Int32" { "INT" }
                        "Boolean" { "BIT" }
                        Default { "NVARCHAR(MAX)" }
                    }
                    Add-SqlColumn -TableName $TableName -ColumnName $Column -DataType $DataType
                }
            }

            # Optionally, remove columns from SQL table not found in JSON
            # Be cautious with this as it can lead to data loss
            # foreach ($Column in $CurrentSchema) {
            #     if ($Column -notin $JsonSchema -and $Column -ne 'Id' -and $Column -ne 'UpdateTimeStamp') {
            #         Remove-SqlColumn -TableName $TableName -ColumnName $Column
            #     }
            # }
        }
    }
    catch {
        Write-Error "An error occurred while processing $TableName : $_"
    }
}

# Loop through each JSON file in the folder and create/update tables
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | ForEach-Object {
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}
