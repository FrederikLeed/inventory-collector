Param(
    [string]$SqlServer = "mk-azure-sql-01.database.windows.net", # Specify SQL Server Name
    [string]$Database = "inventory", # Specify Database Name
    [string]$JsonFilesPath = "F:\InventoryOutput",  # Update with the path to your JSON files
    [string]$subscriptionID = "your-subscription-id", # Azure Subscription ID
    [string]$userName = "az-admfnl@morsoe.onmicrosoft.com" # Azure AD Username
)

# Install required modules (if not already installed)
# Install-Module -Name Az -AllowClobber -Force
# Install-Module -Name SqlServer -AllowClobber -Force

# Sign in to your Azure account
Connect-AzAccount -UseDeviceAuthentication -Subscription $subscriptionID

# Get the access token from Azure AD
$accessToken = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token

# Function to check if a table exists
function Test-SqlTableExists {
    param (
        [string]$TableName
    )

    $query = "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$TableName'"

    # Using Invoke-SqlCmd to execute the query
    $result = Invoke-SqlCmd -ServerInstance $SqlServer -Database $Database -AccessToken $accessToken -Query $query
    return $result.Column1 -gt 0
}

# Function to get the current schema of a table
function Get-SqlTableSchema {
    param (
        [string]$TableName
    )

    $query = "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$TableName'"

    # Using Invoke-SqlCmd to execute the query
    $result = Invoke-SqlCmd -ServerInstance $SqlServer -Database $Database -AccessToken $accessToken -Query $query

    return $result | ForEach-Object { $_.COLUMN_NAME }
}

# Function to create a SQL table from a JSON schema
function Create-SqlTableFromJson {
    param (
        [string]$TableName,
        [PSCustomObject]$FirstJsonItem
    )

    try {
        # Start building the SQL CREATE TABLE command
        $SqlCreateTableCommand = "CREATE TABLE [$TableName] ("

        # Process each property in the JSON object to create column definitions
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

        # Execute the SQL command using Invoke-SqlCmd
        Invoke-SqlCmd -ServerInstance $SqlServer -Database $Database -AccessToken $accessToken -Query $SqlCreateTableCommand

        Write-Host "Table $TableName created successfully."
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
        $SqlAddColumnCommand = "ALTER TABLE [$TableName] ADD [$ColumnName] $DataType"

        # Execute the SQL command using Invoke-SqlCmd
        Invoke-SqlCmd -ServerInstance $SqlServer -Database $Database -AccessToken $accessToken -Query $SqlAddColumnCommand

        Write-Host "Column $ColumnName added to $TableName."
    }
    catch {
        Write-Error "An error occurred while adding column $ColumnName to $TableName : $_"
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
