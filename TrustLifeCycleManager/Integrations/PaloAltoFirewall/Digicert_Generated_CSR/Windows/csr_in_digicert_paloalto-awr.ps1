<#
.SYNOPSIS
    DigiCert TLM Agent Palo Alto Certificate Upload Script (CRT/KEY Format) - PowerShell Version
.DESCRIPTION
    PowerShell AWR post-enrollment script for uploading certificates and private keys to Palo Alto firewalls via PAN-OS XML API
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
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\palo-alto-awr.log"

# Certificate naming configuration
# Options: "common_name" or "manual"
$CERT_NAME_METHOD = "common_name"

# If using manual method, specify the certificate name here
$MANUAL_CERT_NAME = "tf-automated-cert"

# Commit configuration after upload
$COMMIT_CONFIG = "true"  # Set to "true" to automatically commit after upload

# Passphrase for the private key.
# PAN-OS rejects every private-key import that has an empty passphrase parameter, even when the
# key itself is unencrypted, so the script never sends it empty:
#   - Leave empty (default) when the TLM Agent delivers an unencrypted key. The script generates a
#     random one-time passphrase, encrypts the key with it (via OpenSSL) before upload, and passes
#     that passphrase to PAN-OS. If OpenSSL is unavailable or encryption fails the run aborts;
#     the key is never uploaded in plaintext.
#   - Set it only when the key file is already encrypted with a known passphrase.
$PRIVATE_KEY_PASSPHRASE = ""

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# Function to mask a secret for logging: first and last 4 characters only, or **** if too short
function Get-MaskedSecret {
    param([string]$Secret)
    if ([string]::IsNullOrEmpty($Secret)) { return "" }
    if ($Secret.Length -gt 8) {
        return $Secret.Substring(0, 4) + "..." + $Secret.Substring($Secret.Length - 4)
    }
    return "****"
}

# Function to redact the args array (which carries the PAN-OS API key) from a raw JSON string
function Get-RedactedJson {
    param([string]$Json)
    return [regex]::Replace($Json, '"args"\s*:\s*\[[^\]]*\]', '"args":["<redacted>"]')
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

# Function to generate a random alphanumeric passphrase (URL-safe, no encoding surprises)
function New-RandomPassphrase {
    param([int]$Length = 12)
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    $bytes = New-Object byte[] $Length
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Function to encrypt an unencrypted PEM private key with a passphrase using OpenSSL.
# Returns the path of the encrypted temp file, or "" if encryption was not possible.
# Traditional PEM (BEGIN RSA/EC PRIVATE KEY + Proc-Type header) is tried first because it is the
# most widely accepted by PAN-OS; encrypted PKCS#8 is the fallback for OpenSSL builds without -traditional.
function Protect-PrivateKeyFile {
    param(
        [string]$InputPath,
        [string]$Passphrase
    )

    $opensslPath = Get-Command openssl -ErrorAction SilentlyContinue
    if ($null -eq $opensslPath) {
        Write-LogMessage "WARNING: OpenSSL not found. Cannot encrypt private key locally."
        return ""
    }

    $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("pan-key-" + [System.Guid]::NewGuid().ToString() + ".pem")
    # Pass the passphrase via environment variable so it never appears on the command line
    $env:PAN_KEY_PASSPHRASE = $Passphrase
    try {
        $opensslOutput = & openssl pkey -in $InputPath -out $outputPath -aes256 -traditional -passout env:PAN_KEY_PASSPHRASE 2>&1
        $ok = ($LASTEXITCODE -eq 0) -and (Test-Path $outputPath) -and ((Get-Item $outputPath).Length -gt 0)
        if (-not $ok) {
            Write-LogMessage "Traditional PEM encryption not available ($opensslOutput), falling back to PKCS#8"
            Remove-Item -Path $outputPath -Force -ErrorAction SilentlyContinue
            $opensslOutput = & openssl pkcs8 -topk8 -in $InputPath -out $outputPath -v2 aes-256-cbc -passout env:PAN_KEY_PASSPHRASE 2>&1
            $ok = ($LASTEXITCODE -eq 0) -and (Test-Path $outputPath) -and ((Get-Item $outputPath).Length -gt 0)
        }
        if (-not $ok) {
            Write-LogMessage "WARNING: OpenSSL failed to encrypt the private key: $opensslOutput"
            Remove-Item -Path $outputPath -Force -ErrorAction SilentlyContinue
            return ""
        }
        $header = (Get-Content -Path $outputPath -TotalCount 1)
        Write-LogMessage "Private key encrypted for transport ($header)"
        return $outputPath
    }
    catch {
        Write-LogMessage "WARNING: Exception while encrypting private key: $_"
        Remove-Item -Path $outputPath -Force -ErrorAction SilentlyContinue
        return ""
    }
    finally {
        Remove-Item -Path Env:\PAN_KEY_PASSPHRASE -ErrorAction SilentlyContinue
    }
}

# Function to call the PAN-OS XML API. Returns a hashtable with HttpStatus, Body and Error.
# PAN-OS frequently returns HTTP 200 with <response status="error">, and Invoke-WebRequest throws
# on HTTP 4xx/5xx, so the body is captured on both paths for status parsing.
function Invoke-PanosApi {
    param(
        [string]$Uri,
        [string]$Method = "Get",
        [hashtable]$Headers = $null,
        $Body = $null
    )

    $result = @{ HttpStatus = 0; Body = ""; Error = "" }
    $params = @{ Uri = $Uri; Method = $Method; UseBasicParsing = $true }
    if ($Headers) { $params.Headers = $Headers }
    if ($null -ne $Body) { $params.Body = $Body }
    # PowerShell 7+ ignores ServicePointManager.CertificatePolicy; use the native switch instead
    if ($PSVersionTable.PSVersion.Major -ge 6) { $params.SkipCertificateCheck = $true }

    try {
        $response = Invoke-WebRequest @params
        $result.HttpStatus = [int]$response.StatusCode
        $result.Body = [string]$response.Content
    } catch {
        $result.Error = $_.Exception.Message
        if ($_.Exception.InnerException) {
            $result.Error += " | " + $_.Exception.InnerException.Message
        }
        if ($_.Exception.Response) {
            try { $result.HttpStatus = [int]$_.Exception.Response.StatusCode } catch { }
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $result.Body = $_.ErrorDetails.Message
            } else {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $result.Body = $reader.ReadToEnd()
                    $reader.Close()
                } catch { }
            }
        }
    }
    return $result
}

