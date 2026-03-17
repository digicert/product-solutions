<#
===============================================================================
Legal Notice (version January 1, 2026)
===============================================================================
Copyright © 2026 DigiCert. All rights reserved.
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

# Function to write to log file
function Write-Log {
    param(
        [string]$Message
    )
    $logMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $Message"
    Add-Content -Path $logFile -Value $logMessage
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

# Set up logging
$logFile = "C:\CertificateImport.log"
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
        throw "The PFX file does not exist."
    }
    Write-Log "PFX file exists"

    # Get certificate thumbprint and store it in a text file
    try {
        $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
        
        # First validate if we can read the password
        Write-Log "Attempting to verify password..."
        $securePassword = ConvertTo-SecureString -String $password -Force -AsPlainText
        
        # Add password debugging information
        Write-Log "Password length: $($password.Length)"
        Write-Log "First character of password: $($password[0])"
        Write-Log "Password value (first 2 chars): $($password.Substring(0, [Math]::Min(2, $password.Length)))"
        
        # Try to import with more detailed error handling
        try {
            $pfxCert.Import($pfxFile, $password, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        }
        catch [System.Security.Cryptography.CryptographicException] {
            Write-Log "ERROR: Invalid password or corrupted PFX file. Please verify the password is correct."
            throw "Invalid certificate password or corrupted PFX file."
        }
        
        $thumbprint = $pfxCert.Thumbprint
        Write-Log "Retrieved certificate thumbprint: $thumbprint"
        
        # Create thumbprint file in the same folder as the certificate
        $thumbprintFile = Join-Path -Path $certFolder -ChildPath "certificate_thumbprint.txt"
        $thumbprint | Out-File -FilePath $thumbprintFile -Force
        Write-Log "Saved thumbprint to file: $thumbprintFile"
        
        # Dispose of the certificate object
        $pfxCert.Dispose()
        Write-Log "Disposed certificate object"
    } catch {
        Write-Log "ERROR: Failed to get certificate thumbprint. Error: $_"
        throw $_
    }

    # Import the PFX file into the LocalMachine\My store
    try {
        $cert = Import-PfxCertificate -FilePath $pfxFile -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String $password -Force -AsPlainText)
        if ($null -eq $cert) {
            Write-Log "ERROR: Failed to import the certificate"
            throw "Failed to import the certificate."
        }
        Write-Log "Certificate imported successfully"
    } catch {
        Write-Log "ERROR: Failed to import the certificate. Error: $_"
        throw $_
    }

    # Step 2: Grant access to the private key to NETWORK SERVICE using certutil
    Write-Log "Attempting to repair certificate store for thumbprint: $thumbprint"
    $certutilCommand = "certutil -repairstore my $thumbprint"
    try {
        Start-Process cmd.exe -ArgumentList "/c $certutilCommand" -Wait -NoNewWindow
        Write-Log "Successfully ran certutil repair command"
    } catch {
        Write-Log "ERROR: Failed to run certutil command. Error: $_"
        throw $_
    }

    # Step 3: Use WMI to set the RDP listener certificate
    try {
        $tsConfig = Get-WmiObject -Namespace "Root\CIMv2\TerminalServices" -Class Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'"
        
        if ($tsConfig) {
            # Use reflection to set the SSLThumbprint
            $tsConfig.PSBase.Properties["SSLCertificateSHA1Hash"].Value = $thumbprint
            $tsConfig.Put()
            Write-Log "Successfully updated certificate thumbprint via WMI"
        } else {
            Write-Log "ERROR: Failed to retrieve the TS configuration"
            throw "Failed to retrieve the TS configuration"
        }
    } catch {
        Write-Log "ERROR: Failed to set certificate thumbprint via WMI. Error: $_"
        throw $_
    }

    # Step 4: Restart the RDP service to apply changes
    try {
        Restart-Service -Name "TermService" -Force
        Write-Log "Successfully restarted the Terminal Services service"
    } catch {
        Write-Log "ERROR: Failed to restart Terminal Services. Error: $_"
        throw $_
    }

} catch {
    Write-Log "CRITICAL ERROR: $_"
    Write-Log "Script execution failed"
    exit 1
}

Write-Log "Script execution completed successfully"