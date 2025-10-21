#!/usr/bin/env pwsh

<#
.SYNOPSIS
    DigiCert Certificate Management Script for F5 BIG-IP
.DESCRIPTION
    PowerShell 6 conversion of the original bash script for managing DigiCert certificates
    and deploying them to F5 BIG-IP load balancers.
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
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\f5_data.log"

# BIG-IP SSL Profile Update Configuration
$UPDATE_SSL_PROFILE = "true"  # Set to "true" to enable SSL profile update

# ============================================================================
# CUSTOM SCRIPT SECTION - BIG-IP F5 API INTEGRATION
# ============================================================================
#
# Arguments mapping:
# $ARGUMENT_1 - Username (e.g., admin)
# $ARGUMENT_2 - Password (e.g., Tra1ning!)
# $ARGUMENT_3 - BIG-IP IP address or hostname (e.g., ec2-18-117-237-17.us-east-2.compute.amazonaws.com:8443)
# $ARGUMENT_4 - Certificate Name (e.g., ssl-server.com)
# $ARGUMENT_5 - SSL Server Profile name (e.g., serverssl) - only used if UPDATE_SSL_PROFILE="true"
#
# ============================================================================

# Function to log messages with timestamp
function Write-LogMessage {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $LOGFILE -Value $logEntry -Encoding UTF8
}

# Create log directory if it doesn't exist
$logDir = Split-Path -Path $LOGFILE -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script"
Write-LogMessage "=========================================="

