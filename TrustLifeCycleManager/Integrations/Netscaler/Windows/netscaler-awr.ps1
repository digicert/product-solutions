<#
.SYNOPSIS
    DigiCert TLM AWR Post-Enrollment Script - Citrix NetScaler ADC (PowerShell)

.DESCRIPTION
    This script uploads and installs TLS certificates on a Citrix NetScaler
    (ADC) appliance via the Nitro REST API. It supports both initial
    certificate creation and subsequent renewals/updates.

    AWR Arguments:
      Argument 1: NetScaler hostname/IP (excluding https:// and path)
      Argument 2: Nitro API username
      Argument 3: Nitro API password
      Argument 4: SSL cert-key pair name on the ADC

    Behaviour:
      - Uploads the certificate and key files to /nsconfig/ssl/ on the ADC
        with a timestamp in the filename for auditability
      - If the named cert-key pair already exists: updates it in place
        (preserving all vserver bindings)
      - If the named cert-key pair does not exist: creates a new one
      - Saves the running configuration after changes

.NOTES
    Legal Notice (version January 1, 2026)
    Copyright (c) 2024 DigiCert. All rights reserved.
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
    as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
    The contractor/manufacturer is DIGICERT, INC.
#>

# ============================================================================
# Configuration
# ============================================================================
$LEGAL_NOTICE_ACCEPT = "false"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\logs\awr-netscaler-adc.log"

# ============================================================================
# Ensure TLS 1.2+ and ignore self-signed certificates
# ============================================================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Skip certificate validation for self-signed NetScaler certs
# Compatible with both PowerShell 5.1 and 7+
if ($PSVersionTable.PSVersion.Major -ge 6) {
    # PowerShell 7+ uses -SkipCertificateCheck on Invoke-RestMethod (handled per-call)
    $SkipCertCheck = $true
} else {
    # PowerShell 5.1: override certificate validation globally
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    $SkipCertCheck = $false
}

# ============================================================================
# Helper Functions
# ============================================================================

function Log-Message {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] $Message"

    # Ensure log directory exists
    $LogDir = Split-Path -Parent $LOGFILE
    if ($LogDir -and -not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    Add-Content -Path $LOGFILE -Value $LogEntry
}

function Obfuscate-Value {
    param([string]$Value)
    $Length = $Value.Length
    if ($Length -le 4) {
        return "****"
    } else {
        $Stars = "*" * ($Length - 4)
        return "$($Value.Substring(0, 2))${Stars}$($Value.Substring($Length - 2, 2))"
    }
}

function Invoke-NitroApi {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers,
        [string]$Body = $null
    )

    $Params = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        ContentType = "application/json"
        ErrorAction = "Stop"
    }
    if ($Body) {
        $Params["Body"] = $Body
    }

    # Add -SkipCertificateCheck for PowerShell 7+
    if ($SkipCertCheck) {
        $Params["SkipCertificateCheck"] = $true
    }

    try {
        $Response = Invoke-RestMethod @Params
        return @{
            Success   = $true
            Response  = $Response
            ErrorCode = if ($Response.errorcode -ne $null) { $Response.errorcode } else { 0 }
            Message   = if ($Response.message) { $Response.message } else { "OK" }
        }
    } catch {
        $ErrorBody = $null
        $StatusCode = 0

        if ($_.Exception.Response) {
            $StatusCode = [int]$_.Exception.Response.StatusCode

            try {
                $StreamReader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $ErrorBodyRaw = $StreamReader.ReadToEnd()
                $StreamReader.Close()
                $ErrorBody = $ErrorBodyRaw | ConvertFrom-Json
            } catch {
                # Could not parse error body
            }
        }

        return @{
            Success   = $false
            Response  = $ErrorBody
            ErrorCode = if ($ErrorBody -and $ErrorBody.errorcode -ne $null) { $ErrorBody.errorcode } else { $StatusCode }
            Message   = if ($ErrorBody -and $ErrorBody.message) { $ErrorBody.message } else { $_.Exception.Message }
        }
    }
}

# ============================================================================
# Start Logging
# ============================================================================
Log-Message "=========================================="
Log-Message "Starting DigiCert TLM AWR Post-Script"
Log-Message "Target Platform: Citrix NetScaler ADC (Nitro API)"
Log-Message "=========================================="

# Check legal notice acceptance
Log-Message "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Log-Message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
    Log-Message "Script execution terminated due to legal notice non-acceptance."
    Log-Message "=========================================="
    exit 1
} else {
    Log-Message "Legal notice accepted, proceeding with script execution."
}

