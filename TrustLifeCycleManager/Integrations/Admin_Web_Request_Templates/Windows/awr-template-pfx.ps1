<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (PFX Format) - PowerShell Version
.DESCRIPTION
    PowerShell conversion of the original Bash script for processing certificate data from DigiCert TLM Agent
.NOTES
    Legal Notice (version October 29, 2024)
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
#>

# Configuration
$LEGAL_NOTICE_ACCEPT = "false"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\dc1_data.log"

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)"
Write-LogMessage "=========================================="

# Check legal notice acceptance
Write-LogMessage "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-LogMessage "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
    Write-LogMessage "Script execution terminated due to legal notice non-acceptance."
    Write-LogMessage "=========================================="
    exit 1
} else {
    Write-LogMessage "Legal notice accepted, proceeding with script execution."
}

# Log initial configuration
Write-LogMessage "Configuration:"
Write-LogMessage "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Write-LogMessage "  LOGFILE: $LOGFILE"

# Log environment variable check
Write-LogMessage "Checking DC1_POST_SCRIPT_DATA environment variable..."
$CERT_INFO = $env:DC1_POST_SCRIPT_DATA

if ([string]::IsNullOrEmpty($CERT_INFO)) {
    Write-LogMessage "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
} else {
    Write-LogMessage "DC1_POST_SCRIPT_DATA is set (length: $($CERT_INFO.Length) characters)"
}

