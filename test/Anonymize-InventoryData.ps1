<#
.SYNOPSIS
    Anonymizes inventory JSON files so they can be safely shared as test fixtures.

.DESCRIPTION
    Walks every JSON file in -SourcePath, builds deterministic maps for
    identifying values (computer names, user names, group names, domains),
    then writes anonymized copies to -DestinationPath. Same input value
    always maps to the same output value so cross-file relationships
    (e.g. ComputerName joins between SystemInfo and InstalledSoftware) are
    preserved.

    Files listed in -SkipFiles are dropped entirely (default: Invoice.json,
    customer financial data).

    Large arrays are trimmed to -MaxRowsPerFile rows up front to keep the
    fixture size reasonable. Set to 0 for no trimming.

    Run under PowerShell 7 (pwsh) when possible — its ConvertFrom-Json is
    roughly 10x faster than Windows PowerShell 5.1 on large inputs.

.EXAMPLE
    pwsh -File .\Anonymize-InventoryData.ps1 `
         -SourcePath      c:\temp\inventoryparsed `
         -DestinationPath c:\temp\anon-out
#>
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$DestinationPath,
    [string[]]$SkipFiles = @('Invoice'),
    [int]$MaxRowsPerFile = 5000,
    [string]$FakeDomain = 'example.local'
)

$ErrorActionPreference = 'Stop'

# Property-name -> category. PowerShell hashtables are case-insensitive.
$Rules = @{
    'ComputerName'      = 'Computer'
    'MachineName'       = 'Computer'

    'UserName'          = 'User'
    'User'              = 'User'
    'Owner'             = 'User'
    'Principal'         = 'User'
    'StartName'         = 'User'
    'Ejer'              = 'User'

    'GroupName'         = 'Group'

    'Members'           = 'UserArray'
    'GroupMembers'      = 'UserArray'
    'GroupMemberships'  = 'GroupArray'

    'Domain'            = 'Domain'
    'DomainOrWorkgroup' = 'Domain'
    'DomainName'        = 'Domain'
}

$script:maps = @{
    Computer = @{}
    User     = @{}
    Group    = @{}
    Domain   = @{}
}
$script:counters = @{ Computer = 0; User = 0; Group = 0; Domain = 0 }

# Reserved values that must NEVER enter the substitution map. These are
# standard Windows identifiers that appear inside paths, SDDL strings, and
# group lists; replacing them via substring sweep would corrupt the document
# (e.g. C:\Users\... -> C:\group0004\...).
$script:reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    'Users', 'Administrators', 'Guests', 'Power Users',
    'Authenticated Users', 'Everyone', 'CREATOR OWNER', 'CREATOR GROUP',
    'NT AUTHORITY', 'BUILTIN', 'INTERACTIVE', 'NETWORK', 'NT SERVICE',
    'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE',
    'Domain Users', 'Domain Admins', 'Domain Computers',
    'Domain Controllers', 'Domain Guests',
    'Enterprise Admins', 'Schema Admins', 'Cert Publishers',
    'Remote Desktop Users', 'Remote Management Users',
    'Performance Log Users', 'Performance Monitor Users',
    'Backup Operators', 'Account Operators', 'Print Operators',
    'Server Operators', 'Replicator', 'Event Log Readers',
    'IIS_IUSRS', 'TrustedInstaller', 'ALL APPLICATION PACKAGES',
    'Hyper-V Administrators', 'Cryptographic Operators',
    'Distributed COM Users', 'Network Configuration Operators',
    'Remote Desktop'
) | ForEach-Object { [void] $script:reserved.Add($_) }

function Test-Trivial {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    if ($Value.Length -lt 4) { return $true }
    if ($Value -notmatch '[A-Za-z0-9]') { return $true }
    if ($script:reserved.Contains($Value)) { return $true }
    return $false
}

function Get-AnonValue {
    param([string]$Type, $Value)
    if ($null -eq $Value) { return $null }
    $raw = [string]$Value
    if (Test-Trivial $raw) { return $raw }

    $key = $raw.ToLowerInvariant()
    if (-not $script:maps[$Type].ContainsKey($key)) {
        $script:counters[$Type]++
        $i = $script:counters[$Type]
        $script:maps[$Type][$key] = switch ($Type) {
            'Computer' { "CMP{0:D4}" -f $i }
            'User'     { "user{0:D4}" -f $i }
            'Group'    { "group{0:D4}" -f $i }
            'Domain'   { $FakeDomain }
        }
    }
    return $script:maps[$Type][$key]
}