# Log initial configuration
Log-Message "Configuration:"
Log-Message "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Log-Message "  LOGFILE: $LOGFILE"

# ============================================================================
# Extract DC1_POST_SCRIPT_DATA
# ============================================================================
Log-Message "Checking DC1_POST_SCRIPT_DATA environment variable..."
$DC1_POST_SCRIPT_DATA = $env:DC1_POST_SCRIPT_DATA

if ([string]::IsNullOrEmpty($DC1_POST_SCRIPT_DATA)) {
    Log-Message "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
} else {
    Log-Message "DC1_POST_SCRIPT_DATA is set (length: $($DC1_POST_SCRIPT_DATA.Length) characters)"
}

# Read the Base64-encoded JSON string from the environment variable
$CERT_INFO = $DC1_POST_SCRIPT_DATA
Log-Message "CERT_INFO length: $($CERT_INFO.Length) characters"

# Decode JSON string
$JSON_STRING = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($CERT_INFO))
Log-Message "JSON_STRING decoded successfully"

# Log the raw JSON for debugging
Log-Message "=========================================="
Log-Message "Raw JSON content:"
Log-Message "$JSON_STRING"
Log-Message "=========================================="

# Parse JSON
$JSON_OBJECT = $JSON_STRING | ConvertFrom-Json

# Extract arguments from JSON
Log-Message "Extracting arguments from JSON..."

$ARGS_ARRAY = $JSON_OBJECT.args
Log-Message "Raw args array: $($ARGS_ARRAY -join ', ')"

# Extract Argument_1 - NetScaler hostname/IP
$ARGUMENT_1 = if ($ARGS_ARRAY.Count -ge 1) { ($ARGS_ARRAY[0]).Trim() } else { "" }
Log-Message "ARGUMENT_1 (NetScaler Host) extracted: '$ARGUMENT_1'"
Log-Message "ARGUMENT_1 length: $($ARGUMENT_1.Length)"

# Extract Argument_2 - Nitro API username
$ARGUMENT_2 = if ($ARGS_ARRAY.Count -ge 2) { ($ARGS_ARRAY[1]).Trim() } else { "" }
Log-Message "ARGUMENT_2 (Username) extracted: '$ARGUMENT_2'"
Log-Message "ARGUMENT_2 length: $($ARGUMENT_2.Length)"

# Extract Argument_3 - Nitro API password
$ARGUMENT_3 = if ($ARGS_ARRAY.Count -ge 3) { ($ARGS_ARRAY[2]).Trim() } else { "" }
Log-Message "ARGUMENT_3 (Password) extracted: '$(Obfuscate-Value $ARGUMENT_3)'"
Log-Message "ARGUMENT_3 length: $($ARGUMENT_3.Length)"

# Extract Argument_4 - SSL cert-key pair name
$ARGUMENT_4 = if ($ARGS_ARRAY.Count -ge 4) { ($ARGS_ARRAY[3]).Trim() } else { "" }
Log-Message "ARGUMENT_4 (CertKey Name) extracted: '$ARGUMENT_4'"
Log-Message "ARGUMENT_4 length: $($ARGUMENT_4.Length)"

# Extract Argument_5 - reserved for future use
$ARGUMENT_5 = if ($ARGS_ARRAY.Count -ge 5) { ($ARGS_ARRAY[4]).Trim() } else { "" }
Log-Message "ARGUMENT_5 (Reserved) extracted: '$ARGUMENT_5'"
Log-Message "ARGUMENT_5 length: $($ARGUMENT_5.Length)"

# Assign meaningful variable names
$NETSCALER_HOST = $ARGUMENT_1
$NITRO_USER     = $ARGUMENT_2
$NITRO_PASS     = $ARGUMENT_3
$CERTKEY_NAME   = $ARGUMENT_4
$NITRO_BASE_URL = "https://${NETSCALER_HOST}/nitro/v1/config"

# Extract cert folder
$CERT_FOLDER = $JSON_OBJECT.certfolder
Log-Message "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract file names from the files array
$FILES_ARRAY = $JSON_OBJECT.files
Log-Message "Files array content: $($FILES_ARRAY -join ', ')"

$CRT_FILE = $FILES_ARRAY | Where-Object { $_ -match '\.crt$' } | Select-Object -First 1
Log-Message "Extracted CRT_FILE: $CRT_FILE"

