# PowerShell 6+ / Windows Server 2025 Cloudflare Certificate Upload Script

<#
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
$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\Program Files\DigiCert\tlm_agent_3.1.2_win64\log\cloudflare-awr.log"

$BUNDLE_METHOD = "force"  # Can be "ubiquitous", "optimal", or "force"

# Debug mode flag - set to "true" to enable detailed logging
# WARNING: This will log sensitive information including full AUTH_TOKEN
# Only use in testing/development environments
$DEBUG_MODE = "false"  # Set to "true" to enable debug logging

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    
    # Ensure log directory exists
    $logDir = Split-Path $LOGFILE -Parent
    if (!(Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    Add-Content -Path $LOGFILE -Value $logEntry
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting Cloudflare certificate upload script"
if ($DEBUG_MODE -eq "true") {
    Write-LogMessage "DEBUG MODE ENABLED"
}
Write-LogMessage "=========================================="

# Check legal notice acceptance
Write-LogMessage "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-LogMessage "ERROR: Legal notice not accepted. Set `$LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
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
Write-LogMessage "  Default BUNDLE_METHOD: $BUNDLE_METHOD"

# Log environment variable check
Write-LogMessage "Checking DC1_POST_SCRIPT_DATA environment variable..."
$DC1_POST_SCRIPT_DATA = $env:DC1_POST_SCRIPT_DATA
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
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($CERT_INFO))
    if ($DEBUG_MODE -eq "true") {
        Write-LogMessage "Decoded JSON_STRING: $JSON_STRING"
    } else {
        Write-LogMessage "JSON_STRING decoded successfully"
    }
} catch {
    Write-LogMessage "ERROR: Failed to decode base64 JSON string: $($_.Exception.Message)"
    exit 1
}

# Extract arguments from JSON
Write-LogMessage "Extracting arguments from JSON..."

try {
    $jsonObject = $JSON_STRING | ConvertFrom-Json
    
    if ($DEBUG_MODE -eq "true") {
        Write-LogMessage "Raw args array: $($jsonObject.args -join ',')"
    }
    
    # Extract ZONE_ID - first argument
    $ZONE_ID = $jsonObject.args[0].ToString().Trim()
    if ($DEBUG_MODE -eq "true") {
        Write-LogMessage "Raw ZONE_ID after extraction: '$ZONE_ID'"
    }
    Write-LogMessage "ZONE_ID length: $($ZONE_ID.Length)"
    
    # Extract AUTH_TOKEN - second argument
    $AUTH_TOKEN = $jsonObject.args[1].ToString().Trim()
    if ($DEBUG_MODE -eq "true") {
        Write-LogMessage "Raw AUTH_TOKEN after extraction (full): '$AUTH_TOKEN'"
    }
    Write-LogMessage "AUTH_TOKEN length: $($AUTH_TOKEN.Length)"
    
    # Extract BUNDLE_METHOD - third argument (if provided)
    if ($jsonObject.args.Count -gt 2 -and ![string]::IsNullOrEmpty($jsonObject.args[2])) {
        $BUNDLE_METHOD = $jsonObject.args[2].ToString().Trim()
        Write-LogMessage "BUNDLE_METHOD extracted from args: $BUNDLE_METHOD"
    }
    
} catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $($_.Exception.Message)"
    exit 1
}

# Log extracted arguments
Write-LogMessage "Extracted arguments:"
Write-LogMessage "  ZONE_ID: '$ZONE_ID'"
# Mask auth token for security - show only first and last 4 characters
if (![string]::IsNullOrEmpty($AUTH_TOKEN)) {
    if ($AUTH_TOKEN.Length -gt 8) {
        $AUTH_TOKEN_MASKED = $AUTH_TOKEN.Substring(0, 4) + "..." + $AUTH_TOKEN.Substring($AUTH_TOKEN.Length - 4)
    } else {
        $AUTH_TOKEN_MASKED = "***masked***"
    }
    Write-LogMessage "  AUTH_TOKEN: '$AUTH_TOKEN_MASKED' (masked for security)"
    if ($DEBUG_MODE -eq "true") {
        # Also log hex dump of first few chars to check for hidden characters
        $firstChars = $AUTH_TOKEN.Substring(0, [Math]::Min(10, $AUTH_TOKEN.Length))
        $hexDump = [System.BitConverter]::ToString([System.Text.Encoding]::UTF8.GetBytes($firstChars)).Replace("-", "")
        Write-LogMessage "  AUTH_TOKEN first 10 chars hex: $hexDump"
    }
} else {
    Write-LogMessage "  AUTH_TOKEN: [empty]"
}
Write-LogMessage "  BUNDLE_METHOD: '$BUNDLE_METHOD'"

# Validate and clean AUTH_TOKEN and ZONE_ID
Write-LogMessage "Validating extracted values..."

# Remove any potential whitespace, newlines, or carriage returns
$ZONE_ID = $ZONE_ID -replace '\s', ''
$AUTH_TOKEN = $AUTH_TOKEN -replace '\s', ''

# Validate ZONE_ID format (should be 32 characters, alphanumeric)
if ($ZONE_ID -notmatch '^[a-zA-Z0-9]{32}$') {
    Write-LogMessage "WARNING: ZONE_ID format seems invalid. Expected 32 alphanumeric characters, got: '$ZONE_ID' (length: $($ZONE_ID.Length))"
}

# Validate AUTH_TOKEN format (typically 40 characters, alphanumeric with possible special chars)
if ($AUTH_TOKEN.Length -lt 30 -or $AUTH_TOKEN.Length -gt 50) {
    Write-LogMessage "WARNING: AUTH_TOKEN length seems unusual. Got length: $($AUTH_TOKEN.Length)"
}

# Extract cert folder
try {
    $CERT_FOLDER = $jsonObject.certfolder
    Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"
} catch {
    Write-LogMessage "ERROR: Failed to extract cert folder from JSON"
    exit 1
}

# Extract the .crt file name
try {
    $CRT_FILE = $jsonObject.files | Where-Object { $_ -like "*.crt" } | Select-Object -First 1
    Write-LogMessage "Extracted CRT_FILE: $CRT_FILE"
} catch {
    Write-LogMessage "ERROR: Failed to extract .crt file from JSON"
    exit 1
}

# Extract the .key file name
try {
    $KEY_FILE = $jsonObject.files | Where-Object { $_ -like "*.key" } | Select-Object -First 1
    Write-LogMessage "Extracted KEY_FILE: $KEY_FILE"
} catch {
    Write-LogMessage "ERROR: Failed to extract .key file from JSON"
    exit 1
}

# Construct file paths
$CRT_FILE_PATH = Join-Path $CERT_FOLDER $CRT_FILE
$KEY_FILE_PATH = Join-Path $CERT_FOLDER $KEY_FILE
Write-LogMessage "Constructed file paths:"
Write-LogMessage "  CRT_FILE_PATH: $CRT_FILE_PATH"
Write-LogMessage "  KEY_FILE_PATH: $KEY_FILE_PATH"

# Check if files exist
if (Test-Path $CRT_FILE_PATH) {
    $certSize = (Get-Item $CRT_FILE_PATH).Length
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    Write-LogMessage "Certificate file size: $certSize bytes"
} else {
    Write-LogMessage "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (Test-Path $KEY_FILE_PATH) {
    $keySize = (Get-Item $KEY_FILE_PATH).Length
    Write-LogMessage "Key file exists: $KEY_FILE_PATH"
    Write-LogMessage "Key file size: $keySize bytes"
} else {
    Write-LogMessage "ERROR: Key file not found: $KEY_FILE_PATH"
    exit 1
}

# Read certificate and key using dynamically constructed paths
Write-LogMessage "Reading certificate and key files..."
try {
    $CERT_RAW = Get-Content $CRT_FILE_PATH -Raw
    $KEY_RAW = Get-Content $KEY_FILE_PATH -Raw
    
    # Convert to JSON-safe format (escape newlines)
    $CERT = $CERT_RAW -replace "`r`n", "\n" -replace "`n", "\n"
    $KEY = $KEY_RAW -replace "`r`n", "\n" -replace "`n", "\n"
    
    # Log certificate and key lengths
    Write-LogMessage "Certificate content length: $($CERT.Length) characters"
    Write-LogMessage "Key content length: $($KEY.Length) characters"
    
    if ($DEBUG_MODE -eq "true") {
        # Show first and last few characters of cert and key for debugging
        $certStart = $CERT.Substring(0, [Math]::Min(50, $CERT.Length))
        $certEnd = $CERT.Substring([Math]::Max(0, $CERT.Length - 50))
        $keyStart = $KEY.Substring(0, [Math]::Min(50, $KEY.Length))
        $keyEnd = $KEY.Substring([Math]::Max(0, $KEY.Length - 50))
        
        Write-LogMessage "Certificate starts with: $certStart..."
        Write-LogMessage "Certificate ends with: ...$certEnd"
        Write-LogMessage "Key starts with: $keyStart..."
        Write-LogMessage "Key ends with: ...$keyEnd"
    }
} catch {
    Write-LogMessage "ERROR: Failed to read certificate or key files: $($_.Exception.Message)"
    exit 1
}

# Prepare API payload
$apiPayloadObject = @{
    certificate = $CERT
    private_key = $KEY
    bundle_method = $BUNDLE_METHOD
}

$API_PAYLOAD = $apiPayloadObject | ConvertTo-Json -Depth 10

# Log API call details
Write-LogMessage "Preparing Cloudflare API call..."
$apiUrl = "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/custom_certificates"
Write-LogMessage "API Endpoint: $apiUrl"
Write-LogMessage "Bundle method: $BUNDLE_METHOD"

# Debug: Show the exact request details being used (with masked token)
if ($DEBUG_MODE -eq "true") {
    Write-LogMessage "Debug - Request details:"
    Write-LogMessage "  URL: $apiUrl"
    Write-LogMessage "  Authorization header: Bearer $AUTH_TOKEN_MASKED"
    Write-LogMessage "  Content-Type: application/json"
}

# Make the API call
Write-LogMessage "Making API call to Cloudflare..."

try {
    $headers = @{
        'Authorization' = "Bearer $AUTH_TOKEN"
        'Content-Type' = 'application/json'
    }
    
    $response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers -Body $API_PAYLOAD -StatusCodeVariable statusCode
    
    # Log the response
    Write-LogMessage "API call completed"
    Write-LogMessage "HTTP Status Code: $statusCode"
    
    $responseJson = $response | ConvertTo-Json -Depth 10
    Write-LogMessage "API Response: $responseJson"
    
    # Parse response for success/error
    if ($response.success -eq $true) {
        Write-LogMessage "SUCCESS: Certificate uploaded successfully"
        # Try to extract certificate ID if available
        if ($response.result -and $response.result.id) {
            Write-LogMessage "Certificate ID: $($response.result.id)"
        }
        $exitCode = 0
    } else {
        Write-LogMessage "ERROR: Certificate upload failed"
        # Try to extract error messages
        if ($response.errors) {
            foreach ($error in $response.errors) {
                Write-LogMessage "Error message: $($error.message)"
            }
        }
        $exitCode = 1
    }
    
} catch {
    Write-LogMessage "ERROR: API call failed: $($_.Exception.Message)"
    
    # Try to extract status code from exception
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
        Write-LogMessage "HTTP Status Code: $statusCode"
    }
    
    # Try to read response body for more error details
    if ($_.Exception.Response -and $_.Exception.Response.GetResponseStream) {
        try {
            $streamReader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $streamReader.ReadToEnd()
            Write-LogMessage "Error response body: $responseBody"
        } catch {
            Write-LogMessage "Could not read error response body"
        }
    }
    
    $exitCode = 1
}

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

# Exit with appropriate code
exit $exitCode