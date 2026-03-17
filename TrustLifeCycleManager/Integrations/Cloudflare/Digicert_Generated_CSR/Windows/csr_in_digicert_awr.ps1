<#
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

<#
.SYNOPSIS
    Uploads SSL certificates to Cloudflare using the Cloudflare API
    
.DESCRIPTION
    This script is designed to work with DigiCert TLM Agent to automatically upload
    certificates to Cloudflare. It supports both Custom Legacy and Custom Modern certificate types.
    
.PARAMETER ZONE_ID
    The Cloudflare Zone ID (passed via DC1_POST_SCRIPT_DATA environment variable)
    
.PARAMETER AUTH_TOKEN
    The Cloudflare API authentication token (passed via DC1_POST_SCRIPT_DATA environment variable)
    
.PARAMETER BUNDLE_METHOD
    Certificate bundling method: "ubiquitous", "optimal", or "force"
    Default: "force"
    
.PARAMETER CERT_DELETE_MODE
    Certificate deletion strategy:
    - "none": Don't delete any existing certificates
    - "all": Delete all existing certificates before uploading
    - "matching": Only delete certificates covering the same hostname(s)
    Default: "matching"
    
.PARAMETER CERTIFICATE_TYPE
    Certificate type to upload:
    - "legacy_custom": Custom Legacy (supports non-SNI clients, broader compatibility)
    - "sni_custom": Custom Modern (SNI required, recommended for modern setups)
    Default: "sni_custom"
    
.NOTES
    The script accepts parameters through the DC1_POST_SCRIPT_DATA environment variable
    as a base64-encoded JSON object. The args array should contain:
    1. Zone ID (required)
    2. Auth Token (required)
    3. Bundle Method (optional)
    4. Certificate Delete Mode (optional)
    5. Certificate Type (optional)
#>

# ========================================
# Configuration
# ========================================
$LEGAL_NOTICE_ACCEPT = "false"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\cloudflare-awr.log"

$BUNDLE_METHOD = "force"  # Can be "ubiquitous", "optimal", or "force"

# Certificate type configuration:
# "legacy_custom" - Custom Legacy (supports non-SNI clients, broader compatibility)
# "sni_custom" - Custom Modern (SNI required, recommended for modern setups)
$CERTIFICATE_TYPE = "sni_custom"  # Default: "sni_custom" (Custom Modern)

# Certificate deletion strategy:
# "none" - Don't delete any existing certificates (accumulate all)
# "all" - Delete all existing certificates before uploading
# "matching" - Only delete certificates that cover the same hostname(s) being uploaded
$CERT_DELETE_MODE = "matching"  # Recommended: "none" to keep multiple certificates

# Debug mode flag - set to "true" to enable detailed logging
# WARNING: This will log sensitive information including full AUTH_TOKEN
# Only use in testing/development environments
$DEBUG_MODE = "false"  # Set to "true" to enable debug logging

# ========================================
# OpenSSL Configuration
# ========================================
# Hardcoded path (recommended for TLM Agent to ensure reliability)
$OPENSSL_PATH = "C:\Program Files\OpenSSL-Win64\bin\openssl.exe"

# If hardcoded path doesn't exist, try auto-detection
if (-not (Test-Path $OPENSSL_PATH -ErrorAction SilentlyContinue)) {
    $OPENSSL_PATH = $null
    
    # Try common installation paths
    $possiblePaths = @(
        "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
        "C:\Program Files\OpenSSL\bin\openssl.exe",
        "C:\OpenSSL-Win64\bin\openssl.exe",
        "${env:ProgramFiles}\OpenSSL-Win64\bin\openssl.exe",
        "${env:ProgramFiles(x86)}\OpenSSL-Win32\bin\openssl.exe",
        "C:\Program Files (x86)\OpenSSL-Win32\bin\openssl.exe"
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $OPENSSL_PATH = $path
            break
        }
    }
    
    # If not found in common paths, check if it's in PATH
    if (-not $OPENSSL_PATH) {
        $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($opensslCmd) {
            $OPENSSL_PATH = $opensslCmd.Source
        }
    }
}

# Function to check if OpenSSL is available
function Test-OpenSSLAvailable {
    return ($null -ne $script:OPENSSL_PATH -and (Test-Path $script:OPENSSL_PATH))
}

