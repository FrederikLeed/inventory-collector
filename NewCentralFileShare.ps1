# PowerShell Script to Create a File Share with List, Write, and Check File Presence Access for Domain Computers

# Define the folder path and share name
$FolderPath = "C:\SharedFolder"
$ShareName = "SharedData"
$Domain = Get-ADDomain
$DomainComputers = ($Domain.NetBIOSName) + "\Domain Computers"

# Create the folder if it doesn't exist
if (!(Test-Path -Path $FolderPath)) {
    New-Item -Path $FolderPath -ItemType Directory
    Write-Host "Folder created at $FolderPath"
} else {
    Write-Host "Folder already exists at $FolderPath"
}

# Share the folder with 'Change' permission which includes write access
$SMBShareParams = @{
    Name        = $ShareName
    Path        = $FolderPath
    Description = "Shared folder for domain computers with specific access"
    ChangeAccess = $DomainComputers
}
New-SmbShare @SMBShareParams
Write-Host "Folder shared as $ShareName"

# Set NTFS permissions to allow listing, writing, and checking file presence but not reading file content
$ACL = Get-Acl $FolderPath
$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $DomainComputers, 
    "Write, CreateFiles, CreateDirectories, Delete, ReadAttributes, ReadPermissions, ListDirectory, Synchronize", 
    "ContainerInherit, ObjectInherit", 
    "None", 
    "Allow"
)
$ACL.AddAccessRule($AccessRule)
Set-Acl -Path $FolderPath -AclObject $ACL
Write-Host "NTFS permissions set for domain computers with specific access requirements"

Write-Host "File share setup complete"
