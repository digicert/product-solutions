<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script with Imperva API Integration - PowerShell Version
.DESCRIPTION
    PowerShell script for processing separate certificate and key files from DigiCert TLM Agent and uploading to Imperva
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
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\imperva.log"
$API_CALL_LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\imperva-api-call.log"

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# Function to log API call details
function Write-ApiCallLog {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $API_CALL_LOGFILE -Encoding UTF8
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script with Imperva integration"
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
Write-LogMessage "  API_CALL_LOGFILE: $API_CALL_LOGFILE"

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
$ARGUMENT_1 = ""  # Site ID
$ARGUMENT_2 = ""  # API ID
$ARGUMENT_3 = ""  # API Key
$ARGUMENT_4 = ""
$ARGUMENT_5 = ""

# Extract arguments if they exist
if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"
    
    if ($ARGS_ARRAY.Count -ge 1) { 
        $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 (Site ID) extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) { 
        $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 (API ID) extracted: '$ARGUMENT_2'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 3) { 
        $ARGUMENT_3 = ($ARGS_ARRAY[2] -replace '\s', '').Trim()
        $ApiKeyPreview = if ($ARGUMENT_3.Length -gt 5) { $ARGUMENT_3.Substring(0, 5) + "..." } else { "***" }
        Write-LogMessage "ARGUMENT_3 (API Key) extracted: '$ApiKeyPreview'"
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

Write-LogMessage "Constructed file paths:"
Write-LogMessage "  CRT_FILE_PATH: $CRT_FILE_PATH"
Write-LogMessage "  KEY_FILE_PATH: $KEY_FILE_PATH"

# Check if files exist
if (Test-Path $CRT_FILE_PATH) {
    $certFileInfo = Get-Item $CRT_FILE_PATH
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    Write-LogMessage "Certificate file size: $($certFileInfo.Length) bytes"
} else {
    Write-LogMessage "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (Test-Path $KEY_FILE_PATH) {
    $keyFileInfo = Get-Item $KEY_FILE_PATH
    Write-LogMessage "Key file exists: $KEY_FILE_PATH"
    Write-LogMessage "Key file size: $($keyFileInfo.Length) bytes"
} else {
    Write-LogMessage "ERROR: Key file not found: $KEY_FILE_PATH"
    exit 1
}

# Count total certificates in the file
$certContent = Get-Content -Path $CRT_FILE_PATH -Raw
$certCount = ([regex]::Matches($certContent, "BEGIN CERTIFICATE")).Count
Write-LogMessage "Total certificates in file: $certCount"

# ============================================================================
# IMPERVA API INTEGRATION SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting Imperva API Integration"
Write-LogMessage "=========================================="

# Base64 encode the entire certificate chain
Write-LogMessage "Base64 encoding certificate chain..."
$certChainContent = Get-Content -Path $CRT_FILE_PATH -Raw
$certChainBytes = [System.Text.Encoding]::UTF8.GetBytes($certChainContent)
$CERT_CHAIN_BASE64 = [System.Convert]::ToBase64String($certChainBytes)
Write-LogMessage "Certificate chain Base64 encoded successfully"
Write-LogMessage "Certificate chain Base64 length: $($CERT_CHAIN_BASE64.Length) characters"

# Log first 100 characters of Base64 for verification
$certB64Preview = if ($CERT_CHAIN_BASE64.Length -gt 100) { 
    $CERT_CHAIN_BASE64.Substring(0, 100) + "..."
} else { 
    $CERT_CHAIN_BASE64 
}
Write-LogMessage "Certificate chain Base64 starts with: $certB64Preview"

# Base64 encode the private key
Write-LogMessage "Base64 encoding private key..."
$keyContent = Get-Content -Path $KEY_FILE_PATH -Raw
$keyBytes = [System.Text.Encoding]::UTF8.GetBytes($keyContent)
$KEY_BASE64 = [System.Convert]::ToBase64String($keyBytes)
Write-LogMessage "Private key Base64 encoded successfully"
Write-LogMessage "Private key Base64 length: $($KEY_BASE64.Length) characters"

# Log first 50 characters of Base64 encoded key for verification (truncated for security)
$keyB64Preview = if ($KEY_BASE64.Length -gt 50) { 
    $KEY_BASE64.Substring(0, 50) + "..."
} else { 
    "***"
}
Write-LogMessage "Private key Base64 starts with: $keyB64Preview"

# Verify Base64 encoding by attempting to decode back
Write-LogMessage "Verifying Base64 encoding..."
try {
    $verifyCertBytes = [System.Convert]::FromBase64String($CERT_CHAIN_BASE64)
    $verifyCertString = [System.Text.Encoding]::UTF8.GetString($verifyCertBytes)
    if ($verifyCertString -match "BEGIN CERTIFICATE") {
        Write-LogMessage "Certificate Base64 verification: SUCCESS (decodes to valid PEM)"
    } else {
        Write-LogMessage "WARNING: Certificate Base64 may be invalid"
    }
} catch {
    Write-LogMessage "WARNING: Failed to verify certificate Base64: $_"
}

try {
    $verifyKeyBytes = [System.Convert]::FromBase64String($KEY_BASE64)
    $verifyKeyString = [System.Text.Encoding]::UTF8.GetString($verifyKeyBytes)
    if ($verifyKeyString -match "BEGIN.*PRIVATE KEY") {
        Write-LogMessage "Private key Base64 verification: SUCCESS (decodes to valid PEM)"
    } else {
        Write-LogMessage "WARNING: Private key Base64 may be invalid"
    }
} catch {
    Write-LogMessage "WARNING: Failed to verify private key Base64: $_"
}

# Determine auth_type based on private key content
Write-LogMessage "Analyzing private key file for auth_type detection..."

$AUTH_TYPE = "RSA"  # Default

if ($keyContent -match "BEGIN RSA PRIVATE KEY") {
    $AUTH_TYPE = "RSA"
    Write-LogMessage "Detected RSA private key (BEGIN RSA PRIVATE KEY found)"
}
elseif ($keyContent -match "BEGIN EC PRIVATE KEY") {
    $AUTH_TYPE = "ECC"
    Write-LogMessage "Detected ECC private key (BEGIN EC PRIVATE KEY found)"
}
elseif ($keyContent -match "BEGIN PRIVATE KEY") {
    # PKCS#8 format - need to determine if it's RSA or ECC by checking the certificate
    Write-LogMessage "PKCS#8 format detected, checking certificate for key type..."
    
    # Check if OpenSSL is available to analyze the certificate
    $opensslPath = $null
    $possiblePaths = @(
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
        "C:\Program Files\OpenSSL\bin\openssl.exe",
        "C:\OpenSSL\bin\openssl.exe",
        "openssl.exe"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path -ErrorAction SilentlyContinue) {
            $opensslPath = $path
            break
        }
        # Try to find in PATH
        $cmdInfo = Get-Command $path -ErrorAction SilentlyContinue
        if ($cmdInfo) {
            $opensslPath = $cmdInfo.Path
            break
        }
    }
    
    if ($opensslPath) {
        try {
            # Save cert to temp file for OpenSSL analysis
            $tempCertFile = [System.IO.Path]::GetTempFileName()
            $certContent | Out-File -FilePath $tempCertFile -Encoding ASCII
            
            # Run OpenSSL to check certificate details
            $opensslOutput = & $opensslPath x509 -noout -text -in $tempCertFile 2>&1 | Out-String
            
            if ($opensslOutput -match "rsaEncryption|RSA") {
                $AUTH_TYPE = "RSA"
                Write-LogMessage "Detected RSA private key (PKCS#8 format, determined from certificate)"
            }
            elseif ($opensslOutput -match "id-ecPublicKey|EC") {
                $AUTH_TYPE = "ECC"
                Write-LogMessage "Detected ECC private key (PKCS#8 format, determined from certificate)"
            }
            else {
                $AUTH_TYPE = "RSA"
                Write-LogMessage "Could not determine key type from certificate, defaulting to RSA"
            }
            
            # Clean up temp file
            Remove-Item -Path $tempCertFile -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-LogMessage "Error analyzing certificate with OpenSSL: $_"
            Write-LogMessage "Defaulting to RSA"
            $AUTH_TYPE = "RSA"
        }
    }
    else {
        # OpenSSL not available, try simple text matching in certificate
        if ($certContent -match "RSA|rsaEncryption") {
            $AUTH_TYPE = "RSA"
            Write-LogMessage "Detected RSA from certificate text (OpenSSL not available)"
        }
        elseif ($certContent -match "EC|elliptic") {
            $AUTH_TYPE = "ECC"
            Write-LogMessage "Detected ECC from certificate text (OpenSSL not available)"
        }
        else {
            $AUTH_TYPE = "RSA"
            Write-LogMessage "Could not determine key type, defaulting to RSA"
        }
    }
}
else {
    $AUTH_TYPE = "RSA"
    Write-LogMessage "Could not determine key type, defaulting to RSA"
}

Write-LogMessage "Final auth_type: $AUTH_TYPE"

# Prepare API call parameters
$SITE_ID = $ARGUMENT_1
$API_ID = $ARGUMENT_2
$API_KEY = $ARGUMENT_3

$ApiKeyPreview = if ($API_KEY.Length -gt 5) { $API_KEY.Substring(0, 5) + "..." } else { "***" }

Write-LogMessage "API call parameters:"
Write-LogMessage "  Site ID: $SITE_ID"
Write-LogMessage "  API ID: $API_ID"
Write-LogMessage "  API Key: $ApiKeyPreview"

# Prepare JSON payload
Write-LogMessage "Preparing JSON payload with Base64 encoded data..."

$apiPayload = @{
    certificate = $CERT_CHAIN_BASE64
    private_key = $KEY_BASE64
    auth_type = $AUTH_TYPE
}

$jsonPayload = $apiPayload | ConvertTo-Json -Compress

Write-LogMessage "JSON payload prepared successfully"
Write-LogMessage "Total payload size: $($jsonPayload.Length) characters"

# Prepare truncated payload for logging
$certForLog = if ($CERT_CHAIN_BASE64.Length -gt 100) { 
    $CERT_CHAIN_BASE64.Substring(0, 100) + "..."
} else { 
    $CERT_CHAIN_BASE64 
}

$keyForLog = if ($KEY_BASE64.Length -gt 100) { 
    $KEY_BASE64.Substring(0, 100) + "..."
} else { 
    "***" 
}

# Log the complete curl command equivalent to api-call.log
Write-ApiCallLog "=========================================="
Write-ApiCallLog "COMPLETE API CALL (PowerShell Invoke-RestMethod):"
Write-ApiCallLog "=========================================="
Write-ApiCallLog "URL: https://my.imperva.com/api/prov/v2/sites/$SITE_ID/customCertificate"
Write-ApiCallLog "Method: PUT"
Write-ApiCallLog "Headers:"
Write-ApiCallLog "  Content-Type: application/json"
Write-ApiCallLog "  x-API-Id: $API_ID"
Write-ApiCallLog "  x-API-Key: $ApiKeyPreview"
Write-ApiCallLog "Payload:"
Write-ApiCallLog "  certificate (Base64): $certForLog"
Write-ApiCallLog "  private_key (Base64): $keyForLog"
Write-ApiCallLog "  auth_type: $AUTH_TYPE"
Write-ApiCallLog "=========================================="
Write-ApiCallLog "Note: Certificate and key are Base64 encoded entire PEM files (including headers/footers)"
Write-ApiCallLog "Certificate chain contains $certCount certificate(s)"
Write-ApiCallLog "=========================================="

# Make API call to Imperva
Write-LogMessage "=========================================="
Write-LogMessage "Making API call to Imperva with Base64 encoded certificate chain..."
Write-LogMessage "URL: https://my.imperva.com/api/prov/v2/sites/$SITE_ID/customCertificate"
Write-LogMessage "Method: PUT"
Write-LogMessage "Headers:"
Write-LogMessage "  Content-Type: application/json"
Write-LogMessage "  x-API-Id: $API_ID"
Write-LogMessage "  x-API-Key: $ApiKeyPreview"
Write-LogMessage "Payload preview (truncated):"
Write-LogMessage "  certificate (Base64): $certForLog"
Write-LogMessage "  private_key (Base64): $keyForLog"
Write-LogMessage "  auth_type: $AUTH_TYPE"
Write-LogMessage "Certificate chain info:"
Write-LogMessage "  Number of certificates in chain: $certCount"
Write-LogMessage "  Base64 encoded size: $($CERT_CHAIN_BASE64.Length) characters"
Write-LogMessage "  Private key Base64 size: $($KEY_BASE64.Length) characters"
Write-LogMessage "See $API_CALL_LOGFILE for complete API call details"
Write-LogMessage "=========================================="

# Make the actual API call
try {
    # Prepare headers
    $headers = @{
        'Content-Type' = 'application/json'
        'x-API-Key' = $API_KEY
        'x-API-Id' = $API_ID
    }
    
    # Prepare URI
    $uri = "https://my.imperva.com/api/prov/v2/sites/$SITE_ID/customCertificate"
    
    # For PowerShell 5.x, we'll use Invoke-RestMethod with error handling
    $response = $null
    $statusCode = $null
    $errorDetails = $null
    
    try {
        # PowerShell 5.x doesn't have -StatusCodeVariable, so we use different approach
        $response = Invoke-RestMethod -Uri $uri -Method Put -Headers $headers -Body $jsonPayload -ErrorAction Stop
        $statusCode = 200  # If successful, assume 200
        Write-LogMessage "API call completed successfully"
    }
    catch {
        $errorDetails = $_
        
        # Try to extract status code from error
        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }
        else {
            $statusCode = 0
        }
        
        # Try to get response body from error
        if ($_.ErrorDetails.Message) {
            $response = $_.ErrorDetails.Message
        }
        elseif ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $response = $reader.ReadToEnd()
            $reader.Close()
        }
        else {
            $response = $_.Exception.Message
        }
    }
    
    Write-LogMessage "HTTP Status Code: $statusCode"
    
    if ($response) {
        $responseJson = $response | ConvertTo-Json -Compress -ErrorAction SilentlyContinue
        if ($responseJson) {
            Write-LogMessage "Response Body: $responseJson"
        }
        else {
            Write-LogMessage "Response Body: $response"
        }
    }
    
    # Check if API call was successful
    if ($statusCode -eq 200 -or $statusCode -eq 201) {
        Write-LogMessage "SUCCESS: Certificate chain uploaded successfully to Imperva"
        Write-LogMessage "Certificate chain with $certCount certificate(s) has been installed"
    }
    else {
        Write-LogMessage "ERROR: API call failed with status $statusCode"
        
        if ($response) {
            Write-LogMessage "Response: $response"
            
            # Additional debugging for common issues
            if ($response -match "certificate") {
                Write-LogMessage "DEBUG: Error appears to be certificate-related"
                Write-LogMessage "DEBUG: Verify that the certificate chain is in correct order (domain -> intermediate -> root)"
            }
            if ($response -match "private|key") {
                Write-LogMessage "DEBUG: Error appears to be private key-related"
                Write-LogMessage "DEBUG: Verify that the private key matches the certificate"
            }
            if ($response -match "auth_type") {
                Write-LogMessage "DEBUG: Error appears to be auth_type-related"
                Write-LogMessage "DEBUG: Current auth_type: $AUTH_TYPE"
            }
        }
    }
}
catch {
    Write-LogMessage "ERROR: Failed to make API call: $_"
    if ($_.Exception.Message) {
        Write-LogMessage "Exception details: $($_.Exception.Message)"
    }
    exit 1
}

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "Summary:"
Write-LogMessage "  Certificate file: $CRT_FILE_PATH"
Write-LogMessage "  Private key file: $KEY_FILE_PATH"
Write-LogMessage "  Certificates in chain: $certCount"
Write-LogMessage "  Auth type: $AUTH_TYPE"
Write-LogMessage "  API endpoint: https://my.imperva.com/api/prov/v2/sites/$SITE_ID/customCertificate"
Write-LogMessage "  HTTP status: $statusCode"