$KEY_FILE = $FILES_ARRAY | Where-Object { $_ -match '\.key$' } | Select-Object -First 1
Log-Message "Extracted KEY_FILE: $KEY_FILE"

# Construct file paths
$CRT_FILE_PATH = Join-Path $CERT_FOLDER $CRT_FILE
$KEY_FILE_PATH = Join-Path $CERT_FOLDER $KEY_FILE

# Log summary
Log-Message "=========================================="
Log-Message "EXTRACTION SUMMARY:"
Log-Message "=========================================="
Log-Message "Arguments extracted:"
Log-Message "  NetScaler Host:  $NETSCALER_HOST"
Log-Message "  Nitro Username:  $NITRO_USER"
Log-Message "  Nitro Password:  $(Obfuscate-Value $NITRO_PASS)"
Log-Message "  CertKey Name:    $CERTKEY_NAME"
Log-Message "  Nitro Base URL:  $NITRO_BASE_URL"
Log-Message ""
Log-Message "Certificate information:"
Log-Message "  Certificate folder: $CERT_FOLDER"
Log-Message "  Certificate file:   $CRT_FILE"
Log-Message "  Private key file:   $KEY_FILE"
Log-Message "  Certificate path:   $CRT_FILE_PATH"
Log-Message "  Private key path:   $KEY_FILE_PATH"
Log-Message ""
Log-Message "All files in array: $($FILES_ARRAY -join ', ')"
Log-Message "=========================================="

# Check if files exist
if (Test-Path $CRT_FILE_PATH) {
    $CrtFileInfo = Get-Item $CRT_FILE_PATH
    Log-Message "Certificate file exists: $CRT_FILE_PATH"
    Log-Message "Certificate file size: $($CrtFileInfo.Length) bytes"

    # Count certificates in the file
    $CrtContent = Get-Content $CRT_FILE_PATH -Raw
    $CERT_COUNT = ([regex]::Matches($CrtContent, "BEGIN CERTIFICATE")).Count
    Log-Message "Total certificates in file: $CERT_COUNT"
} else {
    Log-Message "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (Test-Path $KEY_FILE_PATH) {
    $KeyFileInfo = Get-Item $KEY_FILE_PATH
    Log-Message "Private key file exists: $KEY_FILE_PATH"
    Log-Message "Private key file size: $($KeyFileInfo.Length) bytes"

    # Determine key type
    $KEY_FILE_CONTENT = Get-Content $KEY_FILE_PATH -Raw
    if ($KEY_FILE_CONTENT -match "BEGIN RSA PRIVATE KEY") {
        $KEY_TYPE = "RSA"
        Log-Message "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN EC PRIVATE KEY") {
        $KEY_TYPE = "ECC"
        Log-Message "Key type: ECC (BEGIN EC PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN PRIVATE KEY") {
        $KEY_TYPE = "PKCS#8 format (generic)"
        Log-Message "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
    } else {
        $KEY_TYPE = "Unknown"
        Log-Message "Key type: Unknown"
    }
} else {
    Log-Message "ERROR: Private key file not found: $KEY_FILE_PATH"
    exit 1
}

# ============================================================================
# NETSCALER ADC INTEGRATION - NITRO REST API
# ============================================================================

Log-Message "=========================================="
Log-Message "Starting NetScaler ADC integration via Nitro API..."
Log-Message "=========================================="

# ---- Validate required arguments ----
Log-Message "Validating required arguments..."
$VALIDATION_FAILED = $false

if ([string]::IsNullOrEmpty($NETSCALER_HOST)) {
    Log-Message "ERROR: Argument 1 (NetScaler Host) is empty"
    $VALIDATION_FAILED = $true
}
if ([string]::IsNullOrEmpty($NITRO_USER)) {
    Log-Message "ERROR: Argument 2 (Username) is empty"
    $VALIDATION_FAILED = $true
}
if ([string]::IsNullOrEmpty($NITRO_PASS)) {
    Log-Message "ERROR: Argument 3 (Password) is empty"
    $VALIDATION_FAILED = $true
}
if ([string]::IsNullOrEmpty($CERTKEY_NAME)) {
    Log-Message "ERROR: Argument 4 (CertKey Name) is empty"
    $VALIDATION_FAILED = $true
}

if ($VALIDATION_FAILED) {
    Log-Message "ERROR: One or more required arguments are missing. Aborting."
    Log-Message "  Required: Argument 1 (host), Argument 2 (user), Argument 3 (pass), Argument 4 (certkey name)"
    exit 1
}
Log-Message "All required arguments validated successfully."