# ========================================
# Logging Function
# ========================================
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    
    # Ensure log directory exists
    $logDir = Split-Path $script:LOGFILE -Parent
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Add-Content -Path $script:LOGFILE -Value $logEntry
}

# ========================================
# Start Script Execution
# ========================================
Write-Log "=========================================="
Write-Log "Starting Cloudflare certificate upload script"
Write-Log "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Log "PowerShell Edition: $($PSVersionTable.PSEdition)"
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Write-Log "NOTE: Running on Windows PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
    Write-Log "For best compatibility, consider using PowerShell 7+ (pwsh.exe)"
}
if ($DEBUG_MODE -eq "true") {
    Write-Log "DEBUG MODE ENABLED"
}
Write-Log "=========================================="

# Check legal notice acceptance
Write-Log "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-Log "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT='true' to proceed."
    Write-Log "Script execution terminated due to legal notice non-acceptance."
    Write-Log "=========================================="
    exit 1
}
else {
    Write-Log "Legal notice accepted, proceeding with script execution."
}

# Log initial configuration
Write-Log "Configuration:"
Write-Log "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Write-Log "  LOGFILE: $LOGFILE"
Write-Log "  Default BUNDLE_METHOD: $BUNDLE_METHOD"
Write-Log "  CERTIFICATE_TYPE: $CERTIFICATE_TYPE"
Write-Log "  CERT_DELETE_MODE: $CERT_DELETE_MODE"

# Log OpenSSL status
if (Test-OpenSSLAvailable) {
    Write-Log "  OpenSSL found: $OPENSSL_PATH"
    if ($DEBUG_MODE -eq "true") {
        try {
            $opensslVersion = & $OPENSSL_PATH version 2>$null
            Write-Log "  OpenSSL version: $opensslVersion"
        } catch {
            Write-Log "  OpenSSL version: Could not determine"
        }
    }
} else {
    Write-Log "  OpenSSL: Not found (hostname matching will be disabled for 'matching' mode)"
}

# Log environment variable check
Write-Log "Checking DC1_POST_SCRIPT_DATA environment variable..."
$CERT_INFO = $env:DC1_POST_SCRIPT_DATA
if ([string]::IsNullOrEmpty($CERT_INFO)) {
    Write-Log "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
}
else {
    Write-Log "DC1_POST_SCRIPT_DATA is set (length: $($CERT_INFO.Length) characters)"
}

Write-Log "CERT_INFO length: $($CERT_INFO.Length) characters"

# Decode JSON string
try {
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($CERT_INFO))
    if ($DEBUG_MODE -eq "true") {
        Write-Log "Decoded JSON_STRING: $JSON_STRING"
    }
    else {
        Write-Log "JSON_STRING decoded successfully"
    }
}
catch {
    Write-Log "ERROR: Failed to decode base64 data: $_"
    exit 1
}

# Extract arguments from JSON
Write-Log "Extracting arguments from JSON..."

