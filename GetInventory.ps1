# Define parameters for the computer name
param(
    [string]$ComputerName = $env:computerName,
    [string]$centralFilesharePath = "\\server\InventoryData"    
)

# Set the metrics to query
$metrics = @"
GroupMembers
LocalUsers
SystemInfo
DiskSpace
InstalledSoftware
PersonalCertificates
AutoRunInfo
ShareAccessInfo
UserProfileList
Services
InstalledUpdates
ScheduledTasks
"@

# Split the string into an array by line breaks
[array]$metrics = $metrics.Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)
# Define base folder paths
$baseFolderPath = $env:SystemDrive + "\Inv" + (New-Guid).ToString().Substring(0,8)
$zipFolderPath = ($baseFolderPath + "\Zipped")

# Final zip file path
$finalZipFile = Join-Path -Path $zipFolderPath -ChildPath "$ComputerName.zip"
$destinationZipFile = Join-Path -Path $centralFilesharePath -ChildPath "$ComputerName.zip"

# Check if the destination zip file already exists
if (Test-Path $destinationZipFile) {
    #Write-Host "The file '$destinationZipFile' already exists. Exiting script."
    exit
}

# Ensure the base and zip folder paths exist
if (-not (Test-Path $baseFolderPath)) {
    New-Item -Path $baseFolderPath -ItemType Directory
}
if (-not (Test-Path $zipFolderPath)) {
    New-Item -Path $zipFolderPath -ItemType Directory
}

# Function to log messages
function Write-Log {
    param (
        [string]$Message,
        [string]$LogFilePath
    )
    # Add timestamp to each log entry
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')): $Message" | Out-File -FilePath $LogFilePath -Append
}

# Function to collect group members
function Get-GroupMembers {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )
    # Group name definitions
    $groups = "Administrators", "Remote Desktop Users"

    # Initialize an array to hold the output data
    $groupMembersData = @()

    try {
        # Initialize ADSI connection
        $adsi = [ADSI]"WinNT://$ComputerName"

        foreach ($group in $groups) {
            # Attempt to retrieve the group object
            $groupObject = $adsi.Children | Where-Object { $_.SchemaClassName -eq 'group' -and $_.Name -eq $group }

            if ($groupObject) {
                # Retrieve group members
                $members = @($groupObject.Invoke("Members")) | ForEach-Object {
                    $adsPath = $_.GetType().InvokeMember("ADsPath", 'GetProperty', $null, $_, $null)
                    $adsPath.Replace("WinNT://", "")
                }
                #Write-Log "Group '$group' members collected on $ComputerName" $LogFilePath
            } else {
                #Write-Log "Group '$group' not found on $ComputerName" $LogFilePath
                $members = @()
            }

            # Add the data to the output array
            $groupMembersData += [PSCustomObject] @{
                ComputerName = $ComputerName
                GroupName = $group
                Members = $members
            }
        }
    } catch {
        # Log and rethrow any exceptions
        Write-Log "Error encountered in Get-GroupMembers: $_" $LogFilePath
        throw $_
    }

    # Return the collected data
    return $groupMembersData
}