# ---- Generate timestamped filenames for auditability ----
$TIMESTAMP = Get-Date -Format "yyyyMMddHHmmss"
$UPLOAD_CRT_FILENAME = "${CERTKEY_NAME}-${TIMESTAMP}.crt"
$UPLOAD_KEY_FILENAME = "${CERTKEY_NAME}-${TIMESTAMP}.key"
$ADC_SSL_LOCATION = "/nsconfig/ssl"

Log-Message "Generated timestamped filenames for ADC upload:"
Log-Message "  Certificate: $UPLOAD_CRT_FILENAME"
Log-Message "  Private Key: $UPLOAD_KEY_FILENAME"

# ---- Build Nitro API headers ----
$NITRO_HEADERS = @{
    "X-NITRO-USER" = $NITRO_USER
    "X-NITRO-PASS" = $NITRO_PASS
}

# ---- Base64 encode the certificate and key for Nitro systemfile upload ----
Log-Message "Base64-encoding certificate file for upload..."
$CERT_B64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($CRT_FILE_PATH))
if ([string]::IsNullOrEmpty($CERT_B64)) {
    Log-Message "ERROR: Failed to base64-encode certificate file"
    exit 1
}
Log-Message "Certificate base64-encoded successfully (length: $($CERT_B64.Length) characters)"

Log-Message "Base64-encoding private key file for upload..."
$KEY_B64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($KEY_FILE_PATH))
if ([string]::IsNullOrEmpty($KEY_B64)) {
    Log-Message "ERROR: Failed to base64-encode private key file"
    exit 1
}
Log-Message "Private key base64-encoded successfully (length: $($KEY_B64.Length) characters)"

# ---- Test connectivity to the NetScaler ----
Log-Message "Testing connectivity to NetScaler at ${NETSCALER_HOST}..."
$ConnTest = Invoke-NitroApi -Uri "${NITRO_BASE_URL}/nsconfig" -Method "GET" -Headers $NITRO_HEADERS

if ($ConnTest.Success -or $ConnTest.ErrorCode -eq 0) {
    Log-Message "Connectivity test successful"
} elseif ($ConnTest.ErrorCode -eq 401) {
    Log-Message "ERROR: Authentication failed (HTTP 401). Check username and password."
    exit 1
} else {
    Log-Message "ERROR: Connectivity test failed (Error: $($ConnTest.Message)). Check host and network."
    exit 1
}

# ---- Step 1: Upload the certificate file to the ADC filesystem ----
Log-Message "------------------------------------------"
Log-Message "Step 1: Uploading certificate file to ADC filesystem"
Log-Message "  Target: ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
Log-Message "------------------------------------------"

$UploadCrtPayload = @{
    systemfile = @{
        filename     = $UPLOAD_CRT_FILENAME
        filelocation = $ADC_SSL_LOCATION
        filecontent  = $CERT_B64
        fileencoding = "BASE64"
    }
} | ConvertTo-Json -Depth 5

$UploadCrtResult = Invoke-NitroApi -Uri "${NITRO_BASE_URL}/systemfile" -Method "POST" -Headers $NITRO_HEADERS -Body $UploadCrtPayload

Log-Message "Certificate upload response: errorcode=$($UploadCrtResult.ErrorCode), message=$($UploadCrtResult.Message)"

if (-not $UploadCrtResult.Success -and $UploadCrtResult.ErrorCode -ne 0) {
    Log-Message "ERROR: Certificate file upload failed (errorcode: $($UploadCrtResult.ErrorCode))"
    Log-Message "Response: $($UploadCrtResult.Message)"
    exit 1
}
Log-Message "Certificate file uploaded successfully to ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"

# ---- Step 2: Upload the private key file to the ADC filesystem ----
Log-Message "------------------------------------------"
Log-Message "Step 2: Uploading private key file to ADC filesystem"
Log-Message "  Target: ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
Log-Message "------------------------------------------"

$UploadKeyPayload = @{
    systemfile = @{
        filename     = $UPLOAD_KEY_FILENAME
        filelocation = $ADC_SSL_LOCATION
        filecontent  = $KEY_B64
        fileencoding = "BASE64"
    }
} | ConvertTo-Json -Depth 5

$UploadKeyResult = Invoke-NitroApi -Uri "${NITRO_BASE_URL}/systemfile" -Method "POST" -Headers $NITRO_HEADERS -Body $UploadKeyPayload