# Decode JSON string from Base64
try {
    $JSON_BYTES = [System.Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString($JSON_BYTES)
    Write-LogMessage "JSON_STRING decoded successfully"
} catch {
    Write-LogMessage "ERROR: Failed to decode Base64: $_"
    exit 1
}

# Log the raw JSON for debugging
Write-LogMessage "=========================================="
Write-LogMessage "Raw JSON content:"
Write-LogMessage $JSON_STRING
Write-LogMessage "=========================================="

# Parse JSON
try {
    $JSON_OBJECT = $JSON_STRING | ConvertFrom-Json
    Write-LogMessage "JSON parsed successfully"
} catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Extract arguments from JSON
Write-LogMessage "Extracting arguments from JSON..."

# Initialize argument variables
$ARGUMENT_1 = ""
$ARGUMENT_2 = ""
$ARGUMENT_3 = ""
$ARGUMENT_4 = ""
$ARGUMENT_5 = ""

# Extract arguments if they exist
if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"
    
    if ($ARGS_ARRAY.Count -ge 1) { 
        $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) { 
        $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 3) { 
        $ARGUMENT_3 = ($ARGS_ARRAY[2] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
        Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 4) { 
        $ARGUMENT_4 = ($ARGS_ARRAY[3] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
        Write-LogMessage "ARGUMENT_4 length: $($ARGUMENT_4.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 5) { 
        $ARGUMENT_5 = ($ARGS_ARRAY[4] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_5 extracted: '$ARGUMENT_5'"
        Write-LogMessage "ARGUMENT_5 length: $($ARGUMENT_5.Length)"
    }
}

# Extract cert folder
$CERT_FOLDER = $JSON_OBJECT.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .pfx file name
$PFX_FILE = ""
if ($JSON_OBJECT.files) {
    $PFX_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.pfx$|\.p12$' } | Select-Object -First 1
}
Write-LogMessage "Extracted PFX_FILE: $PFX_FILE"

# Extract the PFX password from JSON
# Check common field names for password
$PFX_PASSWORD = ""
if ($JSON_OBJECT.password) { $PFX_PASSWORD = $JSON_OBJECT.password }
elseif ($JSON_OBJECT.pfx_password) { $PFX_PASSWORD = $JSON_OBJECT.pfx_password }
elseif ($JSON_OBJECT.keystore_password) { $PFX_PASSWORD = $JSON_OBJECT.keystore_password }
elseif ($JSON_OBJECT.passphrase) { $PFX_PASSWORD = $JSON_OBJECT.passphrase }

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "WARNING: No PFX password found in JSON. Checking if password is in arguments..."
    if (-not [string]::IsNullOrEmpty($ARGUMENT_4)) {
        Write-LogMessage "Checking if Argument 4 could be the password..."
    }
    if (-not [string]::IsNullOrEmpty($ARGUMENT_5)) {
        Write-LogMessage "Checking if Argument 5 could be the password..."
    }
} else {
    Write-LogMessage "PFX password extracted from JSON"
    Write-LogMessage "PFX password length: $($PFX_PASSWORD.Length) characters"
    # Log first 3 chars of password for verification (masked for security)
    if ($PFX_PASSWORD.Length -ge 3) {
        $PFX_PASSWORD_MASKED = $PFX_PASSWORD.Substring(0, 3) + "***"
        Write-LogMessage "PFX password (masked): $PFX_PASSWORD_MASKED"
    } else {
        Write-LogMessage "PFX password (masked): ***"
    }
}

# Construct file path
$PFX_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $PFX_FILE

# Extract all files from the files array
$FILES_ARRAY = $JSON_OBJECT.files -join ','
Write-LogMessage "Files array content: $FILES_ARRAY"

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "Arguments extracted:"
Write-LogMessage "  Argument 1: $ARGUMENT_1"
Write-LogMessage "  Argument 2: $ARGUMENT_2"
Write-LogMessage "  Argument 3: $ARGUMENT_3"
Write-LogMessage "  Argument 4: $ARGUMENT_4"
Write-LogMessage "  Argument 5: $ARGUMENT_5"
Write-LogMessage ""
Write-LogMessage "Certificate information:"
Write-LogMessage "  Certificate folder: $CERT_FOLDER"
Write-LogMessage "  PFX file: $PFX_FILE"
Write-LogMessage "  PFX file path: $PFX_FILE_PATH"
if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "  PFX password: Found ($($PFX_PASSWORD.Length) characters)"
} else {
    Write-LogMessage "  PFX password: Not found"
}
Write-LogMessage ""
Write-LogMessage "All files in array: $FILES_ARRAY"
Write-LogMessage "=========================================="

# Check if PFX file exists
if (Test-Path $PFX_FILE_PATH) {
    $pfxFileInfo = Get-Item $PFX_FILE_PATH
    Write-LogMessage "PFX file exists: $PFX_FILE_PATH"
    Write-LogMessage "PFX file size: $($pfxFileInfo.Length) bytes"
    
    # If we have the password, we can try to inspect the PFX contents
    if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) {
        try {
            # Try to load the PFX certificate
            $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
            $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PFX_FILE_PATH, $securePwd)
            
            Write-LogMessage "Successfully accessed PFX file with provided password"
            Write-LogMessage "Certificate subject: $($pfxCert.Subject)"
            Write-LogMessage "Certificate issuer: $($pfxCert.Issuer)"
            Write-LogMessage "Certificate thumbprint: $($pfxCert.Thumbprint)"
            Write-LogMessage "Certificate valid from: $($pfxCert.NotBefore)"
            Write-LogMessage "Certificate valid to: $($pfxCert.NotAfter)"
            
            # Check key algorithm
            $keyAlgorithm = $pfxCert.SignatureAlgorithm.FriendlyName
            Write-LogMessage "Signature algorithm: $keyAlgorithm"
            
            # Check if it has private key
            if ($pfxCert.HasPrivateKey) {
                Write-LogMessage "Certificate has private key: Yes"
                $keyType = $pfxCert.PrivateKey.GetType().Name
                Write-LogMessage "Private key type: $keyType"
            } else {
                Write-LogMessage "Certificate has private key: No"
            }
            
            $pfxCert.Dispose()
        } catch {
            Write-LogMessage "WARNING: Could not access PFX file with provided password: $_"
        }
    } else {
        Write-LogMessage "No password provided, cannot inspect PFX contents"
    }
} else {
    Write-LogMessage "WARNING: PFX file not found: $PFX_FILE_PATH"
}

# Additional check for any certificate-related files
Write-LogMessage "=========================================="
Write-LogMessage "Checking for all certificate-related files in folder..."
if (Test-Path $CERT_FOLDER) {
    $certFiles = Get-ChildItem -Path $CERT_FOLDER -Include "*.pfx", "*.p12", "*.cer", "*.crt", "*.key", "*.pem" -Recurse -ErrorAction SilentlyContinue
    if ($certFiles) {
        Write-LogMessage "Certificate-related files found:"
        foreach ($file in $certFiles) {
            Write-LogMessage "  $($file.Name) - $($file.Length) bytes - $($file.LastWriteTime)"
        }
    } else {
        Write-LogMessage "No certificate files found in folder"
    }
} else {
    Write-LogMessage "Certificate folder does not exist: $CERT_FOLDER"
}

