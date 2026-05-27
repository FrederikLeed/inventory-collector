# SqlHelpers.ps1 - Shared helper functions for SQL operations
# Dot-source this file in scripts that interact with SQL Server

Add-Type -AssemblyName "System.Data"

# Natural-key map: per-table column set that uniquely identifies a logical row
# within a snapshot run. Always prefixed with RunId in indexes/dedup so a new
# RunId creates a new snapshot without colliding with prior runs.
$script:NaturalKeyMap = @{
    "PersonalCertificates" = @("ComputerName", "Thumbprint")
    "LocalUsers"           = @("ComputerName", "UserName")
    "GroupMembers"         = @("ComputerName", "GroupName")
    "AutoRunInfo"          = @("ComputerName", "Name")
    "DiskSpace"            = @("ComputerName", "Drive")
    "InstalledSoftware"    = @("ComputerName", "DisplayName", "DisplayVersion")
    "UserProfileList"      = @("ComputerName", "Name")
    "ShareAccessInfo"      = @("ComputerName", "ShareName")
    "Services"             = @("ComputerName", "Name")
    "ScheduledTasks"       = @("ComputerName", "TaskPath", "TaskName")
    "ServerList"           = @("ComputerName", "Description")
    "ServerAccess"         = @("ComputerName", "GroupName")
    # InstalledUpdates uses (ComputerName, Title) but is not snapshot/append-only,
    # so it's handled separately by Import-InstalledUpdatesDifferential.
}

function Get-NaturalKey {
    <#
    .SYNOPSIS
    Returns the snapshot natural key for a fact table, always prefixed with RunId.
    Tables not in $NaturalKeyMap fall back to (RunId, ComputerName).
    #>
    param ([Parameter(Mandatory)][string]$TableName)
    if ($script:NaturalKeyMap.ContainsKey($TableName)) {
        return @('RunId') + $script:NaturalKeyMap[$TableName]
    }
    return @('RunId', 'ComputerName')
}

function Test-SqlIdentifier {
    <#
    .SYNOPSIS
    Validates that a string is a safe SQL identifier (table or column name).
    Throws if the identifier contains characters outside the allowed set.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [string]$Context = "identifier"
    )

    if ($Name -notmatch '^[a-zA-Z0-9_ ]+$') {
        throw "Invalid SQL $Context '$Name'. Only alphanumeric characters, underscores, and spaces are allowed."
    }
}

function Convert-ToSimpleFormat {
    <#
    .SYNOPSIS
    Converts complex PowerShell objects to simple values suitable for SQL parameters.
    Arrays are serialized to compressed JSON strings. Nulls pass through as-is.
    #>
    param (
        [Object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    # Single-element array: unwrap only simple types, serialize complex objects
    if ($Value -is [System.Array] -and $Value.Count -eq 1) {
        $element = $Value[0]
        if ($element -is [string] -or $element -is [ValueType]) {
            return $element
        }
        return ($Value | ConvertTo-Json -Compress -Depth 10)
    }

    # Complex enumerable (arrays, lists): serialize to JSON
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [String]) {
        return ($Value | ConvertTo-Json -Compress -Depth 10)
    }

    # Strings + value types (incl. Int32/Int64/Boolean/DateTime) bind directly.
    # Anything else (PSCustomObject, hashtable, foreign types) gets serialized
    # so AddWithValue can bind it.
    if ($Value -is [string] -or $Value -is [ValueType]) {
        return $Value
    }
    return ($Value | ConvertTo-Json -Compress -Depth 10)
}

function Add-ParameterizedValues {
    <#
    .SYNOPSIS
    Adds SqlParameters for all properties of a JSON item to a SqlCommand.
    Returns the column list string and placeholder list string for use in INSERT/UPDATE.
    #>
    param (
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlCommand]$SqlCommand,
        [Parameter(Mandatory)]
        [PSObject]$Item,
        [string]$Prefix = "p"
    )

    $columns = @()
    $placeholders = @()
    $i = 0

    foreach ($prop in $Item.PSObject.Properties) {
        Test-SqlIdentifier -Name $prop.Name -Context "column name"

        $paramName = "@${Prefix}${i}"
        $value = Convert-ToSimpleFormat $prop.Value

        $columns += "[$($prop.Name)]"
        $placeholders += $paramName

        if ($null -eq $value) {
            $SqlCommand.Parameters.AddWithValue($paramName, [DBNull]::Value) | Out-Null
        } else {
            $SqlCommand.Parameters.AddWithValue($paramName, $value) | Out-Null
        }
        $i++
    }

    return @{
        Columns      = $columns -join ", "
        Placeholders = $placeholders -join ", "
    }
}

function Add-ParameterizedCondition {
    <#
    .SYNOPSIS
    Adds SqlParameters for key columns and returns a WHERE condition string.
    #>
    param (
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlCommand]$SqlCommand,
        [Parameter(Mandatory)]
        [PSObject]$Item,
        [Parameter(Mandatory)]
        [string[]]$KeyColumns,
        [string]$Prefix = "k"
    )

    $conditions = @()
    $k = 0

    foreach ($col in $KeyColumns) {
        Test-SqlIdentifier -Name $col -Context "key column name"

        $value = Convert-ToSimpleFormat $Item.$col

        # SQL Server treats `col = NULL` as UNKNOWN, never matching. For a
        # natural-key existence check we want NULL to match NULL exactly, so
        # emit `IS NULL` for null values and skip adding a parameter. Without
        # this, append-only INSERT WHERE NOT EXISTS on rows with a NULL key
        # column produces duplicates.
        if ($null -eq $value) {
            $conditions += "[$col] IS NULL"
        } else {
            $paramName = "@${Prefix}${k}"
            $conditions += "[$col] = $paramName"
            $SqlCommand.Parameters.AddWithValue($paramName, $value) | Out-Null
            $k++
        }
    }

    return $conditions -join " AND "
}

function Add-ParameterizedSetClause {
    <#
    .SYNOPSIS
    Adds SqlParameters for all properties of an item for SET clause in UPDATE.
    Returns the SET clause string.
    #>
    param (
        [Parameter(Mandatory)]
        [System.Data.SqlClient.SqlCommand]$SqlCommand,
        [Parameter(Mandatory)]
        [PSObject]$Item,
        [string]$Prefix = "s"
    )

    $setClauses = @()
    $i = 0

    foreach ($prop in $Item.PSObject.Properties) {
        Test-SqlIdentifier -Name $prop.Name -Context "column name"

        $paramName = "@${Prefix}${i}"
        $value = Convert-ToSimpleFormat $prop.Value

        $setClauses += "[$($prop.Name)] = $paramName"

        if ($null -eq $value) {
            $SqlCommand.Parameters.AddWithValue($paramName, [DBNull]::Value) | Out-Null
        } else {
            $SqlCommand.Parameters.AddWithValue($paramName, $value) | Out-Null
        }
        $i++
    }

    return $setClauses -join ", "
}
