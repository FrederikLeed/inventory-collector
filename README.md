# Computer Inventory PowerShell Script

This PowerShell script is designed to remotely collect various system and software-related information from one or more computers and create an inventory report in JSON format. It can also zip and move the collected data to a central fileshare location for further analysis.

## Features

- Collects the following metrics:
  - Group members of specified groups.
  - Basic system information such as OS version, CPU, RAM, etc.
  - Disk space information for each drive.
  - List of installed software.
  - Information about personal certificates in the LocalMachine\My certificate store.
  - AutoRun application information.
  - Share access information on the target computer.

- The script can be run on multiple remote computers simultaneously.

- Supports customization of the metrics to query and the target computer name.

- Logs errors and information to log files for troubleshooting.

## Usage

1. Run the script. Using favorite #deployment-methods The specified metrics will be collected and saved in JSON format in separate folders.

2. The collected data is then zipped, and the final zip file is moved to a central fileshare location. #setup-central-fileshare

3. Then, when all data is collected. #parse-computer-inventory-powershell-script-collected-data

## Setup Central Fileshare

### Folder and File Share Setup Script

Create a fileshare on a fileserver that can be access by the computers intended to run the script. You can create the share using the "NewCentralFileShare.ps1" script

#### Overview

This script is designed to set up a folder structure and configure sharing and NTFS permissions for inventory data management. It automates the creation of a main folder and a subfolder, shares the main folder with specific access rights, and sets NTFS permissions for domain computers and administrators.

#### Features

- **Folder Creation**: Automatically creates a main folder and a subfolder if they do not already exist.
- **SMB Sharing**: Shares the main folder on the network with 'Change' permissions, allowing specified users to write to it.
- **NTFS Permission Configuration**: Sets specific NTFS permissions on both the main folder and subfolder for different user groups.

#### Script Details

1. **Folder Paths**:
   - `$FolderPath`: Specifies the path for the main folder.
   - `$SubFolderPath`: Specifies the path for the subfolder within the main folder.
2. **Share Setup**:
   - `$ShareName`: The name under which the folder will be shared on the network.
   - The script shares the main folder with 'Change' permission for 'Everyone'.
3. **NTFS Permissions**:
   - The script sets specific NTFS permissions for 'Domain Computers' and 'Everyone' groups, ensuring controlled access to the folders.
   - Additional permissions are set for 'Administrators' and 'SYSTEM', granting them full control over both folders.
   - The script allows customization of inheritance and specific rights through the `Set-NTFSPermissions` function.

#### Example

To use this script:

1. Set the `$FolderPath`, `$SubFolderPath`, and `$ShareName` variables as required.
2. Run the script. It will create the necessary folders, share the main folder, and set the appropriate NTFS permissions.

### Azure Blob Storage with SMB access

TO DO !!

## Deployment methods

### 1. Group Policy with scheduled task

You can import the sample GPO provided in this repo. "Device - Deploy Inventory Collector" just remember to change the path where the script is located

![Alt text](image.png)

### 2. Defender For Endpoit Live Response Integration

It is possible to use the Script in combination with the Defender For Endpoint Live Repsonse. Make sure that Live Response is setup  (See DOCS). Since my script is usigned a setting change must be made to able to run the script.

There is a blog article available that explains more about how to leverage Custom Script in Live Response: [Incident Response Part 3: Leveraging Live Response](https://kqlquery.com/posts/leveraging-live-response/)

To run unsigned scripts live Response:

- Security.microsoft.com
- Settings
- Endpoints
- Advanced Features
- Make sure that Live Response is enabled
- If you want to run this on a server enable live resonse for servers
- Enable Live Response unsigened script execution

Execute script:

- Go to the device page
- Initiate Live Response session
- Upload File to library to upload script
- After uploading the script to the library, use the ***run*** command to run the script

### 3. Other

Script deployment methods using deploymentsoftware like ConfigMGR or others

## Parse Computer Inventory PowerShell Script collected data

## Description

`ParseInventory.ps1` is a PowerShell script designed to parse and aggregate inventory data collected from multiple servers. The script processes a collection of zipped files, each containing JSON files with different system metrics. The aggregated data is then outputted into separate JSON files, one for each type of metric.

## Functionality

- **Dynamic Parsing**: Automatically handles any JSON files found within nested zip archives, without the need for predefined metrics.
- **Flexible Aggregation**: Aggregates data based on the dynamically determined metric names derived from folder names.
- **Error Handling**: Includes error handling to capture and report issues during processing.

## Execution instructions

1. **Set Parameters**: Modify the script parameters to specify the paths:
    - `$fileSharePath`: The path to the fileshare containing the zip files.
    - `$extractPath`: A temporary path for extracting the contents of the zip files.
    - `$aggregateOutputPath`: The path where the aggregated JSON files will be saved.

2. **Run the Script**: Execute the script in PowerShell. It will process each zip file, extract the contents, and aggregate the data into separate JSON files.

3. **Check Results**: After the script execution, check the `$aggregateOutputPath` for the aggregated JSON files.

## Output

The script outputs aggregated JSON files, each named after a specific metric (e.g., `SystemInfo.json`). These files contain combined data from all processed servers for that particular metric.
