<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (CRT/KEY Format) - PowerShell Version
.DESCRIPTION
    PowerShell conversion of the original Bash script for processing separate certificate and key files from DigiCert TLM Agent
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
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script"
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

Write-LogMessage "CERT_INFO length: $($CERT_INFO.Length) characters"

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

# Extract the .crt file name
$CRT_FILE = ""
if ($JSON_OBJECT.files) {
    $CRT_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.crt$' } | Select-Object -First 1
}
Write-LogMessage "Extracted CRT_FILE: $CRT_FILE"

# Extract the .key file name
$KEY_FILE = ""
if ($JSON_OBJECT.files) {
    $KEY_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.key$' } | Select-Object -First 1
}
Write-LogMessage "Extracted KEY_FILE: $KEY_FILE"

# Construct file paths
$CRT_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CRT_FILE
$KEY_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $KEY_FILE

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
Write-LogMessage "  Certificate file: $CRT_FILE"
Write-LogMessage "  Private key file: $KEY_FILE"
Write-LogMessage "  Certificate path: $CRT_FILE_PATH"
Write-LogMessage "  Private key path: $KEY_FILE_PATH"
Write-LogMessage ""
Write-LogMessage "All files in array: $FILES_ARRAY"
Write-LogMessage "=========================================="

# Check if files exist and analyze them
$CERT_COUNT = 0
$KEY_TYPE = "Unknown"
$KEY_FILE_CONTENT = ""

if (Test-Path $CRT_FILE_PATH) {
    $crtFileInfo = Get-Item $CRT_FILE_PATH
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    Write-LogMessage "Certificate file size: $($crtFileInfo.Length) bytes"
    
    # Count certificates in the file
    $crtContent = Get-Content $CRT_FILE_PATH -Raw
    $CERT_COUNT = ([regex]::Matches($crtContent, "BEGIN CERTIFICATE")).Count
    Write-LogMessage "Total certificates in file: $CERT_COUNT"
    
    # Try to parse certificate using .NET
    try {
        # Extract just the first certificate if there are multiple
        if ($crtContent -match '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----') {
            $certBase64 = $matches[1] -replace '\s', ''
            $certBytes = [Convert]::FromBase64String($certBase64)
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certBytes)
            
            Write-LogMessage "Certificate details:"
            Write-LogMessage "  Subject: $($cert.Subject)"
            Write-LogMessage "  Issuer: $($cert.Issuer)"
            Write-LogMessage "  Serial Number: $($cert.SerialNumber)"
            Write-LogMessage "  Valid From: $($cert.NotBefore)"
            Write-LogMessage "  Valid To: $($cert.NotAfter)"
            Write-LogMessage "  Thumbprint: $($cert.Thumbprint)"
            Write-LogMessage "  Signature Algorithm: $($cert.SignatureAlgorithm.FriendlyName)"
            
            $cert.Dispose()
        }
    } catch {
        Write-LogMessage "Could not parse certificate details: $_"
    }
} else {
    Write-LogMessage "WARNING: Certificate file not found: $CRT_FILE_PATH"
}

if (Test-Path $KEY_FILE_PATH) {
    $keyFileInfo = Get-Item $KEY_FILE_PATH
    Write-LogMessage "Private key file exists: $KEY_FILE_PATH"
    Write-LogMessage "Private key file size: $($keyFileInfo.Length) bytes"
    
    # Read key file content and determine type
    $KEY_FILE_CONTENT = Get-Content $KEY_FILE_PATH -Raw
    
    if ($KEY_FILE_CONTENT -match "BEGIN RSA PRIVATE KEY") {
        $KEY_TYPE = "RSA"
        Write-LogMessage "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN EC PRIVATE KEY") {
        $KEY_TYPE = "ECC"
        Write-LogMessage "Key type: ECC (BEGIN EC PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN PRIVATE KEY") {
        $KEY_TYPE = "PKCS#8 format (generic)"
        Write-LogMessage "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN ENCRYPTED PRIVATE KEY") {
        $KEY_TYPE = "Encrypted PKCS#8"
        Write-LogMessage "Key type: Encrypted PKCS#8 format (BEGIN ENCRYPTED PRIVATE KEY found)"
    } else {
        $KEY_TYPE = "Unknown"
        Write-LogMessage "Key type: Unknown"
    }
} else {
    Write-LogMessage "WARNING: Private key file not found: $KEY_FILE_PATH"
}

