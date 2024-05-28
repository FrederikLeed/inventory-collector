<#
.SYNOPSIS
A PowerShell framework for executing a series of scripts specified in an XML file named 'config.xml' located in the same directory as the script, executed in a predetermined order with dynamic parameter passing, logging, and error handling.

.DESCRIPTION
This script provides a robust framework for scheduling and executing multiple PowerShell scripts based on an external XML configuration file named 'config.xml'. It supports passing custom parameters to each script and enhances execution with detailed logging and comprehensive error handling. The framework ensures continued execution even if individual scripts fail, making it ideal for complex automation tasks.

.EXAMPLE
# Example usage of the script
.\Path\To\Your\Script.ps1

This command executes the script using 'config.xml' located in the same directory as the script file. Ensure 'config.xml' is properly formatted.

.NOTES
- Ensure the PowerShell execution policy allows for script execution.
- Review and secure 'config.xml' to prevent unauthorized script execution.
- The log file is automatically generated in the same directory as this script with the name "ExecutionLog.log".

#>

# Determine the path of the script and define paths for the XML configuration and log file
$scriptDir = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
$xmlFilePath = Join-Path -Path $scriptDir -ChildPath "config.xml"
$logFilePath = Join-Path -Path $scriptDir -ChildPath "ExecutionLog.log"

# Function to log messages to a file
function Write-Log {
    param(
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -FilePath $logFilePath -Append
}

# Function to execute a script with parameters, including error handling
function Invoke-ScriptWithParameters {
    param(
        [string]$scriptPath,
        [hashtable]$parameters
    )
    try {
        # Build the argument list for the script
        $argumentList = @()
        foreach ($key in $parameters.Keys) {
            $argumentList += "-$key"
            $argumentList += $parameters[$key]
        }

        # Attempt to execute the script with parameters
        Write-Log "Starting script: $scriptPath with parameters: $($parameters.GetEnumerator() | Out-String)"
        & PowerShell.exe -File $scriptPath @argumentList
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-Log "Completed script: $scriptPath successfully"
            return $true
        } else {
            Write-Log "ERROR: Script $scriptPath failed with exit code $exitCode"
            return $false
        }
    } catch {
        # Log any exceptions that occur
        Write-Log "ERROR: An error occurred while executing $scriptPath. Error: $_"
        return $false
    }
}


# Load the XML file
[xml]$scriptsConfig = Get-Content -Path $xmlFilePath

# Iterate over each script defined in the XML and execute them with error handling
foreach ($script in $scriptsConfig.Scripts.Script) {
    $scriptPath = $script.Path
    $parameters = @{}

    # Extract parameters for the script
    foreach ($param in $script.Parameters.Parameter) {
        $parameters[$param.Name] = $param.Value
    }

    # Invoke the script with parameters and error handling
    $result = Invoke-ScriptWithParameters -scriptPath $scriptPath -parameters $parameters
    if (-not $result) {
        Write-Log "ERROR: Execution halted due to failure in script: $scriptPath"
        break
    }
}
