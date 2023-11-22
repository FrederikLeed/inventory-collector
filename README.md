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

1. Customize the script by modifying the following parameters:
   - `$ComputerName`: Set the target remote computer name (default is the local computer).
   - `$metrics`: Define the metrics you want to query.

2. Define the base folder paths for storing collected data and the final zip file path.

3. Run the script. The specified metrics will be collected and saved in JSON format in separate folders.

4. The collected data is then zipped, and the final zip file is moved to a central fileshare location defined by `$centralFilesharePath`.

## Prerequisites

- PowerShell remoting must be enabled on the target remote computers.

- Appropriate permissions are required on the remote computers to query the specified metrics.

- Ensure that the file share paths for storing data and the central fileshare location are accessible and writable.

## License

This script is provided under the [MIT License](LICENSE).
