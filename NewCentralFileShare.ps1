# Define the folder path, share name, and subfolder path
$FolderPath = "F:\InventoryData"
$SubFolderPath = "F:\InventoryData\script"  # Define the subfolder path
$ShareName = "Inventory"
$Domain = Get-ADDomain
$DomainComputers = ($Domain.NetBIOSName) + "\Domain Computers"
$Everyone = "Everyone"

# Create the folder if it doesn't exist
if (!(Test-Path -Path $FolderPath)) {
    New-Item -Path $FolderPath -ItemType Directory
    Write-Host "Folder created at $FolderPath"
} else {
    Write-Host "Folder already exists at $FolderPath"
}

# Create the subfolder if it doesn't exist
if (!(Test-Path -Path $SubFolderPath)) {
    New-Item -Path $SubFolderPath -ItemType Directory
    Write-Host "Subfolder created at $SubFolderPath"
} else {
    Write-Host "Subfolder already exists at $SubFolderPath"
}

# Share the folder with 'Change' permission which includes write access
$SMBShareParams = @{
    Name        = $ShareName
    Path        = $FolderPath
    Description = "Shared folder for domain computers with specific access"
    ChangeAccess = $Everyone
}
New-SmbShare @SMBShareParams
Write-Host "Folder shared as $ShareName"

# Function to set NTFS permissions
function Set-NTFSPermissions {
    param (
        [string]$Path,
        [string]$IdentityReference,
        [string]$FileSystemRights,
        [bool]$IsInheritanceEnabled = $true
    )

    $ACL = Get-Acl $Path
    $ACL.SetAccessRuleProtection(!$IsInheritanceEnabled, $false)  # Break or keep inheritance

    $AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $IdentityReference, 
        $FileSystemRights, 
        "ContainerInherit, ObjectInherit", 
        "None", 
        "Allow"
    )
    $ACL.AddAccessRule($AccessRule)

    Set-Acl -Path $Path -AclObject $ACL
    Write-Host "NTFS permissions set for $IdentityReference on $Path"
}

# Set NTFS permissions for the main folder and the subfolder
Set-NTFSPermissions -Path $FolderPath -IdentityReference $DomainComputers -FileSystemRights "Write, CreateFiles, CreateDirectories, Delete, ReadAttributes, ReadPermissions, ListDirectory, Synchronize" -IsInheritanceEnabled $false
Set-NTFSPermissions -Path $SubFolderPath -IdentityReference $DomainComputers -FileSystemRights "ReadAndExecute, ReadAttributes, ReadPermissions, ListDirectory, Synchronize" -IsInheritanceEnabled $false

# Set full control for Administrators and SYSTEM on both folders
Set-NTFSPermissions -Path $FolderPath -IdentityReference "Administrators" -FileSystemRights "FullControl" -IsInheritanceEnabled $false
Set-NTFSPermissions -Path $SubFolderPath -IdentityReference "Administrators" -FileSystemRights "FullControl" -IsInheritanceEnabled $false
Set-NTFSPermissions -Path $FolderPath -IdentityReference "SYSTEM" -FileSystemRights "FullControl" -IsInheritanceEnabled $false
Set-NTFSPermissions -Path $SubFolderPath -IdentityReference "SYSTEM" -FileSystemRights "FullControl" -IsInheritanceEnabled $false

Write-Host "File share setup complete"