# Function to collect local users and their group memberships along with password last set and last logon date
function Get-LocalUserGroupMemberships {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Initialize ADSI connection
        $adsi = [ADSI]"WinNT://$ComputerName"

        # Retrieve all user accounts
        $users = $adsi.Children | Where-Object { $_.SchemaClassName -eq 'user' }

        # Initialize an array to hold output data
        $userData = @()

        foreach ($user in $users) {
            # Initialize an array to hold user's group memberships
            $groupMemberships = @()

            # Retrieve all groups
            $groups = $adsi.Children | Where-Object { $_.SchemaClassName -eq 'group' }
            foreach ($group in $groups) {
                # Check if the user is a member of the group
                $isMember = $group.Invoke("IsMember", $user.Path)
                if ($isMember) {
                    $groupMemberships += $group.Name
                }
            }

            # Retrieve user's password last set and last logon date using Win32_UserAccount and Win32_NetworkLoginProfile
            $LocalUserAccount = Try{ Get-LocalUser $($user.Name)}catch{Write-Log "Get-LocalUser failed" $LogFilePath}

            $passwordLastSet = if ($LocalUserAccount) { $LocalUserAccount.PasswordLastSet } else { $null }
            $lastLogonDate   = if ($LocalUserAccount) { $LocalUserAccount.LastLogon } else { $null }
            $Enabled         = if ($LocalUserAccount) { $LocalUserAccount.Enabled } else { $null }
            $Description     = if ($LocalUserAccount) { $LocalUserAccount.Description } else { $null }
            $PasswordExpires = if ($LocalUserAccount) { $LocalUserAccount.PasswordExpires } else { $null }

            # Add the user data with group memberships, password last set, and last logon date to the output array
            $userData += [PSCustomObject] @{
                ComputerName      = $ComputerName
                UserName          = $user.Name
                Description       = $Description
                GroupMemberships  = $groupMemberships
                PasswordLastSet   = $passwordLastSet
                PasswordExpires   = $PasswordExpires
                LastLogonDate     = $lastLogonDate
                Enabled           = $Enabled
            }
        }

        # Log operation success
        Write-Log "Local users and their group memberships collected from $ComputerName" $LogFilePath
    } catch {
        # Log and rethrow any exceptions
        Write-Log "Error encountered in Get-LocalUserGroupMemberships: $_" $LogFilePath
        throw $_
    }

    # Return the collected data
    return $userData
}

# Function to collect system information
function Get-SystemInfo {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Collecting basic system information
        $osInfo = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName
        $cpuInfo = (Get-WmiObject -Class Win32_Processor -ComputerName $ComputerName | Measure-Object -Property NumberOfCores -Sum).Sum
        $ramInfo = Get-WmiObject -Class Win32_PhysicalMemory -ComputerName $ComputerName
        $compSysInfo = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $ComputerName

        # Determining if the computer is domain-joined or in a workgroup
        if ($compSysInfo.PartOfDomain) {
            $domainInfo = $compSysInfo.Domain
        } else {
            $domainInfo = $compSysInfo.Workgroup
        }
        

        # Calculating total RAM
        $totalRam = ($ramInfo | Measure-Object -Property Capacity -Sum).Sum / 1GB
        $lastbootuptime = ($osInfo | Select-Object @{LABEL='LastBootUpTime';EXPRESSION={$_.ConverttoDateTime($_.lastbootuptime)}}).lastbootuptime
        # Creating custom object to hold system information
        $systemInfo = [PSCustomObject]@{
            ComputerName = $ComputerName
            OSVersion = $osInfo.Caption
            ServicePack = $osInfo.ServicePackMajorVersion
            lastbootuptime = $lastbootuptime
            CPU = $cpuInfo
            TotalRAM_GB = [Math]::Round($totalRam, 2)
            DomainOrWorkgroup = $domainInfo
        }

        # Logging success
        Write-Log "Successfully retrieved system information for $ComputerName" $LogFilePath

        # Returning the collected data
        return $systemInfo
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-SystemInfo: $_" $LogFilePath
        throw $_
    }
}

# Function to collect disk space information
function Get-DiskSpace {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Collecting disk space information
        $diskInfo = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $ComputerName -Filter "DriveType=3"

        # Creating an array to hold disk space details for each drive
        $disks = foreach ($disk in $diskInfo) {
            # Calculating the free space percentage
            $freeSpacePercentage = if ($disk.Size -gt 0) {
                [Math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
            } else {
                0
            }

            [PSCustomObject]@{
                ComputerName = $ComputerName
                Drive = $disk.DeviceID
                TotalSize_GB = [Math]::Round($disk.Size / 1GB, 2)
                FreeSpace_GB = [Math]::Round($disk.FreeSpace / 1GB, 2)
                FreeSpace_Percentage = $freeSpacePercentage
                FileSystem = $disk.FileSystem
            }
        }

        # Logging success
        Write-Log "Successfully retrieved disk space information for $ComputerName" $LogFilePath

        # Returning the collected data
        return $disks
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-DiskSpace: $_" $LogFilePath
        throw $_
    }
}