# ============================================================================
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================
#
# Available variables for your custom logic:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $PFX_FILE         - The filename of the PFX/P12 certificate (filename only)
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file (folder + filename)
#   $PFX_PASSWORD     - Password for the PFX/P12 file (if available)
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Argument variables (from JSON args array):
#   $ARGUMENT_1       - First argument from args array (AWR Parameter 1)
#   $ARGUMENT_2       - Second argument from args array (AWR Parameter 2)
#   $ARGUMENT_3       - Third argument from args array (AWR Parameter 3)
#   $ARGUMENT_4       - Fourth argument from args array (AWR Parameter 4)
#   $ARGUMENT_5       - Fifth argument from args array (AWR Parameter 5)
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $JSON_OBJECT      - The parsed JSON object
#   $ARGS_ARRAY       - The args array from JSON object
#
# Utility function:
#   Write-LogMessage "text" - Function to write timestamped messages to log file
#
# Example custom logic:
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section..."
Write-LogMessage "=========================================="

# Example 1: Copy certificate to another location
# if (Test-Path $PFX_FILE_PATH) {
#     $BACKUP_DIR = "C:\Backup\Certificates"
#     if (-not (Test-Path $BACKUP_DIR)) {
#         New-Item -ItemType Directory -Path $BACKUP_DIR -Force | Out-Null
#     }
#     Copy-Item -Path $PFX_FILE_PATH -Destination $BACKUP_DIR -Force
#     Write-LogMessage "Certificate copied to backup location: $BACKUP_DIR"
# }

# Example 2: Import certificate to Windows certificate store
# if (-not [string]::IsNullOrEmpty($PFX_PASSWORD) -and (Test-Path $PFX_FILE_PATH)) {
#     try {
#         $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
#         $pfxCert = Import-PfxCertificate -FilePath $PFX_FILE_PATH -Password $securePwd -CertStoreLocation "Cert:\LocalMachine\My"
#         Write-LogMessage "Certificate imported to Local Machine store. Thumbprint: $($pfxCert.Thumbprint)"
#     } catch {
#         Write-LogMessage "ERROR: Failed to import certificate: $_"
#     }
# }

# Example 3: Extract certificate and key from PFX (requires OpenSSL)
# $opensslPath = "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
# if (-not [string]::IsNullOrEmpty($PFX_PASSWORD) -and (Test-Path $PFX_FILE_PATH) -and (Test-Path $opensslPath)) {
#     # Extract certificate
#     $certOutPath = Join-Path $CERT_FOLDER "server.crt"
#     & $opensslPath pkcs12 -in $PFX_FILE_PATH -passin pass:$PFX_PASSWORD -out $certOutPath -nokeys -clcerts
#     Write-LogMessage "Certificate extracted to: $certOutPath"
#     
#     # Extract private key (unencrypted)
#     $keyOutPath = Join-Path $CERT_FOLDER "server.key"
#     & $opensslPath pkcs12 -in $PFX_FILE_PATH -passin pass:$PFX_PASSWORD -out $keyOutPath -nocerts -nodes
#     Write-LogMessage "Private key extracted to: $keyOutPath"
# }

# Example 4: Restart services based on arguments
# if ($ARGUMENT_1 -eq "restart_iis") {
#     Write-LogMessage "Restarting IIS service as requested..."
#     Restart-Service -Name W3SVC -Force
#     Write-LogMessage "IIS service restarted"
# }

# Example 5: Send notification email
# if (Test-Path $PFX_FILE_PATH) {
#     $NOTIFICATION_EMAIL = $ARGUMENT_2  # Assuming email is in argument 2
#     if (-not [string]::IsNullOrEmpty($NOTIFICATION_EMAIL)) {
#         $subject = "Certificate Deployment Notification"
#         $body = "Certificate deployed: $PFX_FILE at $(Get-Date)"
#         Send-MailMessage -To $NOTIFICATION_EMAIL -From "admin@example.com" -Subject $subject -Body $body -SmtpServer "smtp.example.com"
#         Write-LogMessage "Notification sent to: $NOTIFICATION_EMAIL"
#     }
# }

# Example 6: Update IIS binding with new certificate
# if (-not [string]::IsNullOrEmpty($PFX_PASSWORD) -and (Test-Path $PFX_FILE_PATH)) {
#     Import-Module WebAdministration
#     $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
#     $pfxCert = Import-PfxCertificate -FilePath $PFX_FILE_PATH -Password $securePwd -CertStoreLocation "Cert:\LocalMachine\My"
#     
#     # Update IIS binding for specific site
#     $siteName = "Default Web Site"
#     $binding = Get-WebBinding -Name $siteName -Protocol https
#     if ($binding) {
#         $binding.AddSslCertificate($pfxCert.Thumbprint, "My")
#         Write-LogMessage "Updated SSL certificate for site: $siteName"
#     }
# }

# ADD YOUR CUSTOM LOGIC HERE:
# ----------------------------------------




# ----------------------------------------
# END OF CUSTOM LOGIC

Write-LogMessage "Custom script section completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

exit 0