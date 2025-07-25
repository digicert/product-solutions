# Legal Notice (version October 29, 2024)
# Copyright © 2024 DigiCert. All rights reserved.
# DigiCert and its logo are registered trademarks of DigiCert, Inc.
# Other names may be trademarks of their respective owners.
# For the purposes of this Legal Notice, "DigiCert" refers to:
# - DigiCert, Inc., if you are located in the United States;
# - DigiCert Ireland Limited, if you are located outside of the United States or Japan;
# - DigiCert Japan G.K., if you are located in Japan.
# The software described in this notice is provided by DigiCert and distributed under licenses
# restricting its use, copying, distribution, and decompilation or reverse engineering.
# No part of the software may be reproduced in any form by any means without prior written authorization
# of DigiCert and its licensors, if any.
# Use of the software is subject to the terms and conditions of your agreement with DigiCert, including
# any dispute resolution and applicable law provisions. The terms set out herein are supplemental to
# your agreement and, in the event of conflict, these terms control.
# THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES,
# INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT,
# ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.
# Export Regulation: The software and related technical data and services (collectively "Controlled Technology")
# are subject to the import and export laws of the United States, specifically the U.S. Export Administration
# Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.
# US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or
# disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
# Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
# subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19,
# as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
# The contractor/manufacturer is DIGICERT, INC.

# Configuration
$LEGAL_NOTICE_ACCEPT = $true
$LOGFILE = "C:\Windows\Temp\tlm_agent_3.0.15_windows64\log\template.log"