# Function to collect installed software information
function Get-InstalledSoftware {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Registry paths to query for installed software
        $registryPaths = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" # for 64-bit systems
        )

        # Function to parse InstallDate string to DateTime object
        function Convert-ToDate {
            param([string]$InstallDate)

            if ($InstallDate -match '^\d{8}$') {
                # Return the date in yyyy-MM-dd format
                return [datetime]::ParseExact($InstallDate, 'yyyyMMdd', $null).ToString('yyyy-MM-dd')
            }
            return $null
        }

        # Creating an array to hold software information
        $softwareList = @()

        # Collecting installed software information
        foreach ($path in $registryPaths) {
            $softwareEntries = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                Where-Object { $null -ne $_.DisplayName }
            
            foreach ($entry in $softwareEntries) {
                # Constructing a PSCustomObject for each software entry
                $software = [PSCustomObject]@{
                    ComputerName   = $ComputerName
                    DisplayName    = $entry.DisplayName
                    DisplayVersion = $entry.DisplayVersion
                    InstallDate    = Convert-ToDate $entry.InstallDate
                    Publisher      = $entry.Publisher
                }

                # Adding the object to the array
                $softwareList += $software
            }
        }

        # Logging success
        Write-Log "Successfully retrieved installed software information for $ComputerName" $LogFilePath

        # Returning the collected data
        return $softwareList
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-InstalledSoftware: $_" $LogFilePath
        throw $_
    }
}

# Function to collect installed updates information
function Get-InstalledUpdates {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Creating a COM object to interact with Windows Update Agent
        $updateSession = New-Object -ComObject Microsoft.Update.Session
        $updateSearcher = $updateSession.CreateUpdateSearcher()

        # Getting the count of installed updates
        $updatesCount = $updateSearcher.GetTotalHistoryCount()

        # Retrieving installed updates
        $updates = $updateSearcher.QueryHistory(0, $updatesCount)

        # Collecting information about each update
        $installedUpdates = foreach ($update in $updates) {
            if ($update.Title) {
                # Formatting the Date to match UpdateTimeStamp
                $formattedDate = $update.Date.ToString("yyyy-MM-dd HH:mm:ss")

                [PSCustomObject]@{
                    ComputerName     = $ComputerName
                    Date             = $formattedDate
                    Title            = $update.Title
                    ServiceID        = $update.ServiceID
                }
            }
        }

        # Logging success
        Write-Log "Successfully retrieved installed updates information for $ComputerName" $LogFilePath

        # Returning the collected data
        return $installedUpdates
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-InstalledUpdates: $_" $LogFilePath
        throw $_
    }
}

# Function to get information about installed certificates
function Get-PersonalCertificates {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Define the certificate path for the Personal store
        $certPath = "Cert:\LocalMachine\My"

        # Collecting certificate information
        $certificates = Get-ChildItem -Path $certPath -ErrorAction Stop |
            Select-Object @{Name='ComputerName'; Expression={$ComputerName}}, 
                          Subject, NotBefore, NotAfter, Issuer, Thumbprint, 
                          HasPrivateKey, 
                          @{Name='Subject Alternative Name'; Expression={
                              if ($_.DnsNameList) {
                                  ($_.DnsNameList -join ', ')
                              } else {
                                  'N/A'
                              }
                          }}
        # Logging success
        Write-Log "Successfully retrieved certificate information from the Personal store for $ComputerName" $LogFilePath

        # Returning the collected data
        return $certificates
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-PersonalCertificates: $_" $LogFilePath
        throw $_
    }
}

# Function to get information about user profiles
function Get-UserProfileList {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Define the profile path for users
        $ProfilePath = ($env:SystemDrive + "\Users")

        # Collecting user profile information
        $UserProfiles = Get-ChildItem -Path $ProfilePath -Directory -ErrorAction Stop |
            Select-Object @{Name='ComputerName'; Expression={$ComputerName}}, 
                          Name, CreationTime, LastWriteTime, FullName, 
                          @{Name='UserProfileSizeMB'; Expression={
                              (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum /1Mb
                          }}

        # Logging success
        Write-Log "Successfully retrieved user profile information for $ComputerName" $LogFilePath

        # Returning the collected data
        return $UserProfiles
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-UserProfileList: $_" $LogFilePath
        throw $_
    }
}