try {
    $JSON_DATA = $JSON_STRING | ConvertFrom-Json
    
    # Extract arguments
    $ZONE_ID = $JSON_DATA.args[0].ToString().Trim()
    $AUTH_TOKEN = $JSON_DATA.args[1].ToString().Trim()
    
    if ($DEBUG_MODE -eq "true") {
        Write-Log "Raw ZONE_ID after extraction: '$ZONE_ID'"
    }
    Write-Log "ZONE_ID length: $($ZONE_ID.Length)"
    
    if ($DEBUG_MODE -eq "true") {
        Write-Log "Raw AUTH_TOKEN after extraction (full): '$AUTH_TOKEN'"
    }
    Write-Log "AUTH_TOKEN length: $($AUTH_TOKEN.Length)"
    
    # Extract BUNDLE_METHOD - third argument (if provided)
    if ($JSON_DATA.args.Count -ge 3 -and ![string]::IsNullOrWhiteSpace($JSON_DATA.args[2])) {
        $BUNDLE_METHOD = $JSON_DATA.args[2].ToString().Trim()
        Write-Log "BUNDLE_METHOD extracted from args: $BUNDLE_METHOD"
    }
    
    # Extract CERT_DELETE_MODE - fourth argument (if provided)
    if ($JSON_DATA.args.Count -ge 4 -and ![string]::IsNullOrWhiteSpace($JSON_DATA.args[3])) {
        $CERT_DELETE_MODE = $JSON_DATA.args[3].ToString().Trim()
        Write-Log "CERT_DELETE_MODE extracted from args: $CERT_DELETE_MODE"
    }
    
    # Extract CERTIFICATE_TYPE - fifth argument (if provided)
    if ($JSON_DATA.args.Count -ge 5 -and ![string]::IsNullOrWhiteSpace($JSON_DATA.args[4])) {
        $CERTIFICATE_TYPE = $JSON_DATA.args[4].ToString().Trim()
        Write-Log "CERTIFICATE_TYPE extracted from args: $CERTIFICATE_TYPE"
        
        # Validate certificate type
        if ($CERTIFICATE_TYPE -ne "legacy_custom" -and $CERTIFICATE_TYPE -ne "sni_custom") {
            Write-Log "WARNING: Invalid CERTIFICATE_TYPE '$CERTIFICATE_TYPE'. Using default 'sni_custom'"
            $CERTIFICATE_TYPE = "sni_custom"
        }
    }
}
catch {
    Write-Log "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Log extracted arguments
Write-Log "Extracted arguments:"
Write-Log "  ZONE_ID: '$ZONE_ID'"

# Mask auth token for security
if (![string]::IsNullOrEmpty($AUTH_TOKEN)) {
    if ($AUTH_TOKEN.Length -gt 8) {
        $AUTH_TOKEN_MASKED = $AUTH_TOKEN.Substring(0, 4) + "..." + $AUTH_TOKEN.Substring($AUTH_TOKEN.Length - 4)
    }
    else {
        $AUTH_TOKEN_MASKED = "***masked***"
    }
    Write-Log "  AUTH_TOKEN: '$AUTH_TOKEN_MASKED' (masked for security)"
    
    if ($DEBUG_MODE -eq "true") {
        $hexBytes = [BitConverter]::ToString([System.Text.Encoding]::UTF8.GetBytes($AUTH_TOKEN.Substring(0, [Math]::Min(10, $AUTH_TOKEN.Length))))
        Write-Log "  AUTH_TOKEN first 10 chars hex: $hexBytes"
    }
}
else {
    Write-Log "  AUTH_TOKEN: [empty]"
}

Write-Log "  BUNDLE_METHOD: '$BUNDLE_METHOD'"
Write-Log "  CERT_DELETE_MODE: '$CERT_DELETE_MODE'"
Write-Log "  CERTIFICATE_TYPE: '$CERTIFICATE_TYPE' $(if($CERTIFICATE_TYPE -eq 'legacy_custom'){'(Custom Legacy)'} else {'(Custom Modern - SNI required)'})"

# Validate and clean AUTH_TOKEN and ZONE_ID
Write-Log "Validating extracted values..."

$ZONE_ID = $ZONE_ID -replace '\s', ''
$AUTH_TOKEN = $AUTH_TOKEN -replace '\s', ''

# Validate ZONE_ID format (should be 32 characters, alphanumeric)
if ($ZONE_ID -notmatch '^[a-zA-Z0-9]{32}$') {
    Write-Log "WARNING: ZONE_ID format seems invalid. Expected 32 alphanumeric characters, got: '$ZONE_ID' (length: $($ZONE_ID.Length))"
}

# Validate AUTH_TOKEN format
if ($AUTH_TOKEN.Length -lt 30 -or $AUTH_TOKEN.Length -gt 50) {
    Write-Log "WARNING: AUTH_TOKEN length seems unusual. Got length: $($AUTH_TOKEN.Length)"
}

# Validate CERT_DELETE_MODE
if ($CERT_DELETE_MODE -notmatch '^(none|all|matching)$') {
    Write-Log "WARNING: Invalid CERT_DELETE_MODE '$CERT_DELETE_MODE'. Must be 'none', 'all', or 'matching'. Defaulting to 'none'."
    $CERT_DELETE_MODE = "none"
}

# Extract cert folder
$CERT_FOLDER = $JSON_DATA.certfolder
Write-Log "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .crt and .key file names
$CRT_FILE = $JSON_DATA.files | Where-Object { $_ -like "*.crt" } | Select-Object -First 1
$KEY_FILE = $JSON_DATA.files | Where-Object { $_ -like "*.key" } | Select-Object -First 1

Write-Log "Extracted CRT_FILE: $CRT_FILE"
Write-Log "Extracted KEY_FILE: $KEY_FILE"

# Construct file paths
$CRT_FILE_PATH = Join-Path $CERT_FOLDER $CRT_FILE
$KEY_FILE_PATH = Join-Path $CERT_FOLDER $KEY_FILE

Write-Log "Constructed file paths:"
Write-Log "  CRT_FILE_PATH: $CRT_FILE_PATH"
Write-Log "  KEY_FILE_PATH: $KEY_FILE_PATH"

# Check if files exist
if (Test-Path $CRT_FILE_PATH) {
    $certSize = (Get-Item $CRT_FILE_PATH).Length
    Write-Log "Certificate file exists: $CRT_FILE_PATH"
    Write-Log "Certificate file size: $certSize bytes"
}
else {
    Write-Log "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (Test-Path $KEY_FILE_PATH) {
    $keySize = (Get-Item $KEY_FILE_PATH).Length
    Write-Log "Key file exists: $KEY_FILE_PATH"
    Write-Log "Key file size: $keySize bytes"
}
else {
    Write-Log "ERROR: Key file not found: $KEY_FILE_PATH"
    exit 1
}

# Read certificate and key
Write-Log "Reading certificate and key files..."
try {
    # Read the files as raw text - let PowerShell handle the line endings naturally
    $CERT = Get-Content $CRT_FILE_PATH -Raw
    $KEY = Get-Content $KEY_FILE_PATH -Raw
    
    # Remove trailing whitespace only
    $CERT = $CERT.TrimEnd()
    $KEY = $KEY.TrimEnd()
    
    Write-Log "Certificate content length: $($CERT.Length) characters"
    Write-Log "Key content length: $($KEY.Length) characters"
    
    if ($DEBUG_MODE -eq "true") {
        Write-Log "Certificate starts with: $($CERT.Substring(0, [Math]::Min(50, $CERT.Length)))..."
        Write-Log "Certificate ends with: ...$($CERT.Substring([Math]::Max(0, $CERT.Length - 50)))"
        Write-Log "Key starts with: $($KEY.Substring(0, [Math]::Min(50, $KEY.Length)))..."
        Write-Log "Key ends with: ...$($KEY.Substring([Math]::Max(0, $KEY.Length - 50)))"
    }
}
catch {
    Write-Log "ERROR: Failed to read certificate or key files: $_"
    exit 1
}

# Prepare API payload - let ConvertTo-Json handle all the escaping
$apiPayloadObject = @{
    certificate = $CERT
    private_key = $KEY
    bundle_method = $BUNDLE_METHOD
}

# Add certificate type if specified (only add if not default to maintain backwards compatibility)
# Note: Cloudflare API defaults to legacy_custom if type is not specified
if ($CERTIFICATE_TYPE -eq "sni_custom") {
    $apiPayloadObject["type"] = "sni_custom"
} elseif ($CERTIFICATE_TYPE -eq "legacy_custom") {
    # Explicitly set legacy_custom if that's what user wants
    $apiPayloadObject["type"] = "legacy_custom"
}

# Convert to JSON - PowerShell will automatically escape newlines properly
$API_PAYLOAD = $apiPayloadObject | ConvertTo-Json -Depth 10 -Compress

# Log API call details
Write-Log "Preparing Cloudflare API call..."
Write-Log "API Endpoint: https://api.cloudflare.com/client/v4/zones/$ZONE_ID/custom_certificates"
Write-Log "Bundle method: $BUNDLE_METHOD"
Write-Log "Certificate type: $CERTIFICATE_TYPE $(if($CERTIFICATE_TYPE -eq 'legacy_custom'){'(Custom Legacy - supports non-SNI clients)'} else {'(Custom Modern - SNI required)'})"

if ($DEBUG_MODE -eq "true") {
    $payloadSnippet = $API_PAYLOAD.Substring(0, [Math]::Min(200, $API_PAYLOAD.Length))
    Write-Log "API Payload snippet: $payloadSnippet..."
}

# ========================================
# CHECK FOR EXISTING CERTIFICATES AND DELETE (BASED ON MODE)
# ========================================

$headers = @{
    "Authorization" = "Bearer $AUTH_TOKEN"
    "Content-Type" = "application/json"
}

if ($CERT_DELETE_MODE -eq "none") {
    Write-Log "CERT_DELETE_MODE is 'none' - skipping certificate deletion check"
    Write-Log "New certificate will be added alongside any existing certificates"
}
elseif ($CERT_DELETE_MODE -eq "all" -or $CERT_DELETE_MODE -eq "matching") {
    Write-Log "Checking for existing certificates (mode: $CERT_DELETE_MODE)..."
    
    try {
        $listResponse = Invoke-WebRequest -Uri "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/custom_certificates" `
            -Method Get -Headers $headers -UseBasicParsing
        
        $existingCerts = ($listResponse.Content | ConvertFrom-Json).result
        
        if ($DEBUG_MODE -eq "true") {
            Write-Log "List certificates response: $($listResponse.Content)"
        }
        
        $CERT_IDS = @()
        
        if ($CERT_DELETE_MODE -eq "all") {
            Write-Log "Mode 'all': Will delete all existing certificates"
            $CERT_IDS = $existingCerts | ForEach-Object { $_.id }
        }
        elseif ($CERT_DELETE_MODE -eq "matching") {
            Write-Log "Mode 'matching': Will only delete certificates covering the same hostnames"
            
            # Check if OpenSSL is available for hostname extraction
            # Try to find OpenSSL again if not already found (in case PATH wasn't set during initial detection)
            if (-not (Test-OpenSSLAvailable)) {
                Write-Log "OpenSSL not found via initial detection, attempting runtime detection..."
                $opensslCmd = Get-Command openssl -ErrorAction SilentlyContinue
                if ($opensslCmd) {
                    $script:OPENSSL_PATH = $opensslCmd.Source
                    Write-Log "Found OpenSSL via runtime check: $($script:OPENSSL_PATH)"
                }
            }
            
            if (-not (Test-OpenSSLAvailable)) {
                Write-Log "WARNING: OpenSSL not available - cannot extract hostnames for matching"
                Write-Log "Current PATH: $env:PATH"
                Write-Log "Skipping certificate deletion. Consider:"
                Write-Log "  1. Installing OpenSSL and adding it to PATH"
                Write-Log "  2. Setting CERT_DELETE_MODE to 'none' (keep all certs) or 'all' (delete all)"
                Write-Log "  3. Hardcoding OPENSSL_PATH at the top of this script to: C:\Program Files\OpenSSL-Win64\bin\openssl.exe"
            }
            else {
                Write-Log "Extracting hostnames from new certificate using OpenSSL..."
                
                # Extract SANs from the new certificate
                try {
                    $tempCertPath = [System.IO.Path]::GetTempFileName()
                    $CERT | Out-File -FilePath $tempCertPath -Encoding ascii -NoNewline
                    
                    Write-Log "Using OpenSSL from: $OPENSSL_PATH"
                    $sanOutput = & $OPENSSL_PATH x509 -in $tempCertPath -noout -text 2>$null | Select-String -Pattern "DNS:" -Context 0, 1
                    $NEW_CERT_HOSTS = $sanOutput | ForEach-Object {
                        $_.Line -split ',' | ForEach-Object {
                            if ($_ -match 'DNS:([^\s,]+)') {
                                $matches[1]
                            }
                        }
                    } | Sort-Object -Unique
                    
                    Remove-Item $tempCertPath -Force -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Log "WARNING: Could not extract hostnames from new certificate: $_"
                    $NEW_CERT_HOSTS = @()
                }
                
                if ($NEW_CERT_HOSTS.Count -gt 0) {
                    Write-Log "New certificate covers hostnames: $($NEW_CERT_HOSTS -join ', ')"
                    
                    foreach ($cert in $existingCerts) {
                        $CURRENT_HOSTS = $cert.hosts | Sort-Object -Unique
                        
                        $matchFound = $false
                        foreach ($newHost in $NEW_CERT_HOSTS) {
                            foreach ($currentHost in $CURRENT_HOSTS) {
                                if ($newHost -eq $currentHost) {
                                    $matchFound = $true
                                    break
                                }
                            }
                            if ($matchFound) { break }
                        }
                        
                        if ($matchFound) {
                            Write-Log "Found matching certificate ID $($cert.id) covering: $($CURRENT_HOSTS -join ', ')"
                            $CERT_IDS += $cert.id
                        }
                    }
                    
                    if ($CERT_IDS.Count -eq 0) {
                        Write-Log "No certificates found with matching hostnames"
                    }
                }
                else {
                    Write-Log "WARNING: Could not extract hostnames from new certificate"
                    Write-Log "Skipping deletion to be safe"
                }
            }
        }
        
        if ($CERT_IDS.Count -gt 0) {
            Write-Log "Found $($CERT_IDS.Count) certificate(s) to delete"
            
            foreach ($certId in $CERT_IDS) {
                Write-Log "Deleting certificate ID: $certId"
                
                try {
                    $null = Invoke-WebRequest -Uri "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/custom_certificates/$certId" `
                        -Method Delete -Headers $headers -UseBasicParsing
                    
                    Write-Log "Successfully deleted certificate ID: $certId"
                }
                catch {
                    Write-Log "WARNING: Failed to delete certificate ID: $certId ($_)"
                    if ($DEBUG_MODE -eq "true") {
                        Write-Log "Delete response: $($_.Exception.Message)"
                    }
                }
            }
            
            Start-Sleep -Seconds 2
            Write-Log "Certificate deletion completed, proceeding with upload"
        }
        else {
            Write-Log "No certificates to delete, proceeding with upload"
        }
    }
    catch {
        Write-Log "WARNING: Could not check for existing certificates: $_"
        Write-Log "Proceeding with certificate upload anyway..."
    }
}

