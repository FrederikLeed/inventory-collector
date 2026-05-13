<#
.SYNOPSIS
    Runs every Test-*.ps1 in this folder and returns a combined exit code.

.DESCRIPTION
    Iterates each Test-*.ps1 in alphabetical order, invokes it, and reports
    the per-suite exit code plus a combined summary. Exits 0 if all suites
    exit 0, otherwise exits 1.

    Pass -SampleDataPath through to suites that accept it (the integration
    test does; the unit test ignores it).

.EXAMPLE
    .\Run-AllTests.ps1
    .\Run-AllTests.ps1 -SampleDataPath C:\temp\inventoryparsed
#>
param(
    [string]$SampleDataPath
)

$ErrorActionPreference = 'Continue'
$tests = Get-ChildItem -Path $PSScriptRoot -Filter 'Test-*.ps1' | Sort-Object Name

$results = @()
foreach ($t in $tests) {
    Write-Host ""
    Write-Host ("##### {0} #####" -f $t.Name) -ForegroundColor Magenta
    Write-Host ""

    $args = @{}
    # Forward -SampleDataPath only to suites that declare it
    $hasSampleParam = (Get-Command $t.FullName).Parameters.ContainsKey('SampleDataPath')
    if ($hasSampleParam -and $SampleDataPath) {
        $args['SampleDataPath'] = $SampleDataPath
    }

    & $t.FullName @args
    $results += [pscustomobject]@{
        Suite    = $t.Name
        ExitCode = $LASTEXITCODE
    }
}

Write-Host ""
Write-Host "##### Combined summary #####" -ForegroundColor Magenta
$results | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.ExitCode -ne 0 }).Count
if ($failed -gt 0) {
    Write-Host ("FAILED: {0} suite(s) returned non-zero" -f $failed) -ForegroundColor Red
    exit 1
} else {
    Write-Host "OK: all suites passed" -ForegroundColor Green
    exit 0
}