# Function to get information about services
function Get-Services {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Collecting service information
        $Services = Get-WmiObject "Win32_Service" -ErrorAction Stop |
            Where-Object {$_.StartName -and $_.StartName -notmatch "LocalSystem|LocalService|NetworkService|NT Service"} |
            Select-Object @{Name='ComputerName'; Expression={$ComputerName}},
                          DisplayName, Name, State, StartMode, StartName, Description

        # Logging success
        Write-Log "Successfully retrieved services information for $ComputerName" $LogFilePath

        # Returning the collected data
        return $Services
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-Services: $_" $LogFilePath
        throw $_
    }
}

# Function to get information about scheduled tasks
function Get-ScheduledTasks {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Retrieving all scheduled tasks from the specified computer
        $allTasks = Get-ScheduledTask # -CimSession $ComputerName

        # Filtering out tasks running as SYSTEM, LOCAL SERVICE, or NETWORK SERVICE
        $nonSystemTasks = $allTasks | Where-Object { $_.Principal.UserId -notmatch 'SYSTEM|LOCAL SERVICE|NETWORK SERVICE' -and $_.Principal.UserId }

        # Creating custom objects for each task
        $customTasksInfo = foreach ($task in $nonSystemTasks) {
            # Formatting trigger details
            $triggerDescriptions = $task.Triggers | ForEach-Object {
                $triggerDetails = $_.PSBase.CimClass.CimClassName
                $startBoundary = $_.StartBoundary
                $endBoundary = $_.EndBoundary
                $daysInterval = $_.DaysInterval
                
                switch ($triggerDetails) {
                    'MSFT_TaskTimeTrigger' { "One time, Starts: $startBoundary" }
                    'MSFT_TaskDailyTrigger' { "Daily, Starts: $startBoundary, Ends: $endBoundary, Interval: $daysInterval day(s)" }
                    'MSFT_TaskWeeklyTrigger' { "Weekly, Starts: $startBoundary, Ends: $endBoundary" }
                    'MSFT_TaskMonthlyTrigger' { "Monthly, Starts: $startBoundary, Ends: $endBoundary" }
                    default { "Unknown Trigger Type" }
                }
            }

            $formattedTriggers = $triggerDescriptions -join '; '

            # Getting action details
            $actions = ($task.Actions | ForEach-Object { $_.Execute + ' ' + $_.Arguments }) -join ', '
            $TaskInfo = $task | Get-ScheduledTaskInfo

            [PSCustomObject]@{
                ComputerName   = $ComputerName
                TaskName       = $task.TaskName
                TaskPath       = $task.TaskPath
                LastRunTime    = $TaskInfo.LastRunTime
                NextRunTime    = $TaskInfo.NextRunTime
                LastTaskResult = $TaskInfo.LastTaskResult
                Principal      = $task.Principal.UserId
                LogonType      = $task.Principal.LogonType
                RunLevel       = $task.Principal.RunLevel
                Schedule       = $formattedTriggers
                Action         = $actions
            }
        }

        # Logging success
        Write-Log "Successfully retrieved non-system scheduled tasks for $ComputerName" $LogFilePath

        # Returning the collected data
        return $customTasksInfo
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-NonSystemScheduledTasks: $_" $LogFilePath
        throw $_
    }
}

# Function to get information about AutoRun applications
function Get-AutoRunInfo {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Collect AutoRun information
        $autoRunData = Get-CimInstance Win32_StartupCommand |
        Select-Object @{Name='ComputerName'; Expression={$ComputerName}},
                      Name, Command, Location, @{Name='UserName'; Expression={$_.User}}

        # Returning the collected data
        $autoRunData | ForEach-Object {
            Write-Log "Successfully collected AutoRun information for $($_.Name) on $ComputerName" $LogFilePath
            $_
        }
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-AutoRunInfo: $_" $LogFilePath
        throw $_
    }
}


