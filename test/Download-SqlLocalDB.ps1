<#
.SYNOPSIS
    Downloads the SQL Server LocalDB installer.

.DESCRIPTION
    LocalDB is the lightweight, embeddable SQL Server engine used by the
    integration tests in this folder. The MSI is ~50 MB so it is fetched on
    demand rather than committed to the repo.

    Default URL points at SQL Server 2019 Express LocalDB. The same MSI works
    on all supported Windows client/server SKUs and is sufficient for the
    integration tests here. If Microsoft moves the file, override -Url with
    the current link from
    https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/sql-server-express-localdb

.EXAMPLE
    .\Download-SqlLocalDB.ps1
    .\Download-SqlLocalDB.ps1 -Install
    .\Download-SqlLocalDB.ps1 -Url https://...
#>
param(
    [string]$Url = 'https://download.microsoft.com/download/E/A/E/EAE6F7FC-767A-4038-A954-49B8B05D04EB/SqlLocalDB.msi',
    [string]$Destination = (Join-Path -Path $PSScriptRoot -ChildPath 'SqlLocalDB.msi'),
    [switch]$Install
)

$ErrorActionPreference = 'Stop'

if (Test-Path $Destination) {
    Write-Host "Already present: $Destination"
} else {
    Write-Host "Downloading SqlLocalDB.msi to $Destination ..."
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    Write-Host ("  {0:N1} MB downloaded" -f ((Get-Item $Destination).Length / 1MB))
}

if ($Install) {
    Write-Host "Installing (silent, IACCEPTSQLLOCALDBLICENSETERMS=YES) ..."
    $args = @('/i', "`"$Destination`"", '/quiet', '/qn', '/norestart',
              'IACCEPTSQLLOCALDBLICENSETERMS=YES')
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "msiexec exited $($proc.ExitCode)"
    }
    Write-Host "  installed."
    Write-Host ""
    Write-Host "Verify with:  sqllocaldb info"
} else {
    Write-Host ""
    Write-Host "Run with -Install to install silently, or run the MSI manually."
}
