# Remote Computer Inventory PowerShell Script

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

1. Define the base folder paths for storing collected data and the final zip file path.

2. Run the script. The specified metrics will be collected and saved in JSON format in separate folders.

3. The collected data is then zipped, and the final zip file is moved to a central fileshare location defined by `$centralFilesharePath`.

## Deployment methods

1. Group Policy with scheduled task. You can import the sample GPO provided in this repo. "Device - Deploy Inventory Collector" just remember to change the path where the script is located.

![Alt text](image.png)

2. Defender For Endpoit Live Response Integration

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

3. Other script deployment methods using deploymentsoftware like ConfigMGR etc.

## Prerequisites

- Ensure that the file share paths for storing data and the central fileshare location are accessible and writable.