# Function to get informatil about fileshares
function Get-ShareAccessInfo {
    param(
        [string]$ComputerName,
        [string]$LogFilePath
    )

    try {
        # Collecting share information and excluding specific system shares
        $excludedShares = "ADMIN$", "C$", "D$", "E$", "F$", "IPC$"
        $shares = Get-WmiObject -Class Win32_Share -ComputerName $ComputerName |
                  Where-Object { $excludedShares -notcontains $_.Name }

        # Collecting share access information
        $shareAccessInfo = foreach ($share in $shares) {
            # Getting NTFS permissions
            $ntfsAccessList = Get-Acl -Path $share.Path | Select-Object -ExpandProperty Access

            # Formatting NTFS access list entries
            $formattedNTFSAccessList = $ntfsAccessList | ForEach-Object {
                [PSCustomObject]@{
                    AccessTo = $_.IdentityReference.ToString()
                    AccessRights = $_.FileSystemRights.ToString()
                    AccessType = $_.AccessControlType.ToString()
                    PermissionType = "NTFS"
                }
            }

            # Getting SMB permissions if available
            $smbAccessList = @()
            if (Get-Command "Get-SmbShareAccess" -ErrorAction SilentlyContinue) {
                $smbAccessList = Get-SmbShareAccess -Name $share.Name -ErrorAction SilentlyContinue |
                                 Select-Object -Property AccountName, AccessRight | ForEach-Object {
                    [PSCustomObject]@{
                        AccessTo = $_.AccountName
                        AccessRights = $_.AccessRight
                        AccessType = "Allow" # SMB shares typically only list allowed access
                        PermissionType = "SMB"
                    }
                }
            }

            # Creating custom object for each share
            [PSCustomObject]@{
                ComputerName = $ComputerName
                ShareName = $share.Name
                SharePath = $share.Path
                NTFSAccessList = $formattedNTFSAccessList
                SMBAccessList = $smbAccessList
            }
        }

        # Logging success
        Write-Log "Successfully retrieved share access information for $ComputerName" $LogFilePath

        # Returning the collected data
        return $shareAccessInfo
    } catch {
        # Logging errors
        Write-Log "Error encountered in Get-ShareAccessInfo: $_" $LogFilePath
        throw $_
    }
}

function Get-SecurityLogEvent4624Summary {
    param (
        [string]$ComputerName,    
        [datetime]$StartDate = (Get-Date).AddDays(-1),  # Start date set to 24 hours ago by default
        [datetime]$EndDate = (Get-Date)                # End date set to current date by default
    )

    # Define the logon type mapping
    $logonTypeMap = @{
        2 = "Interactive (Logon locally)"
        3 = "Network"
        4 = "Batch"
        5 = "Service"
        7 = "Unlock"
        8 = "NetworkCleartext"
        9 = "NewCredentials"
        10 = "RemoteInteractive"
        11 = "CachedInteractive"
    }

    try {
        # Construct the filter XML query
        $filterXml = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">
      *[System[(EventID=4624)]]
    </Select>
  </Query>
</QueryList>
"@

        # Retrieve events using Get-WinEvent with the filter on the specified computer
        $events = Get-WinEvent -ComputerName $ComputerName -FilterXml $filterXml

        # Filter events within the specified time range
        $events = $events | Where-Object { $_.TimeCreated -ge $StartDate -and $_.TimeCreated -le $EndDate }

        # Initialize the collection of parsed events
        $parsedEvents = @()

        foreach ($event in $events) {
            # Parse the XML of the event
            $xml = [xml]$event.ToXml()
            $eventDataNode = $xml.Event.EventData

            # Extract the relevant data
            $logonTypeString = $eventDataNode.Data | Where-Object { $_.Name -eq 'LogonType' } | Select-Object -ExpandProperty '#text'
            $logonType = [int]$logonTypeString

            $parsedEvent = [PSCustomObject]@{
                ComputerName        = $ComputerName
                TargetUserName      = $eventDataNode.Data | Where-Object { $_.Name -eq 'TargetUserName' } | Select-Object -ExpandProperty '#text'
                TargetDomainName    = $eventDataNode.Data | Where-Object { $_.Name -eq 'TargetDomainName' } | Select-Object -ExpandProperty '#text'
                LogonType           = $logonTypeString
                IpAddress           = $eventDataNode.Data | Where-Object { $_.Name -eq 'IpAddress' } | Select-Object -ExpandProperty '#text'
                LogonTypeName       = $logonTypeMap[$logonType]
                TimeCreated         = $event.TimeCreated
            }

            # Add parsed event to the collection
            $parsedEvents += $parsedEvent
        }

        # Group and summarize the parsed events
        $summary = $parsedEvents |
            Group-Object ComputerName, TargetUserName, TargetDomainName, LogonType, IpAddress, LogonTypeName |
            Select-Object @{Name='ComputerName';Expression={$_.Group[0].ComputerName}},
                          @{Name='TargetUserName';Expression={$_.Group[0].TargetUserName}},
                          @{Name='TargetDomainName';Expression={$_.Group[0].TargetDomainName}},
                          @{Name='LogonType';Expression={$_.Group[0].LogonType}},
                          @{Name='IpAddress';Expression={$_.Group[0].IpAddress}},
                          @{Name='LogonTypeName';Expression={$_.Group[0].LogonTypeName}},
                          @{Name='Count';Expression={$_.Count}},
                          @{Name='LatestLogonTimeStamp';Expression={$_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1 -ExpandProperty TimeCreated}}

        # Return the summary
        return $summary
    }
    catch {
        Write-Error "An error occurred while retrieving or summarizing the security log events: $_"
    }
}

