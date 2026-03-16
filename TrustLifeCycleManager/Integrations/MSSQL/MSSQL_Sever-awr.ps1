<#
===============================================================================
LEGAL NOTICE (version October 29, 2024)
===============================================================================
Copyright © 2024 DigiCert. All rights reserved.
DigiCert and its logo are registered trademarks of DigiCert, Inc.
Other names may be trademarks of their respective owners.

For the purposes of this Legal Notice, "DigiCert" refers to:
- DigiCert, Inc., if you are located in the United States;
- DigiCert Ireland Limited, if you are located outside of the United States or Japan;
- DigiCert Japan G.K., if you are located in Japan.

The software described in this notice is provided by DigiCert and distributed under licenses
restricting its use, copying, distribution, and decompilation or reverse engineering.
No part of the software may be reproduced in any form by any means without prior written authorization
of DigiCert and its licensors, if any.

Use of the software is subject to the terms and conditions of your agreement with DigiCert, including
any dispute resolution and applicable law provisions. The terms set out herein are supplemental to
your agreement and, in the event of conflict, these terms control.

THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT,
ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.

Export Regulation: The software and related technical data and services (collectively "Controlled Technology")
are subject to the import and export laws of the United States, specifically the U.S. Export Administration
Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.

US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
===============================================================================
#>

# Legal notice acceptance variable (user must set to $true to accept and allow script execution)
$LEGAL_NOTICE_ACCEPT = $false  # Change this to $true to accept the legal notice and run the script

# Configuration
$logFile = "C:\Program Files\DigiCert\TLM Agent\log\sqlserver_cert.log"

# SQL Server instance registry path
# Adjust for your SQL Server version and instance name:
#   MSSQL15 = SQL Server 2019, MSSQL16 = SQL Server 2022
#   MSSQLSERVER = default instance, replace for named instances
$SqlRegistryPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer\SuperSocketNetLib"

# SQL Server service name (default instance = MSSQLSERVER, named instance = MSSQL$InstanceName)
$SqlServiceName = "MSSQLSERVER"

# SQL Server service account (used for private key read permissions)
$SqlServiceAccount = "NT Service\MSSQLSERVER"

# Function to write to log file
function Write-Log {
    param(
        [string]$Message
    )
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $logMessage
    Write-Host $Message
}

# Function to decode base64 encoded string
function Decode-Base64 {
    param (
        [string]$base64String
    )
    $bytes = [System.Convert]::FromBase64String($base64String)
    $decodedString = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $decodedString
}

Write-Log "Script execution started"

# Check legal notice acceptance
if ($LEGAL_NOTICE_ACCEPT -ne $true) {
    Write-Log "ERROR: Script execution halted - Legal notice not accepted"
    Write-Log "User must set `$LEGAL_NOTICE_ACCEPT = `$true to proceed"
    Write-Log "Script terminated due to legal notice non-acceptance"
    exit 1
}

Write-Log "Legal notice accepted - proceeding with script execution"

try {
    # Base64 encoded JSON input
    $base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
    Write-Log "Retrieved environment variable DC1_POST_SCRIPT_DATA"

    # Decode the base64 encoded JSON
    $jsonString = Decode-Base64 -base64String $base64Json
    Write-Log "Decoded base64 string successfully"

    # Convert JSON string to PowerShell object
    $jsonObject = $jsonString | ConvertFrom-Json
    Write-Log "Converted JSON string to object"

    Write-Log "Arguments: $($jsonObject.args)"

    # Extract values from JSON object
    $certFolder = $jsonObject.certfolder
    $pfxFile = Join-Path -Path $certFolder -ChildPath $jsonObject.files[0]
    $password = $jsonObject.password
    Write-Log "Certificate folder: $certFolder"
    Write-Log "PFX file path: $pfxFile"

    # Validate inputs
    if (-not (Test-Path -Path $pfxFile)) {
        Write-Log "ERROR: The PFX file does not exist at path: $pfxFile"
        exit 1
    }
    Write-Log "PFX file exists"

    # Import the PFX file into the LocalMachine\My store
    try {
        $cert = Import-PfxCertificate -FilePath $pfxFile -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String $password -Force -AsPlainText)
        if ($null -eq $cert) {
            throw "Failed to import the certificate."
        }
        Write-Log "Certificate imported successfully"
        
        # Get the thumbprint from the imported certificate
        $thumbprint = $cert.Thumbprint.ToLower()  # Convert thumbprint to lowercase
        Write-Log "Certificate thumbprint (lowercase): $thumbprint"
        
        # Use certutil to get the unique container name
        Write-Log "Querying certutil for unique container name..."
        $certUtilOutput = certutil -store my $thumbprint
        
        # Parse the certutil output to extract the unique container name
        $uniqueContainerNameLine = $certUtilOutput | Where-Object { $_ -match "Unique container name:" }
        if ($uniqueContainerNameLine) {
            $uniqueContainerName = ($uniqueContainerNameLine -split "Unique container name: ")[1].Trim()
            Write-Log "Unique container name: $uniqueContainerName"
            
            # Construct the path to the key file
            $keyFilePath = Join-Path -Path "C:\ProgramData\Microsoft\Crypto\Keys" -ChildPath $uniqueContainerName
            
            if (Test-Path -Path $keyFilePath) {
                Write-Log "Key file found at: $keyFilePath"
                
                # Add read permissions for the SQL Server service account
                Write-Log "Granting read permissions to $SqlServiceAccount on private key file..."
                $acl = Get-Acl -Path $keyFilePath
                $accessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($SqlServiceAccount, "Read", "Allow")
                $acl.AddAccessRule($accessRule)
                Set-Acl -Path $keyFilePath -AclObject $acl
                
                Write-Log "Read permissions added for $SqlServiceAccount to the key file"
                
                # Configure SQL Server to use the certificate for encryption via Registry
                Write-Log "Configuring SQL Server to use the certificate for encryption via registry..."
                
                try {
                    # Set the certificate thumbprint in the registry
                    if (Test-Path -Path $SqlRegistryPath) {
                        Set-ItemProperty -Path $SqlRegistryPath -Name "Certificate" -Value $thumbprint
                        Write-Log "Successfully configured SQL Server registry with thumbprint: $thumbprint"
                        
                        # Restart SQL Server service to apply changes
                        Write-Log "Restarting $SqlServiceName service to apply changes..."
                        Restart-Service -Name $SqlServiceName -Force
                        Write-Log "$SqlServiceName service restarted successfully"
                    } else {
                        Write-Log "ERROR: Registry path '$SqlRegistryPath' does not exist"
                        Write-Log "Verify the SQL Server version and instance name in the configuration"
                        exit 1
                    }
                }
                catch {
                    Write-Log "ERROR: Failed to configure SQL Server via registry. $_"
                    exit 1
                }
            } else {
                Write-Log "ERROR: Key file not found at expected location: $keyFilePath"
                exit 1
            }
        } else {
            Write-Log "ERROR: Could not find unique container name in certutil output"
            exit 1
        }
    } catch {
        Write-Log "ERROR: Failed to process the certificate. $_"
        exit 1
    }

} catch {
    Write-Log "CRITICAL ERROR: $_"
    Write-Log "Script execution failed"
    exit 1
}

Write-Log "Script execution completed successfully"