<# 
Legal Notice (version October 29, 2024) 
Copyright © 2024 DigiCert. All rights reserved. 
DigiCert and its logo are registered trademarks of DigiCert, Inc. 
Other names may be trademarks of their respective owners. 
For the purposes of this Legal Notice, "DigiCert" refers to:
- DigiCert, Inc., if you are located in the United States;
- DigiCert Ireland Limited, if you are located outside of the United States or Japan;
- DigiCert Japan G.K., if you are located in Japan.
The software described in this notice is provided by DigiCert and distributed under licenses restricting its use, copying, distribution, and decompilation or reverse engineering. No part of the software may be reproduced in any form by any means without prior written authorization of DigiCert and its licensors, if any. 
Use of the software is subject to the terms and conditions of your agreement with DigiCert, including any dispute resolution and applicable law provisions. The terms set out herein are supplemental to your agreement and, in the event of conflict, these terms control.
THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES, INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT, ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.
Export Regulation: The software and related technical data and services (collectively "Controlled Technology") are subject to the import and export laws of the United States, specifically the U.S. Export Administration Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported. 
US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19, as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations. 
The contractor/manufacturer is DIGICERT, INC.
#>

# Legal notice acceptance variable
$legal_notice_accept = $false  # Set to true to accept and execute script, false to deny

# Configuration variables for Exchange certificate services
$Enable_POP_Service = $false   # Set to $true to enable certificate for POP3 service
$Enable_IMAP_Service = $false  # Set to $true to enable certificate for IMAP4 service
$Enable_IIS_Service = $false   # Set to $true to enable certificate for IIS (OWA, ECP, EWS, etc.)
$Enable_SMTP_Service = $false  # Set to $true to enable certificate for SMTP service