# Function to export data to JSON
function Export-ToJson {
    param($Data, $FilePath)
    $Data | ConvertTo-Json -Depth 100 | Out-File -FilePath $FilePath
}

# Main script block for querying metrics
$scriptBlock = {
    param($metrics, $ComputerName, $baseFolderPath, $zipFolderPath)

    foreach ($metric in $metrics) {
        # Define file paths
        $folderPath = Join-Path -Path $baseFolderPath -ChildPath $metric
        $OutputFilePath = Join-Path -Path $folderPath -ChildPath "$metric_$ComputerName.json"
        $LogFilePath = Join-Path -Path $folderPath -ChildPath "$metric_$ComputerName.log"

        # Ensure folder exists
        if (-not (Test-Path $folderPath)) {
            New-Item -Path $folderPath -ItemType Directory
        }

        # Call respective function based on metric
        switch ($metric) {
            "GroupMembers" { $data = Get-GroupMembers -groups $groups -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "LocalUsers" { $data = Get-LocalUserGroupMemberships -groups $groups -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "SystemInfo" { $data = Get-SystemInfo -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "DiskSpace" { $data = Get-DiskSpace -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "InstalledSoftware" { $data = Get-InstalledSoftware -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "PersonalCertificates" { $data = Get-PersonalCertificates -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "AutoRunInfo" { $data = Get-AutoRunInfo -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "ShareAccessInfo" { $data = Get-ShareAccessInfo -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "UserProfileList" { $data = Get-UserProfileList -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "Services" { $data = Get-Services -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "InstalledUpdates" { $data = Get-InstalledUpdates -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "ScheduledTasks" { $data = Get-ScheduledTasks -ComputerName $ComputerName -LogFilePath $LogFilePath }
            "SecurityLogEvent4624Summary" { $data = Get-SecurityLogEvent4624Summary -ComputerName $ComputerName -LogFilePath $LogFilePath }            
        }

        # Export data to JSON
        Export-ToJson -Data $data -FilePath $OutputFilePath
    }

    # Ensure that the zip folder path is clear
    Get-ChildItem -Path $zipFolderPath | Remove-Item -Force

    # Zip each metric folder individually and then combine them
    Get-ChildItem -Path $baseFolderPath -Directory | Where-Object { $_.Name -ne "Zipped" } | ForEach-Object {
        $metricZipPath = Join-Path -Path $zipFolderPath -ChildPath "$($_.Name).zip"
        Compress-Archive -Path $_.FullName -DestinationPath $metricZipPath
    }

    # Combine all individual zips into one
    $finalZipFile = Join-Path -Path $zipFolderPath -ChildPath "$ComputerName.zip"
    Compress-Archive -Path (Get-ChildItem -Path $zipFolderPath -File).FullName -DestinationPath $finalZipFile

    # Move the combined zip file to a central fileshare location
    Move-Item -Path $finalZipFile -Destination $centralFilesharePath

    # Cleanup: Delete the entire base folder after moving the zip file
    Remove-Item -Path $baseFolderPath -Recurse -Force
}

# Invoke the script block
Invoke-Command -ScriptBlock $scriptBlock -ArgumentList $metrics, $ComputerName, $baseFolderPath, $zipFolderPath