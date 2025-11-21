<#
LEGAL_NOTICE
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
subparagraphs (c)(1) and (2) of the Commercial Computer Software - Restricted Rights at 48 CFR 52.227-19,
or subparagraph (c)(1) of the Commercial Computer Software--Licensing at NASA FAR supplement 48 CFR 18-52.227-86.
#>

# ============================
# Configuration
# ============================
$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\imperva.log"
$API_CALL_LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\imperva-api-call.log"

# ============================
# Helper Functions
# ============================

function Write-Log {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $LOGFILE
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        "[{0}] {1}" -f $timestamp, $Message | Out-File -FilePath $LOGFILE -Append -Encoding UTF8
    } catch {
        # As a last resort, write to console
        Write-Host $Message
    }
}

function Write-ApiCall {
    param([string]$Message)
    try {
        $dir = Split-Path -Parent $API_CALL_LOGFILE
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        "[{0}] {1}" -f $timestamp, $Message | Out-File -FilePath $API_CALL_LOGFILE -Append -Encoding UTF8
    } catch {
        Write-Host $Message
    }
}

function Truncate-Middle {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [int]$Start=50,
        [int]$End=50
    )
    if (-not $Text) { return $Text }
    if ($Text.Length -le ($Start + $End)) { return $Text }
    return $Text.Substring(0,$Start) + "..." + $Text.Substring($Text.Length-$End)
}

function Mask-ApiKey {
    param([string]$Key)
    if ([string]::IsNullOrEmpty($Key)) { return $Key }
    if ($Key.Length -le 5) { return $Key }
    return $Key.Substring(0,5) + "..."
}

function Count-CertificatesInFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        $count = (Select-String -Path $Path -Pattern 'BEGIN CERTIFICATE' | Measure-Object).Count
        return $count
    } catch { return 0 }
}

function Get-First-Pem-CertificateBytes {
    param([Parameter(Mandatory=$true)][string]$Path)
    # Extract the first PEM certificate block and return raw bytes
    $text = Get-Content -LiteralPath $Path -Raw
    $m = [regex]::Match($text, '-----BEGIN CERTIFICATE-----(?<b64>.*?)-----END CERTIFICATE-----', 'Singleline')
    if (-not $m.Success) { return $null }
    $b64 = ($m.Groups['b64'].Value -replace '\s','')
    try { return [Convert]::FromBase64String($b64) } catch { return $null }
}

function Detect-AuthType {
    param(
        [Parameter(Mandatory=$true)][string]$KeyFilePath,
        [Parameter(Mandatory=$true)][string]$CertFilePath
    )
    Write-Log "Analyzing private key file for auth_type detection..."
    $keyText = ""
    try { $keyText = Get-Content -LiteralPath $KeyFilePath -Raw } catch {}
    if ($keyText -match 'BEGIN RSA PRIVATE KEY') {
        Write-Log "Detected RSA private key (BEGIN RSA PRIVATE KEY found)"
        return 'RSA'
    }
    if ($keyText -match 'BEGIN EC PRIVATE KEY') {
        Write-Log "Detected ECC private key (BEGIN EC PRIVATE KEY found)"
        return 'ECC'
    }
    if ($keyText -match 'BEGIN PRIVATE KEY') {
        # PKCS#8; infer from certificate
        $bytes = Get-First-Pem-CertificateBytes -Path $CertFilePath
        if ($null -ne $bytes) {
            try {
                $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($bytes)
                $oid = $certObj.PublicKey.Oid.Value
                if ($oid -eq '1.2.840.113549.1.1.1') {
                    Write-Log "Detected RSA private key (PKCS#8, from certificate public key OID)"
                    return 'RSA'
                } elseif ($oid -eq '1.2.840.10045.2.1') {
                    Write-Log "Detected ECC private key (PKCS#8, from certificate public key OID)"
                    return 'ECC'
                }
            } catch {
                Write-Log "WARNING: Unable to read certificate for key type detection: $_"
            }
        }
        Write-Log "Could not determine key type from certificate, defaulting to RSA"
        return 'RSA'
    }
    Write-Log "Could not determine key type, defaulting to RSA"
    return 'RSA'
}