# Create log function (main script - used for all logging except the temporary Exchange shell script)
function Log-Message {
    param (
        [string]$message,
        [string]$logFilePath = "C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp : $message"
    Add-Content -Path $logFilePath -Value $logEntry
    Write-Host $message
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

Log-Message "Script execution started"

# Check legal notice acceptance
if ($legal_notice_accept -eq $false) {
    Log-Message "Legal notice acceptance is set to false - script execution denied"
    Log-Message "Script execution stopped - legal notice not accepted"
    exit 0
}

Log-Message "Legal notice accepted - proceeding with script execution"

try {
    # Base64 encoded JSON input
    $base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
    
    # Decode the base64 encoded JSON
    $jsonString = Decode-Base64 -base64String $base64Json
    Log-Message "Decoded JSON: $jsonString"
    
    # Convert JSON string to PowerShell object
    $jsonObject = $jsonString | ConvertFrom-Json
    Log-Message "Arguments: $($jsonObject.args)"
    
    # Extract values from JSON object
    $certFolder = $jsonObject.certfolder
    $pfxFile = Join-Path -Path $certFolder -ChildPath $jsonObject.files[0]
    $password = $jsonObject.password
    
    # Validate inputs
    if (-not (Test-Path -Path $pfxFile)) {
        Log-Message "ERROR: The PFX file $pfxFile does not exist."
        exit 1
    }
    
    # Import the PFX file into the LocalMachine\My store
    try {
        $cert = Import-PfxCertificate -FilePath $pfxFile -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String $password -Force -AsPlainText)
        if ($null -eq $cert) {
            throw "Failed to import the certificate."
        }
        
        # Extract the thumbprint of the imported certificate
        $thumbprint = $cert.Thumbprint
        Log-Message "Certificate imported successfully. Thumbprint: $thumbprint"
        
    } catch {
        Log-Message "ERROR: Failed to import the certificate. $_"
        exit 1
    }
    
    # Load Exchange Management Shell and run the Enable-ExchangeCertificate command
    try {
        # Build the services list based on configuration variables
        $servicesList = @()
        if ($Enable_POP_Service -eq $true) { $servicesList += "POP" }
        if ($Enable_IMAP_Service -eq $true) { $servicesList += "IMAP" }
        if ($Enable_IIS_Service -eq $true) { $servicesList += "IIS" }
        if ($Enable_SMTP_Service -eq $true) { $servicesList += "SMTP" }
        
        # Check if at least one service is enabled
        if ($servicesList.Count -eq 0) {
            Log-Message "WARNING: No Exchange services are enabled for certificate deployment."
            Log-Message "Certificate imported to store but not enabled for any Exchange services."
            Log-Message "To enable services, set the corresponding variables to `$true:"
            Log-Message "  - `$Enable_POP_Service for POP3"
            Log-Message "  - `$Enable_IMAP_Service for IMAP4"
            Log-Message "  - `$Enable_IIS_Service for IIS (OWA, ECP, EWS)"
            Log-Message "  - `$Enable_SMTP_Service for SMTP"
            Log-Message "Script execution completed - No Exchange services configured"
            exit 0
        }
        
        # Convert array to comma-separated string
        $servicesString = $servicesList -join ","
        Log-Message "Enabling certificate for Exchange services: $servicesString"
        
        # Since we're having issues with loading the Exchange Management Shell directly,
        # let's create a script that will run in a new PowerShell process with the Exchange shell loaded
        
        $tempScriptPath = Join-Path $env:TEMP "EnableExchangeCert_$([Guid]::NewGuid().ToString()).ps1"
        
        # Create the content for the temporary script
        $scriptContent = @"
# Log function for the temporary script (required as this runs in a separate process)
function Log-Message {
    param (
        [string]`$message,
        [string]`$logFilePath = "C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log"
    )
    `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    `$logEntry = "`$timestamp : `$message"
    Add-Content -Path `$logFilePath -Value `$logEntry
    Write-Host `$message
}

try {
    # Add Exchange snapin
    Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
    Log-Message "Exchange Management Shell snapin loaded successfully."
    
    # Set error action preference to stop so that non-terminating errors will be treated as terminating
    `$ErrorActionPreference = 'Stop'
    
    # Capture the output to check for errors
    `$result = Enable-ExchangeCertificate -Thumbprint "$thumbprint" -Services $servicesString -Confirm:`$false -ErrorAction Stop
    
    # If we get here, the command was successful
    Log-Message "Enabled Exchange Certificate with thumbprint: $thumbprint for services: $servicesString"
    exit 0
} catch {
    # Log the detailed error
    Log-Message "ERROR in Enable-ExchangeCertificate: `$_"
    
    # Check if the error is related to unsupported key algorithm
    if (`$_.Exception.Message -like "*KeyAlgorithmUnsupported*") {
        Log-Message "CRITICAL ERROR: The certificate uses an unsupported key algorithm for Exchange Server."
    }
    
    exit 1
}
"@
        
        # Write the script to a temporary file
        Set-Content -Path $tempScriptPath -Value $scriptContent
        Log-Message "Created temporary script at $tempScriptPath"
        
        # Execute the script using the Exchange Management Shell
        $exchangeShellPath = "C:\Program Files\Microsoft\Exchange Server\V15\bin\exshell.psc1"
        
        if (Test-Path $exchangeShellPath) {
            Log-Message "Running command through Exchange Management Shell"
            $process = Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command & {Import-Module '$exchangeShellPath'; & '$tempScriptPath'}" -Wait -PassThru
            
            if ($process.ExitCode -ne 0) {
                throw "The Exchange certificate enabling process failed with exit code $($process.ExitCode)"
            }
        } else {
            # Fallback to direct execution with Exchange snap-in
            Log-Message "Exchange shell configuration not found, trying direct execution"
            $process = Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-File", $tempScriptPath -Wait -PassThru
            
            if ($process.ExitCode -ne 0) {
                throw "The Exchange certificate enabling process failed with exit code $($process.ExitCode)"
            }
        }
        
        Log-Message "Exchange certificate enabling process completed successfully"
        
        # Clean up the temporary script
        Remove-Item -Path $tempScriptPath -Force -ErrorAction SilentlyContinue
        
    } catch {
        Log-Message "ERROR: Failed during the Exchange command execution. $_"
        
        # Clean up the temporary script in case of error
        if (Test-Path $tempScriptPath) {
            Remove-Item -Path $tempScriptPath -Force -ErrorAction SilentlyContinue
        }
        
        exit 1
    }
    
} catch {
    Log-Message "CRITICAL ERROR: $_"
    Log-Message "Script execution failed"
    exit 1
}

Log-Message "Script execution completed successfully"