# ========================================
# UPLOAD NEW CERTIFICATE
# ========================================
Write-Log "Uploading new certificate..."

if ($DEBUG_MODE -eq "true") {
    Write-Log "Debug - API call structure:"
    Write-Log "  URL: https://api.cloudflare.com/client/v4/zones/$ZONE_ID/custom_certificates"
    Write-Log "  Authorization header: Bearer $AUTH_TOKEN_MASKED"
    Write-Log "  Content-Type: application/json"
}

try {
    # Use Invoke-WebRequest for better error handling
    $webResponse = Invoke-WebRequest -Uri "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/custom_certificates" `
        -Method Post -Headers $headers -Body $API_PAYLOAD -UseBasicParsing
    
    $statusCode = $webResponse.StatusCode
    $response = $webResponse.Content | ConvertFrom-Json
    
    Write-Log "API call completed"
    Write-Log "HTTP Status Code: $statusCode"
    Write-Log "API Response: $($response | ConvertTo-Json -Depth 10)"
    
    if ($response.success -eq $true) {
        Write-Log "SUCCESS: Certificate uploaded successfully"
        if ($response.result -and $response.result.id) {
            Write-Log "Certificate ID: $($response.result.id)"
        }
        $exitCode = 0
    }
    else {
        Write-Log "ERROR: Certificate upload failed"
        if ($response.errors) {
            foreach ($apiError in $response.errors) {
                Write-Log "Error message: $($apiError.message)"
            }
        }
        $exitCode = 1
    }
}
catch {
    Write-Log "ERROR: API call failed with exception"
    Write-Log "Exception: $($_.Exception.Message)"
    
    # Try to extract status code
    if ($_.Exception.Response) {
        try {
            $statusCode = [int]$_.Exception.Response.StatusCode
            Write-Log "HTTP Status Code: $statusCode"
        }
        catch {
            Write-Log "Could not extract HTTP status code"
        }
    }
    
    # Try to read detailed error response
    if ($_.Exception.Response) {
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            $responseBody = $reader.ReadToEnd()
            Write-Log "Error response body: $responseBody"
            $reader.Close()
            $stream.Close()
        }
        catch {
            Write-Log "Could not read error response body"
        }
    }
    
    $exitCode = 1
}

Write-Log "=========================================="
Write-Log "Script execution completed"
Write-Log "=========================================="

exit $exitCode