# ============================================================================
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================
#
# Available variables for your custom logic:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $CRT_FILE         - The certificate filename (.crt)
#   $KEY_FILE         - The private key filename (.key)
#   $CRT_FILE_PATH    - Full path to the certificate file
#   $KEY_FILE_PATH    - Full path to the private key file
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Certificate inspection variables (if files exist):
#   $CERT_COUNT       - Number of certificates in the CRT file
#   $KEY_TYPE         - Type of key (RSA, ECC, PKCS#8 format, or Unknown)
#   $KEY_FILE_CONTENT - The full content of the private key file
#
# Argument variables (from JSON args array):
#   $ARGUMENT_1       - First argument from args array
#   $ARGUMENT_2       - Second argument from args array
#   $ARGUMENT_3       - Third argument from args array
#   $ARGUMENT_4       - Fourth argument from args array
#   $ARGUMENT_5       - Fifth argument from args array
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

# Example 1: Copy certificates to IIS directory
# if ((Test-Path $CRT_FILE_PATH) -and (Test-Path $KEY_FILE_PATH)) {
#     $WEB_CERT_DIR = "C:\inetpub\certificates"
#     if (-not (Test-Path $WEB_CERT_DIR)) {
#         New-Item -ItemType Directory -Path $WEB_CERT_DIR -Force | Out-Null
#     }
#     Copy-Item -Path $CRT_FILE_PATH -Destination "$WEB_CERT_DIR\server.crt" -Force
#     Copy-Item -Path $KEY_FILE_PATH -Destination "$WEB_CERT_DIR\server.key" -Force
#     
#     # Set appropriate permissions
#     $acl = Get-Acl "$WEB_CERT_DIR\server.key"
#     $acl.SetAccessRuleProtection($true, $false)
#     $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators", "FullControl", "Allow")
#     $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM", "FullControl", "Allow")
#     $acl.SetAccessRule($adminRule)
#     $acl.SetAccessRule($systemRule)
#     Set-Acl "$WEB_CERT_DIR\server.key" $acl
#     
#     Write-LogMessage "Certificates deployed to web server directory: $WEB_CERT_DIR"
# }

# Example 2: Create PFX/PKCS12 from CRT and KEY using OpenSSL
# $opensslPath = "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
# if ((Test-Path $CRT_FILE_PATH) -and (Test-Path $KEY_FILE_PATH) -and (Test-Path $opensslPath)) {
#     $PFX_PASSWORD = "changeit"
#     $PFX_OUTPUT = Join-Path $CERT_FOLDER "certificate.pfx"
#     
#     $opensslArgs = @(
#         "pkcs12",
#         "-export",
#         "-out", $PFX_OUTPUT,
#         "-inkey", $KEY_FILE_PATH,
#         "-in", $CRT_FILE_PATH,
#         "-passout", "pass:$PFX_PASSWORD"
#     )
#     
#     $process = Start-Process -FilePath $opensslPath -ArgumentList $opensslArgs -Wait -PassThru -NoNewWindow
#     
#     if ($process.ExitCode -eq 0) {
#         Write-LogMessage "PFX file created: $PFX_OUTPUT"
#         
#         # Import to Windows certificate store
#         $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
#         $pfxCert = Import-PfxCertificate -FilePath $PFX_OUTPUT -Password $securePwd -CertStoreLocation "Cert:\LocalMachine\My"
#         Write-LogMessage "Certificate imported to store with thumbprint: $($pfxCert.Thumbprint)"
#     } else {
#         Write-LogMessage "ERROR: Failed to create PFX file"
#     }
# }

# Example 3: Update IIS binding with new certificate (requires PFX conversion first)
# if ((Test-Path $CRT_FILE_PATH) -and (Test-Path $KEY_FILE_PATH)) {
#     Import-Module WebAdministration
#     
#     # First, create PFX and import to store (see Example 2)
#     # Then update IIS binding
#     
#     $siteName = "Default Web Site"
#     $binding = Get-WebBinding -Name $siteName -Protocol https
#     
#     if ($binding -and $pfxCert) {
#         # Remove old binding
#         Remove-WebBinding -Name $siteName -Protocol https -Port 443
#         
#         # Add new binding with certificate
#         New-WebBinding -Name $siteName -Protocol https -Port 443
#         $binding = Get-WebBinding -Name $siteName -Protocol https
#         $binding.AddSslCertificate($pfxCert.Thumbprint, "My")
#         
#         Write-LogMessage "Updated SSL certificate for site: $siteName"
#         
#         # Restart IIS
#         Restart-Service -Name W3SVC -Force
#         Write-LogMessage "IIS service restarted"
#     }
# }

