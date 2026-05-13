# SqlHelpers.ps1 - Shared helper functions for SQL operations
# Dot-source this file in scripts that interact with SQL Server

Add-Type -AssemblyName "System.Data"

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

    # Long integers: convert to string for NVARCHAR columns
    if ($Value -is [Int64]) {
        return $Value.ToString()
    }

    return $Value
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
        # column (e.g. RunId NULL in legacy fixtures) produces duplicates.
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
