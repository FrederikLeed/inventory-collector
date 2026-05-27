<#
.SYNOPSIS
    Applies the retention policy: prunes old snapshots, marks silent
    computers inactive, removes long-dead InstalledUpdates rows.

.DESCRIPTION
    Designed to be invoked by scheduler.ps1 weekly. Three operations:

    1. For every Computer, keep only the most-recent -RetainRuns CollectionRuns
       rows. The FK ON DELETE CASCADE on every snapshot fact table propagates
       the delete to the fact rows automatically.
    2. Drop InstalledUpdates rows whose UninstalledAt is older than
       -RetainUninstalledDays (these represent KBs no longer installed
       anywhere, kept around for a grace period for audit).
    3. Mark Computers IsActive = 0 when LastSeenAt is older than
       -InactiveAfterDays.

    Idempotent. Safe to run any number of times.

.EXAMPLE
    .\Run-RetentionPolicy.ps1 -SqlServer 'sql01.domain.com' -Database 'Inventory'

.EXAMPLE
    .\Run-RetentionPolicy.ps1 -SqlServer '(localdb)\MSSQLLocalDB' `
                              -Database InventoryTest `
                              -RetainRuns 30
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$SqlServer,
    [Parameter(Mandatory=$true)]
    [string]$Database,
    [int]$RetainRuns             = 90,
    [int]$RetainUninstalledDays  = 180,
    [int]$InactiveAfterDays      = 30
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName 'System.Data'

$ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"
$script:hasErrors = $false

function Invoke-Sql {
    param([string]$Sql, [hashtable]$Parameters = @{})

    $conn = New-Object System.Data.SqlClient.SqlConnection($ConnectionString)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Sql
        $cmd.CommandTimeout = 600
        foreach ($k in $Parameters.Keys) {
            $cmd.Parameters.AddWithValue($k, $Parameters[$k]) | Out-Null
        }
        $rows = $cmd.ExecuteNonQuery()
        return $rows
    }
    finally {
        $conn.Dispose()
    }
}

Write-Host "Retention policy starting against $SqlServer / $Database"
Write-Host "  RetainRuns            = $RetainRuns"
Write-Host "  RetainUninstalledDays = $RetainUninstalledDays"
Write-Host "  InactiveAfterDays     = $InactiveAfterDays"

# ============================================================
# 1. Trim CollectionRuns to the most-recent N per Computer
# ============================================================
try {
    $sql = @"
WITH RankedRuns AS (
    SELECT RunId,
           ROW_NUMBER() OVER (PARTITION BY ComputerName ORDER BY StartedAt DESC) AS rn
    FROM dbo.CollectionRuns
)
DELETE FROM dbo.CollectionRuns
WHERE RunId IN (SELECT RunId FROM RankedRuns WHERE rn > @retain);
"@
    $deleted = Invoke-Sql -Sql $sql -Parameters @{ '@retain' = $RetainRuns }
    Write-Host "  CollectionRuns rows pruned: $deleted (cascaded to fact tables via FK)"
} catch {
    $script:hasErrors = $true
    Write-Error "CollectionRuns prune failed: $_"
}

# ============================================================
# 2. Drop InstalledUpdates rows uninstalled longer than the retention window
# ============================================================
try {
    $sql = @"
DELETE FROM dbo.InstalledUpdates
WHERE UninstalledAt IS NOT NULL
  AND UninstalledAt < DATEADD(DAY, -@days, SYSUTCDATETIME());
"@
    $deleted = Invoke-Sql -Sql $sql -Parameters @{ '@days' = $RetainUninstalledDays }
    Write-Host "  InstalledUpdates uninstalled-rows pruned: $deleted"
} catch {
    $script:hasErrors = $true
    Write-Error "InstalledUpdates prune failed: $_"
}

# ============================================================
# 3. Flip silent computers to IsActive = 0
# ============================================================
try {
    $sql = @"
UPDATE dbo.Computers
SET    IsActive      = 0,
       DeactivatedAt = SYSUTCDATETIME()
WHERE  IsActive  = 1
  AND  LastSeenAt < DATEADD(DAY, -@days, SYSUTCDATETIME());
"@
    $updated = Invoke-Sql -Sql $sql -Parameters @{ '@days' = $InactiveAfterDays }
    Write-Host "  Computers deactivated: $updated"
} catch {
    $script:hasErrors = $true
    Write-Error "Computer deactivation failed: $_"
}

Write-Host "Retention policy complete."

if ($script:hasErrors) { exit 1 } else { exit 0 }