# Example 4: Import to Java keystore (Windows)
# if ((Test-Path $CRT_FILE_PATH) -and (Test-Path $KEY_FILE_PATH)) {
#     $KEYSTORE_PATH = "C:\Program Files\Java\jdk\lib\security\keystore.jks"
#     $KEYSTORE_PASS = "changeit"
#     $ALIAS_NAME = if ($ARGUMENT_1) { $ARGUMENT_1 } else { "myservice" }
#     
#     $opensslPath = "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
#     $keytoolPath = "C:\Program Files\Java\jdk\bin\keytool.exe"
#     
#     if ((Test-Path $opensslPath) -and (Test-Path $keytoolPath)) {
#         # First create a PKCS12 file
#         $TEMP_P12 = "$env:TEMP\temp_cert.p12"
#         
#         & $opensslPath pkcs12 -export `
#             -in $CRT_FILE_PATH `
#             -inkey $KEY_FILE_PATH `
#             -out $TEMP_P12 `
#             -passout pass:temppass
#         
#         # Import into Java keystore
#         & $keytoolPath -importkeystore `
#             -srckeystore $TEMP_P12 `
#             -srcstoretype PKCS12 `
#             -srcstorepass temppass `
#             -destkeystore $KEYSTORE_PATH `
#             -deststoretype JKS `
#             -deststorepass $KEYSTORE_PASS `
#             -alias $ALIAS_NAME
#         
#         Remove-Item $TEMP_P12 -Force
#         Write-LogMessage "Certificate imported to Java keystore with alias: $ALIAS_NAME"
#     }
# }

# Example 5: Verify certificate and key match using OpenSSL
# $opensslPath = "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
# if ((Test-Path $CRT_FILE_PATH) -and (Test-Path $KEY_FILE_PATH) -and (Test-Path $opensslPath)) {
#     # Get certificate modulus
#     $crtModulusCmd = & $opensslPath x509 -noout -modulus -in $CRT_FILE_PATH 2>$null
#     $crtModulus = ($crtModulusCmd | & $opensslPath md5)
#     
#     # Get key modulus
#     $keyModulusCmd = & $opensslPath rsa -noout -modulus -in $KEY_FILE_PATH 2>$null
#     $keyModulus = ($keyModulusCmd | & $opensslPath md5)
#     
#     if ($crtModulus -eq $keyModulus) {
#         Write-LogMessage "SUCCESS: Certificate and private key match"
#     } else {
#         Write-LogMessage "ERROR: Certificate and private key DO NOT match!"
#         Write-LogMessage "Certificate modulus: $crtModulus"
#         Write-LogMessage "Key modulus: $keyModulus"
#     }
# }

# Example 6: Send notification based on arguments
# if ($ARGUMENT_2 -eq "notify") {
#     $NOTIFICATION_EMAIL = $ARGUMENT_3  # Email in argument 3
#     $HOSTNAME = $env:COMPUTERNAME
#     
#     if (-not [string]::IsNullOrEmpty($NOTIFICATION_EMAIL)) {
#         $subject = "Certificate Deployment - $HOSTNAME"
#         $body = @"
# Certificate deployed on $HOSTNAME
# Certificate: $CRT_FILE_PATH
# Key: $KEY_FILE_PATH
# Time: $(Get-Date)
# "@
#         
#         Send-MailMessage `
#             -To $NOTIFICATION_EMAIL `
#             -From "admin@example.com" `
#             -Subject $subject `
#             -Body $body `
#             -SmtpServer "smtp.example.com"
#         
#         Write-LogMessage "Notification sent to: $NOTIFICATION_EMAIL"
#     }
# }

# Example 7: Combine CRT with intermediate certificates for full chain
# if (Test-Path $CRT_FILE_PATH) {
#     # Look for intermediate certificate files
#     $intermediateFiles = Get-ChildItem -Path $CERT_FOLDER -Filter "*.ca" -ErrorAction SilentlyContinue
#     if (-not $intermediateFiles) {
#         $intermediateFiles = Get-ChildItem -Path $CERT_FOLDER -Filter "*intermediate*" -ErrorAction SilentlyContinue
#     }
#     
#     if ($intermediateFiles) {
#         $fullChainPath = Join-Path $CERT_FOLDER "fullchain.crt"
#         
#         # Start with server certificate
#         Get-Content $CRT_FILE_PATH | Set-Content $fullChainPath
#         
#         # Add intermediate certificates
#         foreach ($intermediate in $intermediateFiles) {
#             Get-Content $intermediate.FullName | Add-Content $fullChainPath
#         }
#         
#         Write-LogMessage "Full certificate chain created: $fullChainPath"
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