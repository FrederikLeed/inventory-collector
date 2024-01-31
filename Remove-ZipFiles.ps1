<#
.SYNOPSIS
    Removes all ZIP files from a specified folder.

.DESCRIPTION
    This script is used to delete all ZIP files from a specified directory. 
    It provides an option to specify the directory path as a parameter.

.PARAMETER FolderPath
    The path of the folder from which ZIP files will be removed.

.EXAMPLE
    PS> .\Remove-ZipFiles.ps1 -FolderPath "C:\ExampleDirectory"

.NOTES
    Author: PowerKick
    Version: 1.0
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true, HelpMessage="Enter the path of the folder.")]
    [string]$FolderPath
)

# Function to remove ZIP files
function Remove-ZipFiles {
    param (
        [string]$Path
    )

    try {
        # Get all ZIP files in the specified folder
        $zipFiles = Get-ChildItem -Path $Path -Filter *.zip -Recurse -ErrorAction Stop

        # Check if there are any ZIP files
        if ($zipFiles.Count -eq 0) {
            Write-Host "No ZIP files found in the folder: $Path"
            return
        }

        # Removing ZIP files
        foreach ($file in $zipFiles) {
            Remove-Item $file.FullName -Force
            Write-Host "Removed ZIP file: $($file.FullName)"
        }
    }
    catch {
        Write-Error "An error occurred: $_"
    }
}

# Executing the function
Remove-ZipFiles -Path $FolderPath