# Check legal notice acceptance
Write-LogMessage "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-LogMessage "ERROR: Legal notice not accepted. Set `$LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
    Write-LogMessage "Script execution terminated due to legal notice non-acceptance."
    Write-LogMessage "=========================================="
    exit 1
}
else {
    Write-LogMessage "Legal notice accepted, proceeding with script execution."
}

# Log initial configuration
Write-LogMessage "Configuration:"
Write-LogMessage "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Write-LogMessage "  LOGFILE: $LOGFILE"

# Log environment variable check
Write-LogMessage "Checking DC1_POST_SCRIPT_DATA environment variable..."
$DC1_POST_SCRIPT_DATA = $env:DC1_POST_SCRIPT_DATA

if ([string]::IsNullOrEmpty($DC1_POST_SCRIPT_DATA)) {
    Write-LogMessage "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
}
else {
    Write-LogMessage "DC1_POST_SCRIPT_DATA is set (length: $($DC1_POST_SCRIPT_DATA.Length) characters)"
}

# Read the Base64-encoded JSON string from the environment variable
$CERT_INFO = $DC1_POST_SCRIPT_DATA
Write-LogMessage "CERT_INFO length: $($CERT_INFO.Length) characters"

# Decode JSON string
try {
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($CERT_INFO))
    Write-LogMessage "JSON_STRING decoded successfully"
}
catch {
    Write-LogMessage "ERROR: Failed to decode Base64 string: $_"
    exit 1
}

# Parse JSON
try {
    $jsonObject = $JSON_STRING | ConvertFrom-Json
    Write-LogMessage "JSON parsed successfully"
}
catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Log the raw JSON for debugging (with password obfuscated)
Write-LogMessage "=========================================="
Write-LogMessage "Raw JSON content (password obfuscated):"

# Create a filtered version of JSON for logging
$jsonObjectFiltered = $jsonObject | ConvertTo-Json -Depth 10 | ConvertFrom-Json
if ($jsonObjectFiltered.args -and $jsonObjectFiltered.args.Count -gt 1) {
    $jsonObjectFiltered.args[1] = "********"
}
$jsonStringFiltered = $jsonObjectFiltered | ConvertTo-Json -Depth 10 -Compress
Write-LogMessage $jsonStringFiltered
Write-LogMessage "=========================================="

# Extract arguments from JSON
Write-LogMessage "Extracting arguments from JSON..."

# Extract arguments
$ARGS_ARRAY = $jsonObject.args
Write-LogMessage "Args array count: $($ARGS_ARRAY.Count)"

# Initialize arguments
$ARGUMENT_1 = ""
$ARGUMENT_2 = ""
$ARGUMENT_3 = ""
$ARGUMENT_4 = ""
$ARGUMENT_5 = ""

# Extract arguments safely
if ($ARGS_ARRAY -and $ARGS_ARRAY.Count -gt 0) {
    # Extract Argument_1 - first argument (Username)
    if ($ARGS_ARRAY.Count -ge 1) {
        $ARGUMENT_1 = $ARGS_ARRAY[0].Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    
    # Extract Argument_2 - second argument (Password - will be obfuscated in logs)
    if ($ARGS_ARRAY.Count -ge 2) {
        $ARGUMENT_2 = $ARGS_ARRAY[1].Trim()
        $ARGUMENT_2_OBFUSCATED = if (-not [string]::IsNullOrEmpty($ARGUMENT_2)) { "********" } else { "[EMPTY]" }
        Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2_OBFUSCATED'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    
    # Extract Argument_3 - third argument (BIG-IP Host)
    if ($ARGS_ARRAY.Count -ge 3) {
        $ARGUMENT_3 = $ARGS_ARRAY[2].Trim()
        Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
        Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
    }
    
    # Extract Argument_4 - fourth argument (Certificate Name)
    if ($ARGS_ARRAY.Count -ge 4) {
        $ARGUMENT_4 = $ARGS_ARRAY[3].Trim()
        Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
        Write-LogMessage "ARGUMENT_4 length: $($ARGUMENT_4.Length)"
    }
    
    # Extract Argument_5 - fifth argument (SSL Profile)
    if ($ARGS_ARRAY.Count -ge 5) {
        $ARGUMENT_5 = $ARGS_ARRAY[4].Trim()
        Write-LogMessage "ARGUMENT_5 extracted: '$ARGUMENT_5'"
        Write-LogMessage "ARGUMENT_5 length: $($ARGUMENT_5.Length)"
    }
}

# Extract cert folder
$CERT_FOLDER = $jsonObject.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract file names
$FILES_ARRAY = $jsonObject.files
Write-LogMessage "Files array content: $($FILES_ARRAY -join ', ')"

# Extract the .crt file name
$CRT_FILE = $FILES_ARRAY | Where-Object { $_ -like "*.crt" } | Select-Object -First 1
Write-LogMessage "Extracted CRT_FILE: $CRT_FILE"

# Extract the .key file name
$KEY_FILE = $FILES_ARRAY | Where-Object { $_ -like "*.key" } | Select-Object -First 1
Write-LogMessage "Extracted KEY_FILE: $KEY_FILE"

# Construct file paths
$CRT_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CRT_FILE
$KEY_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $KEY_FILE

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "Arguments extracted:"
Write-LogMessage "  Argument 1 (Username): $ARGUMENT_1"
Write-LogMessage "  Argument 2 (Password): $ARGUMENT_2_OBFUSCATED"
Write-LogMessage "  Argument 3 (BIG-IP Host): $ARGUMENT_3"
Write-LogMessage "  Argument 4 (Cert Name): $ARGUMENT_4"
Write-LogMessage "  Argument 5 (SSL Profile): $ARGUMENT_5"
Write-LogMessage ""
Write-LogMessage "Certificate information:"
Write-LogMessage "  Certificate folder: $CERT_FOLDER"
Write-LogMessage "  Certificate file: $CRT_FILE"
Write-LogMessage "  Private key file: $KEY_FILE"
Write-LogMessage "  Certificate path: $CRT_FILE_PATH"
Write-LogMessage "  Private key path: $KEY_FILE_PATH"
Write-LogMessage ""
Write-LogMessage "All files in array: $($FILES_ARRAY -join ', ')"
Write-LogMessage "=========================================="

# Check if files exist
if (Test-Path -Path $CRT_FILE_PATH) {
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    $certFileInfo = Get-Item $CRT_FILE_PATH
    Write-LogMessage "Certificate file size: $($certFileInfo.Length) bytes"
    
    # Count certificates in the file
    $certContent = Get-Content -Path $CRT_FILE_PATH -Raw
    $certCount = ([regex]::Matches($certContent, "BEGIN CERTIFICATE")).Count
    Write-LogMessage "Total certificates in file: $certCount"
}
else {
    Write-LogMessage "WARNING: Certificate file not found: $CRT_FILE_PATH"
}

if (Test-Path -Path $KEY_FILE_PATH) {
    Write-LogMessage "Private key file exists: $KEY_FILE_PATH"
    $keyFileInfo = Get-Item $KEY_FILE_PATH
    Write-LogMessage "Private key file size: $($keyFileInfo.Length) bytes"
    
    # Determine key type
    $keyContent = Get-Content -Path $KEY_FILE_PATH -Raw
    if ($keyContent -match "BEGIN RSA PRIVATE KEY") {
        $keyType = "RSA"
        Write-LogMessage "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
    }
    elseif ($keyContent -match "BEGIN EC PRIVATE KEY") {
        $keyType = "ECC"
        Write-LogMessage "Key type: ECC (BEGIN EC PRIVATE KEY found)"
    }
    elseif ($keyContent -match "BEGIN PRIVATE KEY") {
        $keyType = "PKCS#8 format (generic)"
        Write-LogMessage "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
    }
    else {
        $keyType = "Unknown"
        Write-LogMessage "Key type: Unknown"
    }
}
else {
    Write-LogMessage "WARNING: Private key file not found: $KEY_FILE_PATH"
}

Write-LogMessage "=========================================="
Write-LogMessage "Starting BIG-IP F5 API Integration..."
Write-LogMessage "=========================================="

# Validate required arguments
if ([string]::IsNullOrEmpty($ARGUMENT_1) -or [string]::IsNullOrEmpty($ARGUMENT_2) -or 
    [string]::IsNullOrEmpty($ARGUMENT_3) -or [string]::IsNullOrEmpty($ARGUMENT_4)) {
    Write-LogMessage "ERROR: Missing required arguments for BIG-IP integration"
    Write-LogMessage "  Username (Arg1): $ARGUMENT_1"
    Write-LogMessage "  Password (Arg2): [HIDDEN]"
    Write-LogMessage "  BIG-IP Host (Arg3): $ARGUMENT_3"
    Write-LogMessage "  Certificate Name (Arg4): $ARGUMENT_4"
    Write-LogMessage "Skipping BIG-IP integration due to missing arguments"
}
else {
    # Set variables from arguments
    $BIGIP_USER = $ARGUMENT_1
    $BIGIP_PASS = $ARGUMENT_2
    $BIGIP_HOST = $ARGUMENT_3
    $CERT_NAME = $ARGUMENT_4
    $SSL_PROFILE = $ARGUMENT_5
    
    Write-LogMessage "BIG-IP Configuration:"
    Write-LogMessage "  Host: $BIGIP_HOST"
    Write-LogMessage "  User: $BIGIP_USER"
    Write-LogMessage "  Certificate Name: $CERT_NAME"
    Write-LogMessage "  Update SSL Profile: $UPDATE_SSL_PROFILE"
    if ($UPDATE_SSL_PROFILE -eq "true") {
        Write-LogMessage "  SSL Profile: $SSL_PROFILE"
    }
    
    # Ensure files exist before proceeding
    if ((Test-Path -Path $CRT_FILE_PATH) -and (Test-Path -Path $KEY_FILE_PATH)) {
        
        # Create credentials for authentication
        $securePassword = ConvertTo-SecureString $BIGIP_PASS -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($BIGIP_USER, $securePassword)
        
        # Disable SSL certificate validation for self-signed certificates
        if ($PSVersionTable.PSVersion.Major -ge 6) {
            $skipCertCheck = @{ SkipCertificateCheck = $true }
        }
        else {
            # For older PowerShell versions
            add-type @"
                using System.Net;
                using System.Security.Cryptography.X509Certificates;
                public class TrustAllCertsPolicy : ICertificatePolicy {
                    public bool CheckValidationResult(
                        ServicePoint srvPoint, X509Certificate certificate,
                        WebRequest request, int certificateProblem) {
                        return true;
                    }
                }
"@
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
            $skipCertCheck = @{}
        }
        
        # Step 1: Upload the certificate file
        Write-LogMessage "Step 1: Uploading certificate file to BIG-IP..."
        
        try {
            $certBytes = [System.IO.File]::ReadAllBytes($CRT_FILE_PATH)
            $certSize = $certBytes.Length
            $certRangeEnd = $certSize - 1
            
            $headers = @{
                "Content-Type" = "application/octet-stream"
                "Content-Range" = "0-$certRangeEnd/$certSize"
            }
            
            $uri = "https://$BIGIP_HOST/mgmt/shared/file-transfer/uploads/$CERT_NAME.crt"
            
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                -Body $certBytes -Credential $credential @skipCertCheck
            
            Write-LogMessage "SUCCESS: Certificate file uploaded"
        }
        catch {
            Write-LogMessage "ERROR: Failed to upload certificate file: $_"
            Write-LogMessage "Response: $($_.Exception.Response)"
        }
        
        # Step 2: Upload the key file
        Write-LogMessage "Step 2: Uploading key file to BIG-IP..."
        
        try {
            $keyBytes = [System.IO.File]::ReadAllBytes($KEY_FILE_PATH)
            $keySize = $keyBytes.Length
            $keyRangeEnd = $keySize - 1
            
            $headers = @{
                "Content-Type" = "application/octet-stream"
                "Content-Range" = "0-$keyRangeEnd/$keySize"
            }
            
            $uri = "https://$BIGIP_HOST/mgmt/shared/file-transfer/uploads/$CERT_NAME.key"
            
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers `
                -Body $keyBytes -Credential $credential @skipCertCheck
            
            Write-LogMessage "SUCCESS: Key file uploaded"
        }
        catch {
            Write-LogMessage "ERROR: Failed to upload key file: $_"
            Write-LogMessage "Response: $($_.Exception.Response)"
        }
        
        # Step 3: Install certificate
        Write-LogMessage "Step 3: Installing certificate on BIG-IP..."
        
        try {
            $body = @{
                command = "install"
                name = $CERT_NAME
                "from-local-file" = "/var/config/rest/downloads/$CERT_NAME.crt"
            } | ConvertTo-Json
            
            $uri = "https://$BIGIP_HOST/mgmt/tm/sys/crypto/cert"
            
            $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
                -ContentType "application/json" -Credential $credential @skipCertCheck
            
            Write-LogMessage "SUCCESS: Certificate installed"
        }
        catch {
            Write-LogMessage "ERROR: Failed to install certificate: $_"
            Write-LogMessage "Response: $($_.Exception.Response)"
        }
        
        # Step 4: Install key
        Write-LogMessage "Step 4: Installing key on BIG-IP..."
        
        try {
            $body = @{
                command = "install"
                name = $CERT_NAME
                "from-local-file" = "/var/config/rest/downloads/$CERT_NAME.key"
            } | ConvertTo-Json
            
            $uri = "https://$BIGIP_HOST/mgmt/tm/sys/crypto/key"
            
            $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
                -ContentType "application/json" -Credential $credential @skipCertCheck
            
            Write-LogMessage "SUCCESS: Key installed"
        }
        catch {
            Write-LogMessage "ERROR: Failed to install key: $_"
            Write-LogMessage "Response: $($_.Exception.Response)"
        }
        
        # Step 5: Update Server SSL Profile (if enabled)
        if ($UPDATE_SSL_PROFILE -eq "true") {
            if ([string]::IsNullOrEmpty($SSL_PROFILE)) {
                Write-LogMessage "WARNING: UPDATE_SSL_PROFILE is true but SSL_PROFILE (Argument 5) is not set"
                Write-LogMessage "Skipping SSL profile update"
            }
            else {
                Write-LogMessage "Step 5: Updating Server SSL Profile..."
                
                try {
                    $body = @{
                        cert = "/Common/$CERT_NAME"
                        key = "/Common/$CERT_NAME"
                    } | ConvertTo-Json
                    
                    $uri = "https://$BIGIP_HOST/mgmt/tm/ltm/profile/server-ssl/$SSL_PROFILE"
                    
                    $response = Invoke-RestMethod -Uri $uri -Method Patch -Body $body `
                        -ContentType "application/json" -Credential $credential @skipCertCheck
                    
                    Write-LogMessage "SUCCESS: Server SSL Profile updated"
                }
                catch {
                    Write-LogMessage "ERROR: Failed to update Server SSL Profile: $_"
                    Write-LogMessage "Response: $($_.Exception.Response)"
                }
            }
        }
        else {
            Write-LogMessage "Step 5: Skipping SSL profile update (UPDATE_SSL_PROFILE=$UPDATE_SSL_PROFILE)"
        }
        
        Write-LogMessage "BIG-IP integration completed"
    }
    else {
        Write-LogMessage "ERROR: Certificate or key files not found. Cannot proceed with BIG-IP integration"
        Write-LogMessage "  Certificate path: $CRT_FILE_PATH (exists: $(Test-Path $CRT_FILE_PATH))"
        Write-LogMessage "  Key path: $KEY_FILE_PATH (exists: $(Test-Path $KEY_FILE_PATH))"
    }
}

Write-LogMessage "=========================================="
Write-LogMessage "BIG-IP F5 API Integration completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

exit 0