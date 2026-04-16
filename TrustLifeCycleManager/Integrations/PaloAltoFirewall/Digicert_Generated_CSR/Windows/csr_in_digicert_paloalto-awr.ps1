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

# Configuration
$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\palo-alto-awr.log"

# Palo Alto Configuration - MODIFY THESE VALUES
$PA_URL = "https://ec2-3-131-97-204.us-east-2.compute.amazonaws.com"
$PA_API_KEY = "< Add your Palo Alto API key here >"

# Certificate naming configuration
# Options: "common_name" or "manual"
#$CERT_NAME_METHOD = "common_name"  # Use certificate's common name
$CERT_NAME_METHOD = "manual"        # Use manually specified name

# If using manual method, specify the certificate name here
$MANUAL_CERT_NAME = "windows-ceaser-cert"

# Commit configuration after upload
$COMMIT_CONFIG = "true"  # Set to "true" to automatically commit after upload

# Passphrase for private key (if needed)
$PRIVATE_KEY_PASSPHRASE = ""

# Debug mode flag - set to "true" to enable detailed logging
# WARNING: This will log sensitive information including full API_KEY
# Only use in testing/development environments
$DEBUG_MODE = "false"  # Set to "true" to enable debug logging

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Out-File -FilePath $LOGFILE -Append -Encoding UTF8
}