function Invoke-PropertyAnonymization {
    param($Node)
    if ($null -eq $Node) { return $null }

    if ($Node -is [string] -or $Node -is [bool] -or $Node -is [int] -or
        $Node -is [long] -or $Node -is [double] -or $Node -is [decimal] -or
        $Node -is [datetime]) {
        return $Node
    }

    if ($Node -is [System.Collections.IList] -or $Node -is [System.Array]) {
        $out = @()
        foreach ($el in $Node) { $out += , (Invoke-PropertyAnonymization $el) }
        return , $out
    }

    if ($Node -is [PSCustomObject]) {
        $new = [ordered]@{}
        foreach ($prop in $Node.PSObject.Properties) {
            $name = $prop.Name
            $val  = $prop.Value
            if ($Rules.ContainsKey($name)) {
                $type = $Rules[$name]
                switch ($type) {
                    'UserArray' {
                        $arr = @()
                        if ($val -is [System.Array]) {
                            foreach ($u in $val) { $arr += (Get-AnonValue 'User' $u) }
                        } elseif ($null -ne $val) {
                            $arr += (Get-AnonValue 'User' $val)
                        }
                        $new[$name] = $arr
                    }
                    'GroupArray' {
                        $arr = @()
                        if ($val -is [System.Array]) {
                            foreach ($g in $val) { $arr += (Get-AnonValue 'Group' $g) }
                        } elseif ($null -ne $val) {
                            $arr += (Get-AnonValue 'Group' $val)
                        }
                        $new[$name] = $arr
                    }
                    default {
                        if ($val -is [System.Array]) {
                            $arr = @()
                            foreach ($v in $val) { $arr += (Get-AnonValue $type $v) }
                            $new[$name] = $arr
                        } else {
                            $new[$name] = Get-AnonValue $type $val
                        }
                    }
                }
            } else {
                $new[$name] = Invoke-PropertyAnonymization $val
            }
        }
        return [PSCustomObject]$new
    }

    return $Node
}

function Read-AndTrim {
    param([string]$Path)
    $data = Get-Content $Path -Raw | ConvertFrom-Json
    if ($MaxRowsPerFile -gt 0 -and $data -is [System.Array] -and $data.Count -gt $MaxRowsPerFile) {
        return ,@($data[0..($MaxRowsPerFile - 1)])
    }
    return $data
}

$files = Get-ChildItem -Path $SourcePath -Filter '*.json' | Where-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name) -notin $SkipFiles
}

# Cache trimmed objects from Pass 1 so we don't ConvertFrom-Json twice.
$trimmed = @{}

# Pass 1 — collect identifying values.
Write-Host ("Pass 1: collecting identifying values from {0} files (MaxRowsPerFile={1}) ..." -f $files.Count, $MaxRowsPerFile)
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($f in $files) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $data = Read-AndTrim -Path $f.FullName
    [void] (Invoke-PropertyAnonymization $data)
    $trimmed[$f.Name] = $data
    $sw.Stop()
    $count = if ($data -is [System.Array]) { $data.Count } else { 1 }
    Write-Host ("  [{0,5:N0}ms] {1}  ({2:N0} rows)" -f $sw.ElapsedMilliseconds, $f.Name, $count)
}
Write-Host ("  Computers : {0}" -f $script:maps.Computer.Count)
Write-Host ("  Users     : {0}" -f $script:maps.User.Count)
Write-Host ("  Groups    : {0}" -f $script:maps.Group.Count)
Write-Host ("  Domains   : {0}" -f $script:maps.Domain.Count)

# Build a single combined regex for the Pass 2 substring sweep.
$lookup = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($cat in 'Computer','User','Group','Domain') {
    foreach ($k in $script:maps[$cat].Keys) {
        if ($k.Length -ge 5) {
            $lookup[$k] = $script:maps[$cat][$k]
        }
    }
}
$alternation = ($lookup.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
$combinedRegex = $null
if ($alternation) {
    $combinedRegex = [regex]::new($alternation, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

# Pass 2 — write output, with property-level + single-regex substring substitution.
Write-Host ""
Write-Host "Pass 2: writing anonymized files to $DestinationPath ..."
if (-not (Test-Path $DestinationPath)) {
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
}

foreach ($f in $files) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $data = $trimmed[$f.Name]
    $anon = Invoke-PropertyAnonymization $data
    $json = $anon | ConvertTo-Json -Depth 20

    if ($combinedRegex) {
        $json = $combinedRegex.Replace($json, {
            param($m)
            $out = $null
            if ($lookup.TryGetValue($m.Value, [ref]$out)) { return $out }
            return $m.Value
        })
    }

    # AD DN catchall: collapse DC=foo,DC=bar to DC=example,DC=local
    $json = [regex]::Replace($json, '(?i)(DC=[A-Za-z0-9-]+(,DC=[A-Za-z0-9-]+)+)', 'DC=example,DC=local')

    # IP addresses -> deterministic 10.x.y.z bucket
    $ipMap = @{}
    $ipCounter = 0
    $json = [regex]::Replace($json, '\b(?<!\.)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?!\.)\b', {
        param($m)
        $ip = $m.Value
        if (-not $ipMap.ContainsKey($ip)) {
            $ipCounter++
            $ipMap[$ip] = "10.{0}.{1}.{2}" -f ([math]::Floor($ipCounter / 65025)), ([math]::Floor(($ipCounter / 254)) % 254), (($ipCounter % 254) + 1)
        }
        $ipMap[$ip]
    })

    # Email addresses
    $json = [regex]::Replace($json, '(?i)\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b', "noreply@$FakeDomain")

    $outPath = Join-Path $DestinationPath $f.Name
    $json | Out-File -FilePath $outPath -Encoding UTF8
    $sw.Stop()
    Write-Host ("  [{0,5:N0}ms] {1}" -f $sw.ElapsedMilliseconds, $f.Name)
}

$swTotal.Stop()
Write-Host ""
Write-Host ("Done in {0:N1}s." -f $swTotal.Elapsed.TotalSeconds)