function Get-FileBase64 {
    param([Parameter(Mandatory=$true)][string]$Path)
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        return [Convert]::ToBase64String($bytes)
    } catch {
        throw "Failed to read or encode file '$Path': $_"
    }
}

# ============================
# Start
# ============================
Write-Log "=========================================="
Write-Log "Starting Imperva certificate upload script (PowerShell)"
Write-Log "=========================================="

# Require legal notice acceptance
Write-Log "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-Log "ERROR: Legal notice not accepted. Set `$LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
    Write-Log "Script execution terminated due to legal notice non-acceptance."
    Write-Log "=========================================="
    exit 1
} else {
    Write-Log "Legal notice accepted, proceeding with script execution."
}

# Log initial configuration
Write-Log "Configuration:"
Write-Log "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Write-Log "  LOGFILE: $LOGFILE"
Write-Log "  API_CALL_LOGFILE: $API_CALL_LOGFILE"

# Read the Base64-encoded JSON from environment (exact logic aligned with other AWR PS scripts)
Write-Log "Checking DC1_POST_SCRIPT_DATA environment variable..."
if ([string]::IsNullOrEmpty($env:DC1_POST_SCRIPT_DATA)) {
    Write-Log "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
} else {
    Write-Log ("DC1_POST_SCRIPT_DATA is set (length: {0} characters)" -f $env:DC1_POST_SCRIPT_DATA.Length)
}

$CERT_INFO = $env:DC1_POST_SCRIPT_DATA
Write-Log ("CERT_INFO length: {0} characters" -f $CERT_INFO.Length)

# Decode Base64 -> JSON string
try {
    $bytes = [Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [Text.Encoding]::UTF8.GetString($bytes)
    Write-Log "JSON_STRING decoded successfully"
} catch {
    Write-Log "ERROR: Failed to Base64-decode DC1_POST_SCRIPT_DATA"
    exit 1
}

# Parse JSON
Write-Log "Extracting arguments from JSON..."
try {
    $json = $JSON_STRING | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Log "ERROR: JSON parsing failed."
    exit 1
}

# Extract args array with the exact pattern used in working scripts
$ARGS_ARRAY = @()
if ($json.PSObject.Properties.Name -contains 'args') {
    $ARGS_ARRAY = @($json.args)
}
# Normalize arguments (remove CR/LF then whitespace)
if ($ARGS_ARRAY.Count -ge 1) { $ARGUMENT_1 = ([string]$ARGS_ARRAY[0]).Replace("`r","").Replace("`n","") } else { $ARGUMENT_1 = "" }
if ($ARGS_ARRAY.Count -ge 2) { $ARGUMENT_2 = ([string]$ARGS_ARRAY[1]).Replace("`r","").Replace("`n","") } else { $ARGUMENT_2 = "" }
if ($ARGS_ARRAY.Count -ge 3) { $ARGUMENT_3 = ([string]$ARGS_ARRAY[2]).Replace("`r","").Replace("`n","") } else { $ARGUMENT_3 = "" }
if ($ARGS_ARRAY.Count -ge 4) { $ARGUMENT_4 = ([string]$ARGS_ARRAY[3]).Replace("`r","").Replace("`n","") } else { $ARGUMENT_4 = "" }
if ($ARGS_ARRAY.Count -ge 5) { $ARGUMENT_5 = ([string]$ARGS_ARRAY[4]).Replace("`r","").Replace("`n","") } else { $ARGUMENT_5 = "" }

$ARGUMENT_1 = ($ARGUMENT_1 -replace '\s','')
$ARGUMENT_2 = ($ARGUMENT_2 -replace '\s','')
$ARGUMENT_3 = ($ARGUMENT_3 -replace '\s','')
$ARGUMENT_4 = ($ARGUMENT_4 -replace '\s','')
$ARGUMENT_5 = ($ARGUMENT_5 -replace '\s','')

# Extract folder and files using same logic as working scripts
$CERT_FOLDER = ""
if ($json.PSObject.Properties.Name -contains 'certfolder') {
    $CERT_FOLDER = [string]$json.certfolder
}
$CRT_FILE = ""
$KEY_FILE = ""
if ($json.PSObject.Properties.Name -contains 'files') {
    $CRT_FILE = $json.files | Where-Object { $_ -like "*.crt" } | Select-Object -First 1
    $KEY_FILE = $json.files | Where-Object { $_ -like "*.key" } | Select-Object -First 1
    if ($CRT_FILE) { $CRT_FILE = [string]$CRT_FILE }
    if ($KEY_FILE) { $KEY_FILE = [string]$KEY_FILE }
}
$CRT_FILE_PATH = if ($CERT_FOLDER) { Join-Path $CERT_FOLDER $CRT_FILE } else { $CRT_FILE }
$KEY_FILE_PATH = if ($CERT_FOLDER) { Join-Path $CERT_FOLDER $KEY_FILE } else { $KEY_FILE }

Write-Log "=========================================="
Write-Log "EXTRACTION SUMMARY:"
Write-Log "=========================================="
Write-Log ("  ARGUMENT_1: '{0}'" -f $ARGUMENT_1)
Write-Log ("  ARGUMENT_2: '{0}'" -f $ARGUMENT_2)
Write-Log ("  ARGUMENT_3: '{0}'" -f (Mask-ApiKey $ARGUMENT_3))
Write-Log ("  ARGUMENT_4: '{0}'" -f $ARGUMENT_4)
Write-Log ("  ARGUMENT_5: '{0}'" -f $ARGUMENT_5)
Write-Log "  CERT_FOLDER: $CERT_FOLDER"
Write-Log "  CRT_FILE: $CRT_FILE"
Write-Log "  KEY_FILE: $KEY_FILE"
Write-Log "  CRT_FILE_PATH: $CRT_FILE_PATH"
Write-Log "  KEY_FILE_PATH: $KEY_FILE_PATH"

# Validate existence and log sizes
if (Test-Path -LiteralPath $CRT_FILE_PATH) {
    $crtItem = Get-Item -LiteralPath $CRT_FILE_PATH
    Write-Log "Certificate file exists: $CRT_FILE_PATH"
    Write-Log ("Certificate file size: {0} bytes" -f $crtItem.Length)
} else {
    Write-Log "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}
if (Test-Path -LiteralPath $KEY_FILE_PATH) {
    $keyItem = Get-Item -LiteralPath $KEY_FILE_PATH
    Write-Log "Key file exists: $KEY_FILE_PATH"
    Write-Log ("Key file size: {0} bytes" -f $keyItem.Length)
} else {
    Write-Log "ERROR: Key file not found: $KEY_FILE_PATH"
    exit 1
}

# Count total certs
$CERT_COUNT = Count-CertificatesInFile -Path $CRT_FILE_PATH
Write-Log ("Total certificates in file: {0}" -f $CERT_COUNT)

# Base64 encode entire PEM files (no wrapping)
Write-Log "=========================================="
Write-Log "Base64 encoding certificate chain and private key..."
Write-Log "=========================================="
try {
    $CERT_CHAIN_BASE64 = Get-FileBase64 -Path $CRT_FILE_PATH
    Write-Log "Certificate chain Base64 encoded successfully"
    Write-Log ("Certificate chain Base64 length: {0} characters" -f $CERT_CHAIN_BASE64.Length)
    if ($CERT_CHAIN_BASE64.Length -gt 100) {
        Write-Log ("Certificate Base64 starts with: {0}" -f $CERT_CHAIN_BASE64.Substring(0,50))
        Write-Log ("Certificate Base64 ends with: {0}"   -f $CERT_CHAIN_BASE64.Substring($CERT_CHAIN_BASE64.Length-50))
    } else {
        Write-Log ("Certificate Base64: {0}" -f $CERT_CHAIN_BASE64)
    }
} catch {
    Write-Log "ERROR: Failed to Base64 encode certificate file"
    exit 1
}

try {
    $KEY_BASE64 = Get-FileBase64 -Path $KEY_FILE_PATH
    Write-Log "Private key Base64 encoded successfully"
    Write-Log ("Private key Base64 length: {0} characters" -f $KEY_BASE64.Length)
    if ($KEY_BASE64.Length -gt 100) {
        Write-Log ("Private key Base64 starts with: {0}" -f $KEY_BASE64.Substring(0,50))
        Write-Log ("Private key Base64 ends with: {0}"   -f $KEY_BASE64.Substring($KEY_BASE64.Length-50))
    } else {
        Write-Log ("Private key Base64: {0}" -f $KEY_BASE64)
    }
} catch {
    Write-Log "ERROR: Failed to Base64 encode key file"
    exit 1
}

# Verify by decoding
try {
    $decodedCert = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($CERT_CHAIN_BASE64))
    if ($decodedCert -notmatch 'BEGIN CERTIFICATE') {
        Write-Log "WARNING: Certificate Base64 may be invalid. First line after decode: $((($decodedCert -split "`r?`n")[0]))"
    }
} catch { Write-Log "WARNING: Could not decode certificate Base64 for verification" }

try {
    $decodedKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($KEY_BASE64))
    if ($decodedKey -notmatch 'BEGIN (?:RSA |EC )?PRIVATE KEY') {
        Write-Log "WARNING: Private key Base64 may be invalid. First line after decode: $((($decodedKey -split "`r?`n")[0]))"
    }
} catch { Write-Log "WARNING: Could not decode private key Base64 for verification" }

# Determine auth_type (RSA or ECC)
$AUTH_TYPE = Detect-AuthType -KeyFilePath $KEY_FILE_PATH -CertFilePath $CRT_FILE_PATH
Write-Log ("Final auth_type: {0}" -f $AUTH_TYPE)

# Map arguments for API call
$SITE_ID = $ARGUMENT_1
$API_ID  = $ARGUMENT_2
$API_KEY = $ARGUMENT_3

Write-Log "API call parameters:"
Write-Log "  Site ID: $SITE_ID"
Write-Log "  API ID: $API_ID"
Write-Log ("  API Key: {0}" -f (Mask-ApiKey $API_KEY))

# Prepare JSON payload
Write-Log "Preparing JSON payload with Base64 encoded data..."
$payloadObj = [ordered]@{
    certificate = $CERT_CHAIN_BASE64
    private_key = $KEY_BASE64
    auth_type   = $AUTH_TYPE
}
$API_PAYLOAD = ($payloadObj | ConvertTo-Json -Depth 5)

Write-Log "JSON payload prepared successfully"

# Prepare truncated payload for logging
$CERT_FOR_LOG = if ($CERT_CHAIN_BASE64.Length -gt 100) { $CERT_CHAIN_BASE64.Substring(0,100) + "..." } else { $CERT_CHAIN_BASE64 }
$KEY_FOR_LOG  = if ($KEY_BASE64.Length -gt 100) { $KEY_BASE64.Substring(0,100) + "..." } else { $KEY_BASE64 }
$JSON_PAYLOAD_FOR_LOG = (@{
    certificate = $CERT_FOR_LOG
    private_key = $KEY_FOR_LOG
    auth_type   = $AUTH_TYPE
} | ConvertTo-Json -Depth 5)

# Log the complete (masked) curl-like command to API log
Write-ApiCall "=========================================="
Write-ApiCall "COMPLETE CURL COMMAND (with Base64 encoded chain):"
Write-ApiCall "=========================================="
Write-ApiCall ("curl --location --request PUT 'https://my.imperva.com/api/prov/v2/sites/{0}/customCertificate' \" -f $SITE_ID)
Write-ApiCall "--header 'Content-Type: application/json' \"
Write-ApiCall ("--header 'x-API-Key: {0}' \" -f (Mask-ApiKey $API_KEY))"
Write-ApiCall ("--header 'x-API-Id: {0}' \\" -f $API_ID)
Write-ApiCall ("--data '{0}'" -f $JSON_PAYLOAD_FOR_LOG.Replace("`r","").Replace("`n",""))
Write-ApiCall "=========================================="
Write-ApiCall ("Note: Certificate and key are Base64 encoded entire PEM files (including headers/footers)")
Write-ApiCall ("Certificate chain contains {0} certificate(s)" -f $CERT_COUNT)
Write-ApiCall "=========================================="

# Make API call (use Invoke-WebRequest to capture status code reliably)
Write-Log "=========================================="
Write-Log "Making API call to Imperva with Base64 encoded certificate chain..."
Write-Log ("URL: https://my.imperva.com/api/prov/v2/sites/{0}/customCertificate" -f $SITE_ID)
Write-Log "Method: PUT"
Write-Log "Headers:"
Write-Log "  Content-Type: application/json"
Write-Log ("  x-API-Id: {0}" -f $API_ID)
Write-Log ("  x-API-Key: {0}" -f (Mask-ApiKey $API_KEY))
Write-Log "Payload preview (truncated):"
Write-Log ("  certificate (Base64): {0}" -f (Truncate-Middle $CERT_CHAIN_BASE64 50 50))
Write-Log ("  private_key (Base64): {0}" -f (Truncate-Middle $KEY_BASE64 50 50))
Write-Log ("  auth_type: {0}" -f $AUTH_TYPE)
Write-Log "Certificate chain info:"
Write-Log ("  Number of certificates in chain: {0}" -f $CERT_COUNT)
Write-Log ("  Base64 encoded size: {0} characters" -f $CERT_CHAIN_BASE64.Length)
Write-Log ("  Private key Base64 size: {0} characters" -f $KEY_BASE64.Length)
Write-Log ("See {0} for complete curl command" -f $API_CALL_LOGFILE)
Write-Log "=========================================="

try {
    # Enforce modern TLS
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 3072 # 3072=TLS1.3 if available
    } catch {}

    $headers = @{
        'Content-Type' = 'application/json'
        'x-API-Key'    = $API_KEY
        'x-API-Id'     = $API_ID
    }

    $response = Invoke-WebRequest -Uri ("https://my.imperva.com/api/prov/v2/sites/{0}/customCertificate" -f $SITE_ID) `
                                  -Method Put `
                                  -Headers $headers `
                                  -Body $API_PAYLOAD `
                                  -ErrorAction Stop

    $HTTP_STATUS = [int]$response.StatusCode
    $RESPONSE_BODY = try { $response.Content } catch { "" }

    Write-Log "API call completed"
    Write-Log ("HTTP Status Code: {0}" -f $HTTP_STATUS)
    Write-Log ("Response Body: {0}" -f $RESPONSE_BODY)

    if ($HTTP_STATUS -eq 200 -or $HTTP_STATUS -eq 201) {
        Write-Log "SUCCESS: Certificate chain uploaded successfully to Imperva"
        Write-Log ("Certificate chain with {0} certificate(s) has been installed" -f $CERT_COUNT)
    } else {
        Write-Log ("ERROR: API call failed with status {0}" -f $HTTP_STATUS)
    }
} catch {
    # Attempt to extract status code from exception
    $HTTP_STATUS = 0
    $RESPONSE_BODY = ""
    if ($_.Exception.Response) {
        try { $HTTP_STATUS = [int]$_.Exception.Response.StatusCode } catch {}
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $RESPONSE_BODY = $reader.ReadToEnd()
            $reader.Close()
        } catch {}
    }
    Write-Log "API call encountered an exception"
    Write-Log ("HTTP Status Code: {0}" -f $HTTP_STATUS)
    if ($RESPONSE_BODY) {
        Write-Log ("Response Body: {0}" -f $RESPONSE_BODY)
    } else {
        Write-Log ("Exception: {0}" -f $_.Exception.Message)
    }
    Write-Log "ERROR: API call failed."
}

Write-Log "=========================================="
Write-Log "Summary:"
Write-Log ("  Certificate file: {0}" -f $CRT_FILE_PATH)
Write-Log ("  Private key file: {0}" -f $KEY_FILE_PATH)
Write-Log ("  Certificates in chain: {0}" -f $CERT_COUNT)
Write-Log ("  Auth type: {0}" -f $AUTH_TYPE)
Write-Log ("  API endpoint: https://my.imperva.com/api/prov/v2/sites/{0}/customCertificate" -f $SITE_ID)
Write-Log ("  HTTP status: {0}" -f $HTTP_STATUS)
if ($HTTP_STATUS -eq 200 -or $HTTP_STATUS -eq 201) {
    Write-Log "  Result: SUCCESS - Certificate chain uploaded"
} else {
    Write-Log "  Result: FAILED - Check response for details"
}
Write-Log "=========================================="

exit 0