# Function to log messages with timestamp
function Write-LogMessage {
    param (
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $LOGFILE -Value $logEntry
}

# Ensure log directory exists
$logDir = Split-Path -Path $LOGFILE -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting certificate variable extraction script"
Write-LogMessage "=========================================="

# Check legal notice acceptance
Write-LogMessage "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne $true) {
    Write-LogMessage "ERROR: Legal notice not accepted. Set `$LEGAL_NOTICE_ACCEPT = `$true to proceed."
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
$DC1_POST_SCRIPT_DATA = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
if ([string]::IsNullOrEmpty($DC1_POST_SCRIPT_DATA)) {
    Write-LogMessage "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
} else {
    Write-LogMessage "DC1_POST_SCRIPT_DATA is set (length: $($DC1_POST_SCRIPT_DATA.Length) characters)"
}

# Read the Base64-encoded JSON string from the environment variable
$CERT_INFO = $DC1_POST_SCRIPT_DATA
Write-LogMessage "CERT_INFO length: $($CERT_INFO.Length) characters"

# Decode JSON string
try {
    $bytes = [System.Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString($bytes)
    Write-LogMessage "JSON_STRING decoded successfully"
} catch {
    Write-LogMessage "ERROR: Failed to decode base64 JSON: $_"
    exit 1
}

# Convert JSON string to PowerShell object for easier parsing
try {
    $jsonObject = $JSON_STRING | ConvertFrom-Json
} catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Extract arguments from JSON
Write-LogMessage "Extracting arguments from JSON..."

# First, let's log the args array
if ($jsonObject.args) {
    $ARGS_ARRAY = $jsonObject.args -join ', '
    Write-LogMessage "Raw args array: $ARGS_ARRAY"
    
    # Extract Argument_1 - first argument
    $ARGUMENT_1 = if ($jsonObject.args.Count -gt 0) { $jsonObject.args[0].ToString().Trim() } else { "" }
    Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
    Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    
    # Extract Argument_2 - second argument
    $ARGUMENT_2 = if ($jsonObject.args.Count -gt 1) { $jsonObject.args[1].ToString().Trim() } else { "" }
    Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
    Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    
    # Extract Argument_3 - third argument
    $ARGUMENT_3 = if ($jsonObject.args.Count -gt 2) { $jsonObject.args[2].ToString().Trim() } else { "" }
    Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
    Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
    
    # Extract Argument_4 - fourth argument
    $ARGUMENT_4 = if ($jsonObject.args.Count -gt 3) { $jsonObject.args[3].ToString().Trim() } else { "" }
    Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
    Write-LogMessage "ARGUMENT_4 length: $($ARGUMENT_4.Length)"
    
    # Extract Argument_5 - fifth argument
    $ARGUMENT_5 = if ($jsonObject.args.Count -gt 4) { $jsonObject.args[4].ToString().Trim() } else { "" }
    Write-LogMessage "ARGUMENT_5 extracted: '$ARGUMENT_5'"
    Write-LogMessage "ARGUMENT_5 length: $($ARGUMENT_5.Length)"
} else {
    Write-LogMessage "No args array found in JSON"
    $ARGUMENT_1 = $ARGUMENT_2 = $ARGUMENT_3 = $ARGUMENT_4 = $ARGUMENT_5 = ""
}

# Log extracted arguments summary
Write-LogMessage "Extracted arguments summary:"
Write-LogMessage "  ARGUMENT_1: '$ARGUMENT_1'"
Write-LogMessage "  ARGUMENT_2: '$ARGUMENT_2'"
Write-LogMessage "  ARGUMENT_3: '$ARGUMENT_3'"
Write-LogMessage "  ARGUMENT_4: '$ARGUMENT_4'"
Write-LogMessage "  ARGUMENT_5: '$ARGUMENT_5'"

# Validate and clean arguments
Write-LogMessage "Validating extracted argument values..."

# Remove any potential whitespace from all arguments
$ARGUMENT_1 = $ARGUMENT_1 -replace '\s+', ''
$ARGUMENT_2 = $ARGUMENT_2 -replace '\s+', ''
$ARGUMENT_3 = $ARGUMENT_3 -replace '\s+', ''
$ARGUMENT_4 = $ARGUMENT_4 -replace '\s+', ''
$ARGUMENT_5 = $ARGUMENT_5 -replace '\s+', ''

# Extract cert folder
$CERT_FOLDER = $jsonObject.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .pfx file name (look for PFX instead of CRT/KEY)
$PFX_FILE = $jsonObject.files | Where-Object { $_ -match '\.pfx$' } | Select-Object -First 1
Write-LogMessage "Extracted PFX_FILE: $PFX_FILE"

# Extract password if present
$PASSWORD = $jsonObject.password
if ($PASSWORD) {
    Write-LogMessage "Extracted PASSWORD: [password length: $($PASSWORD.Length)]"
} else {
    Write-LogMessage "No password found in JSON"
}

# Construct file path
$PFX_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $PFX_FILE
Write-LogMessage "Constructed file paths:"
Write-LogMessage "  PFX_FILE_PATH: $PFX_FILE_PATH"

# Check if PFX file exists
if (Test-Path -Path $PFX_FILE_PATH) {
    $fileInfo = Get-Item -Path $PFX_FILE_PATH
    Write-LogMessage "PFX file exists: $PFX_FILE_PATH"
    Write-LogMessage "PFX file size: $($fileInfo.Length) bytes"
} else {
    Write-LogMessage "ERROR: PFX file not found: $PFX_FILE_PATH"
    exit 1
}

# Import the PFX certificate to the local machine store
Write-LogMessage "Importing PFX certificate to LocalMachine\My store..."
try {
    if ($PASSWORD) {
        $securePassword = ConvertTo-SecureString -String $PASSWORD -Force -AsPlainText
        $cert = Import-PfxCertificate -FilePath $PFX_FILE_PATH -CertStoreLocation Cert:\LocalMachine\My -Password $securePassword
    } else {
        # Try without password if none provided
        $cert = Import-PfxCertificate -FilePath $PFX_FILE_PATH -CertStoreLocation Cert:\LocalMachine\My
    }
    
    if ($null -eq $cert) {
        throw "Failed to import the certificate - Import-PfxCertificate returned null"
    }
    
    Write-LogMessage "SUCCESS: Certificate imported successfully"
    Write-LogMessage "Certificate Thumbprint: $($cert.Thumbprint)"
    Write-LogMessage "Certificate Subject: $($cert.Subject)"
    Write-LogMessage "Certificate Issuer: $($cert.Issuer)"
    Write-LogMessage "Certificate Valid From: $($cert.NotBefore)"
    Write-LogMessage "Certificate Valid To: $($cert.NotAfter)"
    
} catch {
    Write-LogMessage "ERROR: Failed to import the certificate: $_"
    exit 1
}

# Write variables to output
Write-LogMessage "Writing extracted variables:"
Write-LogMessage "  Argument 1: $ARGUMENT_1"
Write-LogMessage "  Argument 2: $ARGUMENT_2"
Write-LogMessage "  Argument 3: $ARGUMENT_3"
Write-LogMessage "  Argument 4: $ARGUMENT_4"
Write-LogMessage "  Argument 5: $ARGUMENT_5"
Write-LogMessage "  Certificate folder: $CERT_FOLDER"
Write-LogMessage "  PFX file: $PFX_FILE"
Write-LogMessage "  PFX file path: $PFX_FILE_PATH"

Write-LogMessage "=========================================="
Write-LogMessage "Variable extraction and certificate import completed successfully"
Write-LogMessage "=========================================="

exit 0