# Function to extract the status attribute ("success" / "error") from a PAN-OS XML API response
function Get-PanosResponseStatus {
    param([string]$ResponseBody)
    if ($ResponseBody -match '<response[^>]*\bstatus\s*=\s*["'']([^"'']+)["'']') {
        return $Matches[1].ToLower()
    }
    return "unknown"
}

# Function to extract the human-readable message lines from a PAN-OS XML API response
function Get-PanosResponseMessage {
    param([string]$ResponseBody)
    $lines = [regex]::Matches($ResponseBody, '<(?:msg|line)>([^<]+)</(?:msg|line)>') |
        ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups[1].Value.Trim()) } |
        Where-Object { $_ } | Select-Object -Unique
    if ($lines) { return ($lines -join ' | ') }
    return ""
}

# Function to decide whether a PAN-OS API call succeeded: requires HTTP 2xx AND status="success"
function Test-PanosSuccess {
    param(
        [int]$HttpStatus,
        [string]$ResponseBody
    )
    $httpOk = ($HttpStatus -eq 200 -or $HttpStatus -eq 201)
    $apiOk = ((Get-PanosResponseStatus -ResponseBody $ResponseBody) -eq "success")
    return ($httpOk -and $apiOk)
}

# Ensure log directory exists
$LOG_DIR = Split-Path -Path $LOGFILE -Parent
if (-not (Test-Path -Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting Palo Alto certificate upload script"
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

# Log the JSON for debugging with the args array redacted (it carries the PAN-OS API key)
Write-LogMessage "=========================================="
Write-LogMessage "JSON content (args redacted):"
Write-LogMessage (Get-RedactedJson -Json $JSON_STRING)
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

# Extract arguments if they exist
if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Args array: $($ARGS_ARRAY.Count) element(s) (values redacted; argument 2 is the API key)"

    if ($ARGS_ARRAY.Count -ge 1) {
        $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) {
        $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 extracted: '$(Get-MaskedSecret -Secret $ARGUMENT_2)' (masked)"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
}

# Map arguments to Palo Alto configuration
$PA_URL = $ARGUMENT_1
$PA_API_KEY = $ARGUMENT_2

# Validate Palo Alto configuration from arguments
if ([string]::IsNullOrEmpty($PA_URL)) {
    Write-LogMessage "ERROR: PA_URL (Argument 1) is empty"
    exit 1
}

if ([string]::IsNullOrEmpty($PA_API_KEY)) {
    Write-LogMessage "ERROR: PA_API_KEY (Argument 2) is empty"
    exit 1
}

# Log Palo Alto configuration
Write-LogMessage "Palo Alto Configuration (from arguments):"
Write-LogMessage "  PA_URL: $PA_URL"
# Mask API key for security - show only first and last 4 characters
$PA_API_KEY_MASKED = Get-MaskedSecret -Secret $PA_API_KEY
Write-LogMessage "  PA_API_KEY: '$PA_API_KEY_MASKED' (masked for security)"
Write-LogMessage "  CERT_NAME_METHOD: $CERT_NAME_METHOD"
Write-LogMessage "  MANUAL_CERT_NAME: $MANUAL_CERT_NAME"
Write-LogMessage "  COMMIT_CONFIG: $COMMIT_CONFIG"

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
Write-LogMessage "  Argument 1 (PA_URL): $PA_URL"
Write-LogMessage "  Argument 2 (PA_API_KEY): $PA_API_KEY_MASKED"
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

# Check if files exist
if (Test-Path -Path $CRT_FILE_PATH) {
    $crtFileInfo = Get-Item $CRT_FILE_PATH
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    Write-LogMessage "Certificate file size: $($crtFileInfo.Length) bytes"

    # Count certificates in the file
    $crtContent = Get-Content -Path $CRT_FILE_PATH -Raw
    $CERT_COUNT = ([regex]::Matches($crtContent, "BEGIN CERTIFICATE")).Count
    Write-LogMessage "Total certificates in file: $CERT_COUNT"
} else {
    Write-LogMessage "WARNING: Certificate file not found: $CRT_FILE_PATH"
}

if (Test-Path -Path $KEY_FILE_PATH) {
    $keyFileInfo = Get-Item $KEY_FILE_PATH
    Write-LogMessage "Private key file exists: $KEY_FILE_PATH"
    Write-LogMessage "Private key file size: $($keyFileInfo.Length) bytes"

    # Determine key type
    $KEY_FILE_CONTENT = Get-Content -Path $KEY_FILE_PATH -Raw
    if ($KEY_FILE_CONTENT -match "BEGIN RSA PRIVATE KEY") {
        $KEY_TYPE = "RSA"
        Write-LogMessage "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN EC PRIVATE KEY") {
        $KEY_TYPE = "ECC"
        Write-LogMessage "Key type: ECC (BEGIN EC PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN PRIVATE KEY") {
        $KEY_TYPE = "PKCS#8 format (generic)"
        Write-LogMessage "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
    } else {
        $KEY_TYPE = "Unknown"
        Write-LogMessage "Key type: Unknown"
    }
} else {
    Write-LogMessage "WARNING: Private key file not found: $KEY_FILE_PATH"
}

# ============================================================================
# CUSTOM SCRIPT SECTION - PALO ALTO CERTIFICATE UPLOAD
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
#   $ARGUMENT_1       - First argument from args array (PA_URL)
#   $ARGUMENT_2       - Second argument from args array (PA_API_KEY)
#
# Palo Alto mapped variables:
#   $PA_URL           - Palo Alto management URL (from Argument 1)
#   $PA_API_KEY       - Palo Alto API key (from Argument 2)
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $JSON_OBJECT      - The parsed JSON object
#
# Utility function:
#   Write-LogMessage "text" - Function to write timestamped messages to log file
#
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section..."
Write-LogMessage "=========================================="

# Verify certificate and key files exist before proceeding
if (-not (Test-Path -Path $CRT_FILE_PATH)) {
    Write-LogMessage "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (-not (Test-Path -Path $KEY_FILE_PATH)) {
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

$CERT_NAME_ENCODED = [System.Uri]::EscapeDataString($CERT_NAME)

# Prepare multipart form for certificate upload
$certUri = "${PA_URL}/api/?key=${PA_API_KEY}&type=import&category=certificate&certificate-name=${CERT_NAME_ENCODED}&format=pem"

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

$certCall = Invoke-PanosApi -Uri $certUri -Method Post -Headers $headers -Body $body
$CERT_HTTP_STATUS = $certCall.HttpStatus
$CERT_RESPONSE = $certCall.Body

Write-LogMessage "Certificate upload completed"
Write-LogMessage "Certificate HTTP Status Code: $CERT_HTTP_STATUS"
Write-LogMessage "Certificate API Response: $CERT_RESPONSE"
if ($certCall.Error) {
    Write-LogMessage "Certificate connection error detail: $($certCall.Error)"
}

# Check certificate upload success (HTTP 2xx AND <response status="success">)
$CERT_UPLOAD_OK = Test-PanosSuccess -HttpStatus $CERT_HTTP_STATUS -ResponseBody $CERT_RESPONSE
if ($CERT_UPLOAD_OK) {
    Write-LogMessage "SUCCESS: Certificate uploaded successfully"
} else {
    Write-LogMessage "ERROR: Certificate upload failed (HTTP $CERT_HTTP_STATUS, API status: $(Get-PanosResponseStatus -ResponseBody $CERT_RESPONSE))"
    $certMsg = Get-PanosResponseMessage -ResponseBody $CERT_RESPONSE
    if ($certMsg) { Write-LogMessage "Certificate API message: $certMsg" }
    exit 1
}

# Prepare private key for import.
# PAN-OS requires a non-empty passphrase for every private-key import. If the key is unencrypted
# (the TLM Agent default) it is encrypted here with a one-time passphrase before upload.
Write-LogMessage "Preparing private key for import..."
$KEY_UPLOAD_PATH = $KEY_FILE_PATH
$ENCRYPTED_KEY_TEMP = ""
$KEY_IS_ENCRYPTED = ($KEY_FILE_CONTENT -match "ENCRYPTED PRIVATE KEY") -or ($KEY_FILE_CONTENT -match "Proc-Type:\s*4,\s*ENCRYPTED")

if ($KEY_IS_ENCRYPTED) {
    Write-LogMessage "Private key file is already encrypted"
    if ([string]::IsNullOrEmpty($PRIVATE_KEY_PASSPHRASE)) {
        Write-LogMessage "ERROR: Private key is encrypted but PRIVATE_KEY_PASSPHRASE is empty"
        Write-LogMessage "Certificate '$CERT_NAME' was imported without its key; candidate configuration was not committed"
        exit 1
    }
    $IMPORT_PASSPHRASE = $PRIVATE_KEY_PASSPHRASE
    Write-LogMessage "Using configured PRIVATE_KEY_PASSPHRASE to import encrypted key"
} else {
    Write-LogMessage "Private key file is unencrypted"
    if ([string]::IsNullOrEmpty($PRIVATE_KEY_PASSPHRASE)) {
        $IMPORT_PASSPHRASE = New-RandomPassphrase
        Write-LogMessage "Generated one-time passphrase for key import"
    } else {
        $IMPORT_PASSPHRASE = $PRIVATE_KEY_PASSPHRASE
        Write-LogMessage "Using configured PRIVATE_KEY_PASSPHRASE for key import"
    }
    # The private key is never uploaded in plaintext. The TLS connection to PAN-OS skips certificate
    # validation, so an unencrypted key on the wire would be exposed to a man-in-the-middle.
    # If the key cannot be encrypted locally the run fails instead of degrading.
    $ENCRYPTED_KEY_TEMP = Protect-PrivateKeyFile -InputPath $KEY_FILE_PATH -Passphrase $IMPORT_PASSPHRASE
    if ($ENCRYPTED_KEY_TEMP) {
        $KEY_UPLOAD_PATH = $ENCRYPTED_KEY_TEMP
    } else {
        Write-LogMessage "ERROR: Private key could not be encrypted locally (is OpenSSL installed and on PATH?)"
        Write-LogMessage "Refusing to upload an unencrypted private key over a connection without certificate validation"
        Write-LogMessage "Certificate '$CERT_NAME' was imported without its key; candidate configuration was not committed"
        $IMPORT_PASSPHRASE = $null
        exit 1
    }
}

if ([string]::IsNullOrEmpty($IMPORT_PASSPHRASE)) {
    Write-LogMessage "ERROR: Import passphrase is empty; PAN-OS requires a non-empty passphrase for private-key import"
    Write-LogMessage "Certificate '$CERT_NAME' was imported without its key; candidate configuration was not committed"
    exit 1
}

# Upload private key
Write-LogMessage "Uploading private key to Palo Alto..."

$PASSPHRASE_ENCODED = [System.Uri]::EscapeDataString($IMPORT_PASSPHRASE)
$keyUri = "${PA_URL}/api/?key=${PA_API_KEY}&type=import&category=private-key&certificate-name=${CERT_NAME_ENCODED}&format=pem&passphrase=${PASSPHRASE_ENCODED}"

# Read key file (encrypted temp copy or the original)
$keyContent = Get-Content -Path $KEY_UPLOAD_PATH -Raw

# Create form data
$boundary = [System.Guid]::NewGuid().ToString()

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

$keyCall = Invoke-PanosApi -Uri $keyUri -Method Post -Headers $headers -Body $body
$KEY_HTTP_STATUS = $keyCall.HttpStatus
$KEY_RESPONSE = $keyCall.Body

# Remove the encrypted temp copy as soon as the upload has been attempted
if ($ENCRYPTED_KEY_TEMP -and (Test-Path -Path $ENCRYPTED_KEY_TEMP)) {
    Remove-Item -Path $ENCRYPTED_KEY_TEMP -Force -ErrorAction SilentlyContinue
    Write-LogMessage "Removed temporary encrypted key file"
}
$keyContent = $null
$IMPORT_PASSPHRASE = $null

Write-LogMessage "Private key upload completed"
Write-LogMessage "Private key HTTP Status Code: $KEY_HTTP_STATUS"
Write-LogMessage "Private key API Response: $KEY_RESPONSE"
if ($keyCall.Error) {
    Write-LogMessage "Private key connection error detail: $($keyCall.Error)"
}

# Check private key upload success (HTTP 2xx AND <response status="success">)
$KEY_UPLOAD_OK = Test-PanosSuccess -HttpStatus $KEY_HTTP_STATUS -ResponseBody $KEY_RESPONSE
if ($KEY_UPLOAD_OK) {
    Write-LogMessage "SUCCESS: Private key uploaded successfully"
} else {
    Write-LogMessage "ERROR: Private key upload failed (HTTP $KEY_HTTP_STATUS, API status: $(Get-PanosResponseStatus -ResponseBody $KEY_RESPONSE))"
    $keyMsg = Get-PanosResponseMessage -ResponseBody $KEY_RESPONSE
    if ($keyMsg) { Write-LogMessage "Private key API message: $keyMsg" }
    Write-LogMessage "Certificate '$CERT_NAME' was imported without its key; candidate configuration was not committed"
    exit 1
}

# Commit configuration if enabled
if ($COMMIT_CONFIG -eq "true") {
    Write-LogMessage "Committing Palo Alto configuration..."

    $commitUri = "${PA_URL}/api/?key=${PA_API_KEY}&type=commit&cmd=<commit></commit>"
    $commitCall = Invoke-PanosApi -Uri $commitUri -Method Get
    $COMMIT_HTTP_STATUS = $commitCall.HttpStatus
    $COMMIT_RESPONSE = $commitCall.Body

    Write-LogMessage "Configuration commit completed"
    Write-LogMessage "Commit HTTP Status Code: $COMMIT_HTTP_STATUS"
    Write-LogMessage "Commit API Response: $COMMIT_RESPONSE"
    if ($commitCall.Error) {
        Write-LogMessage "Commit connection error detail: $($commitCall.Error)"
    }

    # Check commit success (HTTP 2xx AND <response status="success">)
    if (Test-PanosSuccess -HttpStatus $COMMIT_HTTP_STATUS -ResponseBody $COMMIT_RESPONSE) {
        $commitMsg = Get-PanosResponseMessage -ResponseBody $COMMIT_RESPONSE
        Write-LogMessage "SUCCESS: Configuration commit accepted ($commitMsg)"
    } else {
        Write-LogMessage "WARNING: Configuration commit failed (HTTP $COMMIT_HTTP_STATUS, API status: $(Get-PanosResponseStatus -ResponseBody $COMMIT_RESPONSE))"
        $commitMsg = Get-PanosResponseMessage -ResponseBody $COMMIT_RESPONSE
        if ($commitMsg) { Write-LogMessage "Commit API message: $commitMsg" }
        Write-LogMessage "Certificate and key were uploaded successfully, but commit failed"
    }
} else {
    Write-LogMessage "Configuration commit skipped (COMMIT_CONFIG is set to false)"
}

Write-LogMessage "Custom script section completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

# Exit with appropriate code based on parsed certificate and key upload results
if ($CERT_UPLOAD_OK -and $KEY_UPLOAD_OK) {
    exit 0
} else {
    exit 1
}