if ($statusCode -eq 200 -or $statusCode -eq 201) {
    Write-LogMessage "  Result: SUCCESS - Certificate chain uploaded"
} else {
    Write-LogMessage "  Result: FAILED - Check response for details"
}

Write-LogMessage "=========================================="

# ============================================================================
# ADDITIONAL CUSTOM LOGIC SECTION
# You can add additional custom logic here if needed
# ============================================================================

# Example: Send notification email on success (commented out)
# if (($statusCode -eq 200 -or $statusCode -eq 201) -and $ARGUMENT_4 -eq "notify") {
#     $emailTo = $ARGUMENT_5
#     if (-not [string]::IsNullOrEmpty($emailTo)) {
#         $subject = "Certificate Deployment to Imperva - $env:COMPUTERNAME"
#         $body = @"
# Certificate successfully deployed to Imperva
# Site ID: $SITE_ID
# Certificate: $CRT_FILE_PATH
# Key: $KEY_FILE_PATH
# Time: $(Get-Date)
# "@
#         
#         Send-MailMessage `
#             -To $emailTo `
#             -From "admin@example.com" `
#             -Subject $subject `
#             -Body $body `
#             -SmtpServer "smtp.example.com"
#         
#         Write-LogMessage "Notification sent to: $emailTo"
#     }
# }

Write-LogMessage "=========================================="
Write-LogMessage "All operations completed"
Write-LogMessage "=========================================="

exit 0