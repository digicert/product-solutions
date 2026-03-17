<# 
Legal Notice (version January 1, 2026) 
Copyright © 2026 DigiCert. All rights reserved. 
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

# Set up logging (moved to top)
$logFile = "C:\Program Files\DigiCert\TLM Agent\log\rdp.log"

# Legal notice acceptance variable
$legal_notice_accept = $false  # Set to true to accept and execute script, false to deny

# Configuration variables for certificate installation
$Install_RDP_Listener_Certificate = $false  # Set to $true to configure RDP listener certificate
$Install_RDS_Publishing_Certificate = $false  # Set to $true to install RD Connection Broker Publishing certificate
$Install_RDS_WebAccess_Certificate = $false  # Set to $true to install RD Web Access certificate
$RDS_Connection_Broker_FQDN = "rdp.rds.local"  # Replace with your RD Connection Broker FQDN

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

Write-Log "Script execution started"

# Check legal notice acceptance
if ($legal_notice_accept -eq $false) {
    Write-Log "Legal notice acceptance is set to false - script execution denied"
    Write-Log "Script execution stopped - legal notice not accepted"
    exit 0
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
        $pfxCert.Import($pfxFile, $password, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet)
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
    
    # Check if all certificate installation options are disabled
    if ($Install_RDP_Listener_Certificate -eq $false -and $Install_RDS_Publishing_Certificate -eq $false -and $Install_RDS_WebAccess_Certificate -eq $false) {
        Write-Log "All certificate installation options are set to false"
        Write-Log "Certificate imported to store but no RDP/RDS configuration performed"
        Write-Log "Script execution completed - RDP/RDS configuration skipped"
        exit 0
    }
    
    # Grant access to the private key to NETWORK SERVICE using certutil
    Write-Log "Attempting to repair certificate store for thumbprint: $thumbprint"
    $certutilCommand = "certutil -repairstore my $thumbprint"
    try {
        Start-Process cmd.exe -ArgumentList "/c $certutilCommand" -Wait -NoNewWindow
        Write-Log "Successfully ran certutil repair command"
    } catch {
        Write-Log "ERROR: Failed to run certutil command. Error: $_"
        throw $_
    }
    
    # Configure RDP Listener Certificate if enabled
    if ($Install_RDP_Listener_Certificate -eq $true) {
        Write-Log "Install_RDP_Listener_Certificate is set to true - configuring RDP listener"
        
        try {
            $tsConfig = Get-WmiObject -Namespace "Root\CIMv2\TerminalServices" -Class Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'"
            
            if ($tsConfig) {
                # Use reflection to set the SSLThumbprint
                $tsConfig.PSBase.Properties["SSLCertificateSHA1Hash"].Value = $thumbprint
                $tsConfig.Put()
                Write-Log "Successfully updated RDP listener certificate thumbprint via WMI"
            } else {
                Write-Log "ERROR: Failed to retrieve the TS configuration"
                throw "Failed to retrieve the TS configuration"
            }
        } catch {
            Write-Log "ERROR: Failed to set RDP listener certificate thumbprint via WMI. Error: $_"
            throw $_
        }
        
        # Restart the RDP service to apply changes
        try {
            Restart-Service -Name "TermService" -Force
            Write-Log "Successfully restarted the Terminal Services service"
        } catch {
            Write-Log "ERROR: Failed to restart Terminal Services. Error: $_"
            throw $_
        }
    } else {
        Write-Log "Install_RDP_Listener_Certificate is set to false - skipping RDP listener configuration"
    }
    
    # Configure RDS Publishing Certificate if enabled
    if ($Install_RDS_Publishing_Certificate -eq $true) {
        Write-Log "Install_RDS_Publishing_Certificate is set to true - configuring RDS Publishing certificate"
        
        # Check if RDS PowerShell module is available
        try {
            Import-Module RemoteDesktop -ErrorAction Stop
            Write-Log "Successfully imported RemoteDesktop module"
        } catch {
            Write-Log "ERROR: RemoteDesktop module not available. Is RDS installed on this server?"
            Write-Log "Skipping RDS Publishing certificate configuration"
            # Continue without throwing error as this might be a standalone server
        }
        
        # Attempt to set RDS Publishing certificate
        if (Get-Module -Name RemoteDesktop) {
            try {
                # Set the RD Connection Broker Publishing certificate
                Set-RDCertificate -Role RDPublishing -Thumbprint $thumbprint -ConnectionBroker $RDS_Connection_Broker_FQDN -Force
                Write-Log "Successfully set RD Connection Broker Publishing certificate"
                
                # Verify the certificate was applied
                $verifyPublishing = Get-RDCertificate -Role RDPublishing -ConnectionBroker $RDS_Connection_Broker_FQDN
                if ($verifyPublishing.Thumbprint -eq $thumbprint) {
                    Write-Log "Verified RD Publishing certificate is correctly applied"
                } else {
                    Write-Log "WARNING: RD Publishing certificate thumbprint mismatch after setting"
                }
            } catch {
                Write-Log "ERROR: Failed to set RD Publishing certificate. Error: $_"
                Write-Log "This may occur if the server is not part of an RDS deployment"
                # Continue without throwing - this is not a critical error for standalone servers
            }
        }
    } else {
        Write-Log "Install_RDS_Publishing_Certificate is set to false - skipping RDS Publishing configuration"
    }
    
    # Configure RDS Web Access Certificate if enabled
    if ($Install_RDS_WebAccess_Certificate -eq $true) {
        Write-Log "Install_RDS_WebAccess_Certificate is set to true - configuring RDS Web Access certificate"
        
        # Check if RDS PowerShell module is available
        try {
            Import-Module RemoteDesktop -ErrorAction Stop
            Write-Log "Successfully imported RemoteDesktop module for Web Access configuration"
        } catch {
            Write-Log "ERROR: RemoteDesktop module not available. Is RDS installed on this server?"
            Write-Log "Skipping RDS Web Access certificate configuration"
            # Continue without throwing error as this might be a standalone server
        }
        
        # Attempt to set RDS Web Access certificate
        if (Get-Module -Name RemoteDesktop) {
            try {
                # Set the RD Web Access certificate
                Set-RDCertificate -Role RDWebAccess -Thumbprint $thumbprint -ConnectionBroker $RDS_Connection_Broker_FQDN -Force
                Write-Log "Successfully set RD Web Access certificate"
                
                # Verify the certificate was applied
                $verifyWebAccess = Get-RDCertificate -Role RDWebAccess -ConnectionBroker $RDS_Connection_Broker_FQDN
                if ($verifyWebAccess.Thumbprint -eq $thumbprint) {
                    Write-Log "Verified RD Web Access certificate is correctly applied"
                } else {
                    Write-Log "WARNING: RD Web Access certificate thumbprint mismatch after setting"
                }
                
                # Note: RD Web Access also typically requires IIS certificate binding update
                Write-Log "Note: You may also need to update the IIS HTTPS binding for RD Web Access site"
                
            } catch {
                Write-Log "ERROR: Failed to set RD Web Access certificate. Error: $_"
                Write-Log "This may occur if the server is not part of an RDS deployment or RD Web Access role is not installed"
                # Continue without throwing - this is not a critical error for standalone servers
            }
        }
    } else {
        Write-Log "Install_RDS_WebAccess_Certificate is set to false - skipping RDS Web Access configuration"
    }
    
} catch {
    Write-Log "CRITICAL ERROR: $_"
    Write-Log "Script execution failed"
    exit 1
}

Write-Log "Script execution completed successfully"