Log-Message "Private key upload response: errorcode=$($UploadKeyResult.ErrorCode), message=$($UploadKeyResult.Message)"

if (-not $UploadKeyResult.Success -and $UploadKeyResult.ErrorCode -ne 0) {
    Log-Message "ERROR: Private key file upload failed (errorcode: $($UploadKeyResult.ErrorCode))"
    Log-Message "Response: $($UploadKeyResult.Message)"
    exit 1
}
Log-Message "Private key file uploaded successfully to ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"

# ---- Step 3: Check if the cert-key pair already exists on the ADC ----
Log-Message "------------------------------------------"
Log-Message "Step 3: Checking if cert-key pair '${CERTKEY_NAME}' already exists on the ADC"
Log-Message "------------------------------------------"

$CertKeyCheckResult = Invoke-NitroApi -Uri "${NITRO_BASE_URL}/sslcertkey/${CERTKEY_NAME}" -Method "GET" -Headers $NITRO_HEADERS

Log-Message "Cert-key pair lookup response: errorcode=$($CertKeyCheckResult.ErrorCode), message=$($CertKeyCheckResult.Message)"

$CERTKEY_EXISTS = $false
if ($CertKeyCheckResult.ErrorCode -eq 0) {
    $CERTKEY_EXISTS = $true
    Log-Message "Cert-key pair '${CERTKEY_NAME}' EXISTS on the ADC - will perform UPDATE"
    Log-Message "  (All existing vserver bindings will be preserved)"
} else {
    Log-Message "Cert-key pair '${CERTKEY_NAME}' does NOT exist on the ADC - will perform CREATE"
}

# ---- Step 4: Create or Update the cert-key pair ----
Log-Message "------------------------------------------"
Log-Message "Step 4: Installing certificate on the ADC"
Log-Message "------------------------------------------"

if ($CERTKEY_EXISTS) {
    # -----------------------------------------------------------
    # UPDATE existing cert-key pair
    # Using POST with ?action=update which is the supported method
    # for updating SSL cert-key pairs on NetScaler 14.1+
    # nodomaincheck=true allows updating even if CN/SAN differs
    # -----------------------------------------------------------
    Log-Message "Performing UPDATE on existing cert-key pair '${CERTKEY_NAME}'..."
    Log-Message "  New certificate file: ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
    Log-Message "  New private key file: ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
    Log-Message "  nodomaincheck: true (allows CN/SAN changes during renewal)"

    # Payload with full path
    $UpdatePayloadFullPath = @{
        sslcertkey = @{
            certkey       = $CERTKEY_NAME
            cert          = "${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
            key           = "${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
            nodomaincheck = $true
        }
    } | ConvertTo-Json -Depth 5

    # Payload with filename only
    $UpdatePayloadShort = @{
        sslcertkey = @{
            certkey       = $CERTKEY_NAME
            cert          = $UPLOAD_CRT_FILENAME
            key           = $UPLOAD_KEY_FILENAME
            nodomaincheck = $true
        }
    } | ConvertTo-Json -Depth 5

    # Define the fallback chain of update methods
    $UpdateMethods = @(
        @{ Method = "POST"; Uri = "${NITRO_BASE_URL}/sslcertkey?action=update"; Body = $UpdatePayloadFullPath;  Label = "POST ?action=update (full path)" },
        @{ Method = "PUT";  Uri = "${NITRO_BASE_URL}/sslcertkey";              Body = $UpdatePayloadFullPath;  Label = "PUT (full path)" },
        @{ Method = "POST"; Uri = "${NITRO_BASE_URL}/sslcertkey?action=update"; Body = $UpdatePayloadShort;    Label = "POST ?action=update (filename only)" },
        @{ Method = "PUT";  Uri = "${NITRO_BASE_URL}/sslcertkey";              Body = $UpdatePayloadShort;    Label = "PUT (filename only)" }
    )

    $UpdateSuccess = $false

    foreach ($Attempt in $UpdateMethods) {
        Log-Message "Attempting update via $($Attempt.Label)..."

        $UpdateResult = Invoke-NitroApi -Uri $Attempt.Uri -Method $Attempt.Method -Headers $NITRO_HEADERS -Body $Attempt.Body

        Log-Message "Update ($($Attempt.Label)) response: errorcode=$($UpdateResult.ErrorCode), message=$($UpdateResult.Message)"

        if ($UpdateResult.ErrorCode -eq 0) {
            $UpdateSuccess = $true
            Log-Message "Update succeeded via $($Attempt.Label)"
            break
        } else {
            Log-Message "WARNING: $($Attempt.Label) failed (errorcode: $($UpdateResult.ErrorCode)). Trying next method..."
        }
    }

    if (-not $UpdateSuccess) {
        Log-Message "ERROR: All update methods failed for cert-key pair '${CERTKEY_NAME}'"
        Log-Message "  Last errorcode: $($UpdateResult.ErrorCode)"
        Log-Message "  Last response: $($UpdateResult.Message)"
        exit 1
    }

    Log-Message "SUCCESS: Cert-key pair '${CERTKEY_NAME}' updated successfully"
    Log-Message "  All existing vserver bindings remain intact"

} else {
    # -----------------------------------------------------------
    # CREATE new cert-key pair
    # Using POST on /sslcertkey to create a brand new pair
    # -----------------------------------------------------------
    Log-Message "Performing CREATE of new cert-key pair '${CERTKEY_NAME}'..."
    Log-Message "  Certificate file: ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
    Log-Message "  Private key file: ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"

    $CreatePayload = @{
        sslcertkey = @{
            certkey = $CERTKEY_NAME
            cert    = "${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
            key     = "${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
            inform  = "PEM"
        }
    } | ConvertTo-Json -Depth 5

    $CreateResult = Invoke-NitroApi -Uri "${NITRO_BASE_URL}/sslcertkey" -Method "POST" -Headers $NITRO_HEADERS -Body $CreatePayload

    Log-Message "Create response: errorcode=$($CreateResult.ErrorCode), message=$($CreateResult.Message)"

    if ($CreateResult.ErrorCode -ne 0) {
        Log-Message "ERROR: Failed to create cert-key pair '${CERTKEY_NAME}' (errorcode: $($CreateResult.ErrorCode))"
        Log-Message "Response: $($CreateResult.Message)"
        exit 1
    }

    Log-Message "SUCCESS: Cert-key pair '${CERTKEY_NAME}' created successfully"
    Log-Message "  NOTE: The new cert-key pair is not yet bound to any vserver."
    Log-Message "  Bind it manually or via automation using the sslvserver_sslcertkey_binding endpoint."
}

