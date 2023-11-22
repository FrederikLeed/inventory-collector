# Function to log messages
function Write-Log {
    param (
        [string]$Message,
        [string]$LogFilePath
    )
    # Add timestamp to each log entry
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')): $Message" | Out-File -FilePath $LogFilePath -Append
}

# Define the remote computer name and the task properties
$RemoteComputer = "RemoteComputerName"
[string]$RemoteComputer = $env:computerName  #Remove after testing

$TaskName = "GetInventoryTask"
$ScriptPath = '-file "\\DESKTOP-8Q45UIR\InventoryData\GetInventory.ps1"'

# Create a task principal for "NT Authority\System"
$Principal = New-ScheduledTaskPrincipal -UserId "NT Authority\System" -LogonType ServiceAccount

# Set Action
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $ScriptPath

# Set Trigger defintion
$Trigger = New-ScheduledTaskTrigger -Daily -At "3:00 AM" # Adjust the time as needed

# Establish a remote session to the target computer
$Session = New-PSSession -ComputerName $RemoteComputer -Credential (Get-Credential)

# Check if the task already exists
$TaskExists = Invoke-Command -Session $Session -ScriptBlock {
    Get-ScheduledTask -TaskName $using:TaskName -ErrorAction SilentlyContinue
}
$TaskExists = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue

# Register the scheduled task remotely
if ($TaskExists) {
    # Update the existing task
    #Invoke-Command -Session $Session -ScriptBlock {
        #Set-ScheduledTask -TaskName $using:TaskName -Action $using:Action -Trigger $using:Trigger -Principal $using:Principal
        Set-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal
    #}
    #Write-Log "Scheduled task updated on $RemoteComputer."
} else {
    # Register the task if it doesn't exist
    #Invoke-Command -Session $Session -ScriptBlock {
        #Register-ScheduledTask -TaskName $using:TaskName -Action $using:Action -Trigger $using:Trigger -Principal $using:Principal
        Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal
    #}
    #Write-Log "Scheduled task created on $RemoteComputer."
}