# Function to extract common name from certificate
function Get-CommonName {
    param([string]$CertFile)
    
    try {
        # Check if openssl is available
        $opensslPath = Get-Command openssl -ErrorAction SilentlyContinue
        if ($null -eq $opensslPath) {
            Write-LogMessage "WARNING: OpenSSL not found. Cannot extract Common Name automatically."
            return ""
        }
        
        # Extract CN from certificate subject
        $subject = & openssl x509 -in $CertFile -noout -subject 2>$null
        if ($subject -match 'CN\s*=\s*([^,/]+)') {
            $commonName = $Matches[1].Trim()
            Write-LogMessage "Extracted Common Name: $commonName"
            return $commonName
        } else {
            Write-LogMessage "WARNING: Could not extract Common Name from certificate"
            return ""
        }
    }
    catch {
        Write-LogMessage "ERROR extracting Common Name: $_"
        return ""
    }
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting Palo Alto certificate upload script"
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
Write-LogMessage "  PA_URL: $PA_URL"

# Mask API key for security - show only first and last 4 characters
if (-not [string]::IsNullOrEmpty($PA_API_KEY)) {
    $PA_API_KEY_MASKED = $PA_API_KEY.Substring(0, 4) + "..." + $PA_API_KEY.Substring($PA_API_KEY.Length - 4)
    Write-LogMessage "  PA_API_KEY: '$PA_API_KEY_MASKED' (masked for security)"
} else {
    Write-LogMessage "  PA_API_KEY: [empty]"
}
Write-LogMessage "  CERT_NAME_METHOD: $CERT_NAME_METHOD"
Write-LogMessage "  MANUAL_CERT_NAME: $MANUAL_CERT_NAME"
Write-LogMessage "  COMMIT_CONFIG: $COMMIT_CONFIG"

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
    $decodedBytes = [System.Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
    
    if ($DEBUG_MODE -eq "true") {
        Write-LogMessage "Decoded JSON_STRING: $JSON_STRING"
    } else {
        Write-LogMessage "JSON_STRING decoded successfully"
    }
} catch {
    Write-LogMessage "ERROR: Failed to decode Base64 string: $_"
    exit 1
}

# Parse JSON
Write-LogMessage "Extracting certificate information from JSON..."
try {
    $jsonObject = $JSON_STRING | ConvertFrom-Json
    
    # Extract cert folder
    $CERT_FOLDER = $jsonObject.certfolder
    Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"
    
    # Extract the .crt file name
    $CRT_FILE = $jsonObject.files | Where-Object { $_ -like "*.crt" } | Select-Object -First 1
    Write-LogMessage "Extracted CRT_FILE: $CRT_FILE"
    
    # Extract the .key file name
    $KEY_FILE = $jsonObject.files | Where-Object { $_ -like "*.key" } | Select-Object -First 1
    Write-LogMessage "Extracted KEY_FILE: $KEY_FILE"
} catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Construct file paths
$CRT_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CRT_FILE
$KEY_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $KEY_FILE
Write-LogMessage "Constructed file paths:"
Write-LogMessage "  CRT_FILE_PATH: $CRT_FILE_PATH"
Write-LogMessage "  KEY_FILE_PATH: $KEY_FILE_PATH"

# Check if files exist
if (Test-Path -Path $CRT_FILE_PATH) {
    $crtFileInfo = Get-Item $CRT_FILE_PATH
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    Write-LogMessage "Certificate file size: $($crtFileInfo.Length) bytes"
} else {
    Write-LogMessage "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (Test-Path -Path $KEY_FILE_PATH) {
    $keyFileInfo = Get-Item $KEY_FILE_PATH
    Write-LogMessage "Key file exists: $KEY_FILE_PATH"
    Write-LogMessage "Key file size: $($keyFileInfo.Length) bytes"
} else {
    Write-LogMessage "ERROR: Key file not found: $KEY_FILE_PATH"
    exit 1
}

# Determine certificate name
if ($CERT_NAME_METHOD -eq "common_name") {
    $CERT_NAME = Get-CommonName -CertFile $CRT_FILE_PATH
    if ([string]::IsNullOrEmpty($CERT_NAME)) {
        Write-LogMessage "ERROR: Could not extract Common Name and CERT_NAME_METHOD is set to 'common_name'"
        Write-LogMessage "Please either fix the certificate or set CERT_NAME_METHOD to 'manual' and specify MANUAL_CERT_NAME"
        exit 1
    }
} elseif ($CERT_NAME_METHOD -eq "manual") {
    if ([string]::IsNullOrEmpty($MANUAL_CERT_NAME)) {
        Write-LogMessage "ERROR: CERT_NAME_METHOD is set to 'manual' but MANUAL_CERT_NAME is empty"
        exit 1
    }
    $CERT_NAME = $MANUAL_CERT_NAME
} else {
    Write-LogMessage "ERROR: Invalid CERT_NAME_METHOD: $CERT_NAME_METHOD. Must be 'common_name' or 'manual'"
    exit 1
}

Write-LogMessage "Using certificate name: $CERT_NAME"

# Skip certificate validation for self-signed certificates
Add-Type @"
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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Upload certificate
Write-LogMessage "Uploading certificate to Palo Alto..."
Write-LogMessage "API Endpoint: ${PA_URL}/api/"

if ($DEBUG_MODE -eq "true") {
    Write-LogMessage "Debug - Certificate upload parameters:"
    Write-LogMessage "  URL: ${PA_URL}/api/"
    Write-LogMessage "  API Key: $PA_API_KEY_MASKED"
    Write-LogMessage "  Certificate name: $CERT_NAME"
    Write-LogMessage "  Certificate file: $CRT_FILE_PATH"
}

try {
    # Prepare multipart form for certificate upload
    $certUri = "${PA_URL}/api/?key=${PA_API_KEY}&type=import&category=certificate&certificate-name=${CERT_NAME}&format=pem"
    
    # Read certificate file
    $certContent = Get-Content -Path $CRT_FILE_PATH -Raw
    
    # Create form data
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    
    $bodyLines = @(
        "--$boundary",
        "Content-Disposition: form-data; name=`"file`"; filename=`"$CRT_FILE`"",
        "Content-Type: application/octet-stream",
        "",
        $certContent,
        "--$boundary--"
    )
    $body = $bodyLines -join $LF
    
    $headers = @{
        "Content-Type" = "multipart/form-data; boundary=$boundary"
    }
    
    $certResponse = Invoke-WebRequest -Uri $certUri -Method Post -Headers $headers -Body $body -UseBasicParsing
    $CERT_HTTP_STATUS = $certResponse.StatusCode
    $CERT_RESPONSE = $certResponse.Content
    
    Write-LogMessage "Certificate upload completed"
    Write-LogMessage "Certificate HTTP Status Code: $CERT_HTTP_STATUS"
    Write-LogMessage "Certificate API Response: $CERT_RESPONSE"
} catch {
    $CERT_HTTP_STATUS = $_.Exception.Response.StatusCode.value__
    $CERT_RESPONSE = $_.Exception.Message
    Write-LogMessage "Certificate upload error: $_"
    Write-LogMessage "Certificate HTTP Status Code: $CERT_HTTP_STATUS"
    Write-LogMessage "Certificate API Response: $CERT_RESPONSE"
}

# Check certificate upload success
if ($CERT_HTTP_STATUS -eq 200 -or $CERT_HTTP_STATUS -eq 201) {
    Write-LogMessage "SUCCESS: Certificate uploaded successfully"
} else {
    Write-LogMessage "ERROR: Certificate upload failed with status $CERT_HTTP_STATUS"
    Write-LogMessage "Certificate response: $CERT_RESPONSE"
    exit 1
}

# Upload private key
Write-LogMessage "Uploading private key to Palo Alto..."

if ($DEBUG_MODE -eq "true") {
    Write-LogMessage "Debug - Private key upload parameters:"
    Write-LogMessage "  URL: ${PA_URL}/api/"
    Write-LogMessage "  API Key: $PA_API_KEY_MASKED"
    Write-LogMessage "  Certificate name: $CERT_NAME"
    Write-LogMessage "  Key file: $KEY_FILE_PATH"
    Write-LogMessage "  Passphrase: [present]"
}

try {
    # Prepare multipart form for private key upload
    $keyUri = "${PA_URL}/api/?key=${PA_API_KEY}&type=import&category=private-key&certificate-name=${CERT_NAME}&format=pem&passphrase=${PRIVATE_KEY_PASSPHRASE}"
    
    # Read key file
    $keyContent = Get-Content -Path $KEY_FILE_PATH -Raw
    
    # Create form data
    $boundary = [System.Guid]::NewGuid().ToString()
    $LF = "`r`n"
    
    $bodyLines = @(
        "--$boundary",
        "Content-Disposition: form-data; name=`"file`"; filename=`"$KEY_FILE`"",
        "Content-Type: application/octet-stream",
        "",
        $keyContent,
        "--$boundary--"
    )
    $body = $bodyLines -join $LF
    
    $headers = @{
        "Content-Type" = "multipart/form-data; boundary=$boundary"
    }
    
    $keyResponse = Invoke-WebRequest -Uri $keyUri -Method Post -Headers $headers -Body $body -UseBasicParsing
    $KEY_HTTP_STATUS = $keyResponse.StatusCode
    $KEY_RESPONSE = $keyResponse.Content
    
    Write-LogMessage "Private key upload completed"
    Write-LogMessage "Private key HTTP Status Code: $KEY_HTTP_STATUS"
    Write-LogMessage "Private key API Response: $KEY_RESPONSE"
} catch {
    $KEY_HTTP_STATUS = $_.Exception.Response.StatusCode.value__
    $KEY_RESPONSE = $_.Exception.Message
    Write-LogMessage "Private key upload error: $_"
    Write-LogMessage "Private key HTTP Status Code: $KEY_HTTP_STATUS"
    Write-LogMessage "Private key API Response: $KEY_RESPONSE"
}

# Check private key upload success
if ($KEY_HTTP_STATUS -eq 200 -or $KEY_HTTP_STATUS -eq 201) {
    Write-LogMessage "SUCCESS: Private key uploaded successfully"
} else {
    Write-LogMessage "ERROR: Private key upload failed with status $KEY_HTTP_STATUS"
    Write-LogMessage "Private key response: $KEY_RESPONSE"
    exit 1
}

# Commit configuration if enabled
if ($COMMIT_CONFIG -eq "true") {
    Write-LogMessage "Committing Palo Alto configuration..."
    
    if ($DEBUG_MODE -eq "true") {
        Write-LogMessage "Debug - Commit parameters:"
        Write-LogMessage "  URL: ${PA_URL}/api/"
        Write-LogMessage "  API Key: $PA_API_KEY_MASKED"
        Write-LogMessage "  Command: commit"
    }
    
    try {
        $commitUri = "${PA_URL}/api/?key=${PA_API_KEY}&type=commit&cmd=<commit></commit>"
        $commitResponse = Invoke-WebRequest -Uri $commitUri -Method Get -UseBasicParsing
        $COMMIT_HTTP_STATUS = $commitResponse.StatusCode
        $COMMIT_RESPONSE = $commitResponse.Content
        
        Write-LogMessage "Configuration commit completed"
        Write-LogMessage "Commit HTTP Status Code: $COMMIT_HTTP_STATUS"
        Write-LogMessage "Commit API Response: $COMMIT_RESPONSE"
    } catch {
        $COMMIT_HTTP_STATUS = $_.Exception.Response.StatusCode.value__
        $COMMIT_RESPONSE = $_.Exception.Message
        Write-LogMessage "Configuration commit error: $_"
        Write-LogMessage "Commit HTTP Status Code: $COMMIT_HTTP_STATUS"
        Write-LogMessage "Commit API Response: $COMMIT_RESPONSE"
    }
    
    # Check commit success
    if ($COMMIT_HTTP_STATUS -eq 200 -or $COMMIT_HTTP_STATUS -eq 201) {
        Write-LogMessage "SUCCESS: Configuration committed successfully"
    } else {
        Write-LogMessage "WARNING: Configuration commit failed with status $COMMIT_HTTP_STATUS"
        Write-LogMessage "Commit response: $COMMIT_RESPONSE"
        Write-LogMessage "Certificate and key were uploaded successfully, but commit failed"
    }
} else {
    Write-LogMessage "Configuration commit skipped (COMMIT_CONFIG is set to false)"
}

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

# Exit with appropriate code based on certificate and key upload status
# We consider the script successful if both cert and key uploads succeeded
# Commit failure is not considered a fatal error
if (($CERT_HTTP_STATUS -eq 200 -or $CERT_HTTP_STATUS -eq 201) -and 
    ($KEY_HTTP_STATUS -eq 200 -or $KEY_HTTP_STATUS -eq 201)) {
    exit 0
} else {
    exit 1
}