# ---- Step 5: Save the NetScaler configuration ----
Log-Message "------------------------------------------"
Log-Message "Step 5: Saving NetScaler running configuration"
Log-Message "  (Persisting changes across reboot)"
Log-Message "------------------------------------------"

$SavePayload = @{ nsconfig = @{} } | ConvertTo-Json -Depth 5

$SaveResult = Invoke-NitroApi -Uri "${NITRO_BASE_URL}/nsconfig?action=save" -Method "POST" -Headers $NITRO_HEADERS -Body $SavePayload

Log-Message "Save config response: errorcode=$($SaveResult.ErrorCode), message=$($SaveResult.Message)"

if ($SaveResult.ErrorCode -ne 0) {
    Log-Message "WARNING: Failed to save configuration (errorcode: $($SaveResult.ErrorCode))"
    Log-Message "  The certificate changes are active but may not persist across reboot"
    Log-Message "Response: $($SaveResult.Message)"
} else {
    Log-Message "NetScaler configuration saved successfully"
}

# ---- Final Summary ----
$OperationPerformed = if ($CERTKEY_EXISTS) { "UPDATE (existing)" } else { "CREATE (new)" }
$ConfigSaved = if ($SaveResult.ErrorCode -eq 0) { "YES" } else { "NO (warning)" }

Log-Message "=========================================="
Log-Message "NETSCALER ADC INTEGRATION COMPLETE"
Log-Message "=========================================="
Log-Message "  NetScaler Host:        $NETSCALER_HOST"
Log-Message "  CertKey Pair Name:     $CERTKEY_NAME"
Log-Message "  Operation Performed:   $OperationPerformed"
Log-Message "  Uploaded Cert File:    ${ADC_SSL_LOCATION}/${UPLOAD_CRT_FILENAME}"
Log-Message "  Uploaded Key File:     ${ADC_SSL_LOCATION}/${UPLOAD_KEY_FILENAME}"
Log-Message "  Config Saved:          $ConfigSaved"
Log-Message "=========================================="

# ============================================================================
# END OF NETSCALER ADC INTEGRATION
# ============================================================================

Log-Message "=========================================="
Log-Message "Script execution completed successfully"
Log-Message "=========================================="

exit 0