Param(
    [Parameter(Mandatory=$true)]
    [string]$SqlServer,
    [Parameter(Mandatory=$true)]
    [string]$Database,
    [Parameter(Mandatory=$true)]
    [string]$JsonFilesPath,
    [Parameter(Mandatory=$true)]
    [string]$logFilePath
)

# PowerShell Script to Update SQL Tables from JSON Files

# Dot-source shared SQL helpers
. (Join-Path -Path $PSScriptRoot -ChildPath "SqlHelpers.ps1")

$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"

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


function Update-SqlTableFromJson {
    param (
        [string]$JsonFilePath
    )

    try {
        $JsonContent = Get-Content -Path $JsonFilePath -Raw | ConvertFrom-Json
        $TableName = [IO.Path]::GetFileNameWithoutExtension($JsonFilePath)

        Test-SqlIdentifier -Name $TableName -Context "table name"

        $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
        $SqlConnection.ConnectionString = $ConnectionString
        try {
            $SqlConnection.Open()

            # Create SQL command
            $SqlCommand = $SqlConnection.CreateCommand()

            foreach ($Item in $JsonContent) {
                $SqlCommand.Parameters.Clear()

                # Determine key columns for this table
                if ($KeyColumnsMap.ContainsKey($TableName)) {
                    $KeyColumns = $KeyColumnsMap[$TableName]
                } else {
                    $KeyColumns = @("ComputerName")
                }

                # Build parameterized WHERE condition for existence check
                $Condition = Add-ParameterizedCondition -SqlCommand $SqlCommand -Item $Item -KeyColumns $KeyColumns -Prefix "k"

                # Check if the record exists
                $SqlCommand.CommandText = "SELECT COUNT(*) FROM [$TableName] WHERE $Condition"
                $RecordExists = $SqlCommand.ExecuteScalar()

                if ($RecordExists -gt 0) {
                    # Record exists: perform parameterized UPDATE
                    $SqlCommand.Parameters.Clear()

                    $SetClause = Add-ParameterizedSetClause -SqlCommand $SqlCommand -Item $Item -Prefix "s"
                    $Condition = Add-ParameterizedCondition -SqlCommand $SqlCommand -Item $Item -KeyColumns $KeyColumns -Prefix "k"

                    $SqlCommand.CommandText = "UPDATE [$TableName] SET $SetClause WHERE $Condition"
                    try {
                        $SqlCommand.ExecuteNonQuery() | Out-Null
                    } catch {
                        $errorMessage = "Error updating table $TableName : $($_.Exception.Message)"
                        $errorMessage | Out-File -FilePath $logFilePath -Append
                    }

                } else {
                    # No record exists: perform parameterized INSERT
                    $SqlCommand.Parameters.Clear()

                    $paramInfo = Add-ParameterizedValues -SqlCommand $SqlCommand -Item $Item -Prefix "p"

                    $SqlCommand.CommandText = "INSERT INTO [$TableName] ($($paramInfo.Columns)) VALUES ($($paramInfo.Placeholders))"
                    try {
                        $SqlCommand.ExecuteNonQuery() | Out-Null
                    } catch {
                        $errorMessage = "Error inserting into table $TableName : $($_.Exception.Message)"
                        $errorMessage | Out-File -FilePath $logFilePath -Append
                    }
                }
            }

            # Customized output message
            $ComputerName = $JsonContent.ComputerName | Select-Object -Unique
            Write-Host "Table $TableName updated for $ComputerName"
        }
        finally {
            $SqlConnection.Dispose()
        }

    }
    catch {
        Write-Error "An error occurred: $_"
    }
}

# Iterate over each JSON file and update the corresponding table
Get-ChildItem -Path $JsonFilesPath -Filter "*.json" | ForEach-Object {
    Write-output ((get-Date).ToString() + " Updating table from file: " + $($_.FullName))
    ((get-Date).ToString() + " Updating table from file: " + $($_.FullName)) | Out-File -FilePath $logFilePath -Append
    Update-SqlTableFromJson -JsonFilePath $_.FullName
}

exit 0
