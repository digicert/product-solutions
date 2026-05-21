<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script - Radware Alteon Deployment (PowerShell Version)
.DESCRIPTION
    Imports a certificate and private key to a Radware Alteon load balancer via its REST API,
    using certificate and key files delivered by the DigiCert TLM Agent.
.NOTES
    Legal Notice (version January 1, 2026)
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
#>

# Configuration
$LEGAL_NOTICE_ACCEPT = "false"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\radware_alteon.log"

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# Function to obfuscate sensitive strings
function Get-ObfuscatedString {
    param(
        [string]$InputString,
        [int]$ShowChars = 3
    )
    if ($InputString.Length -le $ShowChars) {
        return $InputString
    }
    return $InputString.Substring(0, $ShowChars) + "***"
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

# Extract arguments if they exist
if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"

    if ($ARGS_ARRAY.Count -ge 1) {
        $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 (IP Address) extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) {
        $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 (Certificate ID) extracted: '$ARGUMENT_2'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 3) {
        $ARGUMENT_3 = ($ARGS_ARRAY[2] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_3 (Auth Token) extracted: '$(Get-ObfuscatedString $ARGUMENT_3)'"
        Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
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
Write-LogMessage "  Argument 1 (IP Address):     $ARGUMENT_1"
Write-LogMessage "  Argument 2 (Certificate ID): $ARGUMENT_2"
Write-LogMessage "  Argument 3 (Auth Token):     $(Get-ObfuscatedString $ARGUMENT_3)"
Write-LogMessage ""
Write-LogMessage "Certificate information:"
Write-LogMessage "  Certificate folder: $CERT_FOLDER"
Write-LogMessage "  Certificate file:   $CRT_FILE"
Write-LogMessage "  Private key file:   $KEY_FILE"
Write-LogMessage "  Certificate path:   $CRT_FILE_PATH"
Write-LogMessage "  Private key path:   $KEY_FILE_PATH"
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
# CUSTOM SCRIPT SECTION - RADWARE ALTEON CERTIFICATE DEPLOYMENT
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
#   $ARGUMENT_1       - IP Address or hostname of the Radware Alteon
#   $ARGUMENT_2       - Certificate ID on the Alteon
#   $ARGUMENT_3       - Base64-encoded credentials for Basic Auth
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $JSON_OBJECT      - The parsed JSON object
#   $ARGS_ARRAY       - The args array from JSON object
#
# Utility functions:
#   Write-LogMessage "text"        - Function to write timestamped messages to log file
#   Get-ObfuscatedString "text"    - Function to obfuscate sensitive strings in logs
#
# WHAT THIS SECTION DOES
# ---------------------------------------------------------------------------
# 1) Import the certificate PEM to the Alteon via REST API:
#       POST https://{ARG1}/config/sslcertimport?renew=1&id={ARG2}&type=certificate&src=txt
# 2) Import the private key PEM to the Alteon via REST API:
#       POST https://{ARG1}/config/sslcertimport?renew=1&id={ARG2}&type=key&src=txt
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section..."
Write-LogMessage "Starting Radware Alteon certificate deployment..."
Write-LogMessage "=========================================="

# ADD YOUR CUSTOM LOGIC HERE:
# ----------------------------------------

# Validate required arguments
if ([string]::IsNullOrWhiteSpace($ARGUMENT_1)) {
    Write-LogMessage "ERROR: Argument 1 (IP Address / Base URL) is not provided"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ARGUMENT_2)) {
    Write-LogMessage "ERROR: Argument 2 (Certificate ID) is not provided"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ARGUMENT_3)) {
    Write-LogMessage "ERROR: Argument 3 (Auth Token) is not provided"
    exit 1
}

# Validate files exist before attempting deployment
if (-not (Test-Path $CRT_FILE_PATH)) {
    Write-LogMessage "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (-not (Test-Path $KEY_FILE_PATH)) {
    Write-LogMessage "ERROR: Private key file not found: $KEY_FILE_PATH"
    exit 1
}

# Configuration
$baseUrl = $ARGUMENT_1
$certId  = $ARGUMENT_2
$authToken = $ARGUMENT_3

Write-LogMessage "Radware Alteon target:"
Write-LogMessage "  Base URL:        $baseUrl"
Write-LogMessage "  Certificate ID:  $certId"
Write-LogMessage "  Auth Token:      $(Get-ObfuscatedString $authToken)"

# URI construction
$certUri = "https://$baseUrl/config/sslcertimport?renew=1&id=$certId&type=certificate&src=txt"
$keyUri  = "https://$baseUrl/config/sslcertimport?renew=1&id=$certId&type=key&src=txt"

Write-LogMessage "Certificate import URI: $certUri"
Write-LogMessage "Key import URI: $keyUri"

# Read certificate and key file contents
$certContent = Get-Content -Path $CRT_FILE_PATH -Raw
$keyContent  = Get-Content -Path $KEY_FILE_PATH -Raw

# Headers
$headers = @{
    'Content-Type'  = 'text/plain'
    'Authorization' = "Basic $authToken"
}

# Scoped SSL validation bypass — restore original callback after use
$originalCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

try {
    # Temporarily disable SSL validation (required for self-signed certs on Alteon)
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}

    # --- Step 1: Import Certificate ---
    Write-LogMessage "Step 1: Importing certificate to Radware Alteon..."

    $certResponse = Invoke-RestMethod `
        -Uri $certUri `
        -Method Post `
        -Headers $headers `
        -Body $certContent `
        -ContentType 'text/plain'

    $certResponseStr = $certResponse | Out-String
    Write-LogMessage "Certificate import response: $certResponseStr"

    # Validate certificate import response
    if ($certResponseStr -match "error|fail|denied|unauthorized") {
        Write-LogMessage "ERROR: Certificate import returned a failure indicator."
        Write-LogMessage "Response: $certResponseStr"
        exit 1
    } else {
        Write-LogMessage "SUCCESS: Certificate imported successfully."
    }

    # --- Step 2: Import Private Key ---
    Write-LogMessage "Step 2: Importing private key to Radware Alteon..."

    $keyResponse = Invoke-RestMethod `
        -Uri $keyUri `
        -Method Post `
        -Headers $headers `
        -Body $keyContent `
        -ContentType 'text/plain'

    $keyResponseStr = $keyResponse | Out-String
    Write-LogMessage "Key import response: $keyResponseStr"

    # Validate key import response
    if ($keyResponseStr -match "error|fail|denied|unauthorized") {
        Write-LogMessage "ERROR: Key import returned a failure indicator."
        Write-LogMessage "Response: $keyResponseStr"
        exit 1
    } else {
        Write-LogMessage "SUCCESS: Private key imported successfully."
    }

    Write-LogMessage "Radware Alteon certificate deployment completed successfully"
    Write-LogMessage "  Certificate ID: $certId"
    Write-LogMessage "  Target:         $baseUrl"

} catch {
    Write-LogMessage "EXCEPTION: $($_.Exception.Message)"
    Write-LogMessage "STACK TRACE: $($_.ScriptStackTrace)"
    exit 1

} finally {
    # ALWAYS restore the original SSL validation callback
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $originalCallback
    Write-LogMessage "SSL validation callback restored."
}

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