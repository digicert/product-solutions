<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (PFX Format) - PowerShell Version
.DESCRIPTION
    PowerShell conversion of the original Bash script for processing certificate data from DigiCert TLM Agent
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
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\awr-template-logfile.log"
$LOG_DIR_CHECKED = $false

# ============================================================================
#  IIS MULTI-SITE / MULTI-PORT SSL CERTIFICATE REPLACEMENT
# ----------------------------------------------------------------------------
#  Target environment - every site carries the SAME certificate on BOTH of its
#  https bindings, and the sites differ only by port:
#
#     Site               Binding 1 (host name, SNI)        Binding 2 (dedicated IP)
#     -----------------  --------------------------------  ------------------------
#     ws1-digicert-demo  *:9001:iis-01.digicert-demo.com   10.160.52.84:9001:
#     ws2-digicert-demo  *:9090:iis-01.digicert-demo.com   10.160.52.84:9090:
#     ws3-digicert-demo  *:9080:iis-01.digicert-demo.com   10.160.52.84:9080:
#     ws4-digicert-demo  *:9070:iis-01.digicert-demo.com   10.160.52.84:9070:
#
#  Flow:
#    1. Import the PFX delivered by the TLM agent into LocalMachine\My
#       (intermediates go to LocalMachine\CA).
#    2. Snapshot every https binding (applicationHost.config hash + http.sys
#       registration) and write a rollback script.
#    3. Re-point every https binding of every listed site:
#         - applicationHost.config : certificateHash / certificateStoreName
#         - http.sys               : hostnameport=<host>:<port>  (SNI bindings)
#                                    ipport=<ip>:<port>          (IP bindings)
#       Both stores are updated on purpose: config alone leaves IIS Manager and
#       http.sys out of sync, netsh alone is reverted on the next config change.
#    4. Verify in config, in http.sys, and with a live TLS handshake.
#
#  Requires: the TLM agent service runs as an account with local admin rights
#  (writing applicationHost.config and http.sys SSL bindings needs elevation).
# ============================================================================

$FINAL_EXIT_CODE = 0
$script:IIS_ERRORS = 0

#region ----------------- IIS configuration ---------------------------------

# Sites whose https bindings must be re-pointed at the new certificate.
$IIS_TARGET_SITES = @(
    'ws1-digicert-demo',
    'ws2-digicert-demo',
    'ws3-digicert-demo',
    'ws4-digicert-demo'
)

# 'List'     - only the sites listed in $IIS_TARGET_SITES
# 'AllHttps' - every IIS site that has at least one https binding
$IIS_SITE_DISCOVERY_MODE = 'List'

# Safety net - abort if the new certificate does not carry this common name.
# Set to '' to disable the check.
$IIS_EXPECTED_SUBJECT_CN = 'iis-01.digicert-demo.com'

$IIS_CERT_STORE_NAME       = 'My'      # store under LocalMachine
$IIS_IMPORT_CHAIN          = $true     # intermediates -> LocalMachine\CA
$IIS_IMPORT_ROOT_CA        = $false    # $true also trusts roots found in the PFX
$IIS_REMOVE_REPLACED_CERTS = $false    # delete old cert once nothing references it
$IIS_VERIFY_TLS_HANDSHAKE  = $true     # live TLS probe of every endpoint
$IIS_DEFAULT_APPID         = '{4dc3e181-e14b-4a21-b022-59fc669b0914}'  # IIS appid
$IIS_ROLLBACK_DIR          = 'C:\ProgramData\DigiCert\iis-cert-rollback'

#endregion

# Function to log messages with timestamp.
# The log directory is created on first use: on a fresh agent install the "log"
# folder may not exist yet, and without it every Add-Content below fails and the
# run leaves no trace at all.
function Write-LogMessage {
    param([string]$Message)

    if (-not $script:LOG_DIR_CHECKED) {
        $script:LOG_DIR_CHECKED = $true
        $logDir = Split-Path -Path $LOGFILE -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
            try {
                New-Item -ItemType Directory -Path $logDir -Force -ErrorAction Stop | Out-Null
            } catch {
                Write-Warning "Could not create log directory '$logDir': $_"
            }
        }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    try {
        "[$timestamp] $Message" | Add-Content -LiteralPath $LOGFILE -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning "Could not write to log file '$LOGFILE': $_"
    }
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)"
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

# Decode JSON string from Base64
try {
    $JSON_BYTES = [System.Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString($JSON_BYTES)
    Write-LogMessage "JSON_STRING decoded successfully"
} catch {
    Write-LogMessage "ERROR: Failed to decode Base64: $_"
    exit 1
}

# Log the JSON for debugging, with any secret-bearing field redacted first.
# The payload carries the PFX password in clear text, so $JSON_STRING itself must
# never reach the log. Keys are matched case-insensitively and the value is
# consumed escape-aware so that a password containing \" cannot end the match
# early and leak its tail.
$JSON_STRING_REDACTED = [regex]::Replace(
    $JSON_STRING,
    '(?i)("[^"]*(?:password|passphrase|pwd|secret|token|credential)[^"]*"\s*:\s*")(?:\\.|[^"\\])*(")',
    '${1}<redacted>${2}')

Write-LogMessage "=========================================="
Write-LogMessage "JSON content (secrets redacted):"
Write-LogMessage $JSON_STRING_REDACTED
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

# Initialize argument variables (up to 15)
$ARGUMENT_1 = ""
$ARGUMENT_2 = ""
$ARGUMENT_3 = ""
$ARGUMENT_4 = ""
$ARGUMENT_5 = ""
$ARGUMENT_6 = ""
$ARGUMENT_7 = ""
$ARGUMENT_8 = ""
$ARGUMENT_9 = ""
$ARGUMENT_10 = ""
$ARGUMENT_11 = ""
$ARGUMENT_12 = ""
$ARGUMENT_13 = ""
$ARGUMENT_14 = ""
$ARGUMENT_15 = ""

# Extract arguments if they exist
if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"

    if ($ARGS_ARRAY.Count -ge 1) {
        $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) {
        $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 3) {
        $ARGUMENT_3 = ($ARGS_ARRAY[2] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
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
    if ($ARGS_ARRAY.Count -ge 6) {
        $ARGUMENT_6 = ($ARGS_ARRAY[5] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_6 extracted: '$ARGUMENT_6'"
        Write-LogMessage "ARGUMENT_6 length: $($ARGUMENT_6.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 7) {
        $ARGUMENT_7 = ($ARGS_ARRAY[6] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_7 extracted: '$ARGUMENT_7'"
        Write-LogMessage "ARGUMENT_7 length: $($ARGUMENT_7.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 8) {
        $ARGUMENT_8 = ($ARGS_ARRAY[7] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_8 extracted: '$ARGUMENT_8'"
        Write-LogMessage "ARGUMENT_8 length: $($ARGUMENT_8.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 9) {
        $ARGUMENT_9 = ($ARGS_ARRAY[8] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_9 extracted: '$ARGUMENT_9'"
        Write-LogMessage "ARGUMENT_9 length: $($ARGUMENT_9.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 10) {
        $ARGUMENT_10 = ($ARGS_ARRAY[9] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_10 extracted: '$ARGUMENT_10'"
        Write-LogMessage "ARGUMENT_10 length: $($ARGUMENT_10.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 11) {
        $ARGUMENT_11 = ($ARGS_ARRAY[10] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_11 extracted: '$ARGUMENT_11'"
        Write-LogMessage "ARGUMENT_11 length: $($ARGUMENT_11.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 12) {
        $ARGUMENT_12 = ($ARGS_ARRAY[11] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_12 extracted: '$ARGUMENT_12'"
        Write-LogMessage "ARGUMENT_12 length: $($ARGUMENT_12.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 13) {
        $ARGUMENT_13 = ($ARGS_ARRAY[12] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_13 extracted: '$ARGUMENT_13'"
        Write-LogMessage "ARGUMENT_13 length: $($ARGUMENT_13.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 14) {
        $ARGUMENT_14 = ($ARGS_ARRAY[13] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_14 extracted: '$ARGUMENT_14'"
        Write-LogMessage "ARGUMENT_14 length: $($ARGUMENT_14.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 15) {
        $ARGUMENT_15 = ($ARGS_ARRAY[14] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_15 extracted: '$ARGUMENT_15'"
        Write-LogMessage "ARGUMENT_15 length: $($ARGUMENT_15.Length)"
    }
}

# Extract cert folder
$CERT_FOLDER = $JSON_OBJECT.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .pfx file name
$PFX_FILE = ""
if ($JSON_OBJECT.files) {
    $PFX_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.pfx$|\.p12$' } | Select-Object -First 1
}
Write-LogMessage "Extracted PFX_FILE: $PFX_FILE"

# Extract the PFX password from JSON
# Check common field names for password
$PFX_PASSWORD = ""
if ($JSON_OBJECT.password) { $PFX_PASSWORD = $JSON_OBJECT.password }
elseif ($JSON_OBJECT.pfx_password) { $PFX_PASSWORD = $JSON_OBJECT.pfx_password }
elseif ($JSON_OBJECT.keystore_password) { $PFX_PASSWORD = $JSON_OBJECT.keystore_password }
elseif ($JSON_OBJECT.passphrase) { $PFX_PASSWORD = $JSON_OBJECT.passphrase }

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "WARNING: No PFX password found in JSON. Checking if password is in arguments..."
    if (-not [string]::IsNullOrEmpty($ARGUMENT_4)) {
        Write-LogMessage "Checking if Argument 4 could be the password..."
    }
    if (-not [string]::IsNullOrEmpty($ARGUMENT_5)) {
        Write-LogMessage "Checking if Argument 5 could be the password..."
    }
} else {
    Write-LogMessage "PFX password extracted from JSON"
    # Length only - never any part of the value itself. Enough to tell an empty or
    # truncated password from a real one without putting characters in the log.
    Write-LogMessage "PFX password length: $($PFX_PASSWORD.Length) characters"
}

# Construct file path
$PFX_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $PFX_FILE

# Extract all files from the files array
$FILES_ARRAY = $JSON_OBJECT.files -join ','
Write-LogMessage "Files array content: $FILES_ARRAY"

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "Arguments extracted:"
Write-LogMessage "  Argument 1: $ARGUMENT_1"
Write-LogMessage "  Argument 2: $ARGUMENT_2"
Write-LogMessage "  Argument 3: $ARGUMENT_3"
Write-LogMessage "  Argument 4: $ARGUMENT_4"
Write-LogMessage "  Argument 5: $ARGUMENT_5"
Write-LogMessage "  Argument 6: $ARGUMENT_6"
Write-LogMessage "  Argument 7: $ARGUMENT_7"
Write-LogMessage "  Argument 8: $ARGUMENT_8"
Write-LogMessage "  Argument 9: $ARGUMENT_9"
Write-LogMessage "  Argument 10: $ARGUMENT_10"
Write-LogMessage "  Argument 11: $ARGUMENT_11"
Write-LogMessage "  Argument 12: $ARGUMENT_12"
Write-LogMessage "  Argument 13: $ARGUMENT_13"
Write-LogMessage "  Argument 14: $ARGUMENT_14"
Write-LogMessage "  Argument 15: $ARGUMENT_15"
Write-LogMessage ""
Write-LogMessage "Certificate information:"
Write-LogMessage "  Certificate folder: $CERT_FOLDER"
Write-LogMessage "  PFX file: $PFX_FILE"
Write-LogMessage "  PFX file path: $PFX_FILE_PATH"
if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "  PFX password: Found ($($PFX_PASSWORD.Length) characters)"
} else {
    Write-LogMessage "  PFX password: Not found"
}
Write-LogMessage ""
Write-LogMessage "All files in array: $FILES_ARRAY"
Write-LogMessage "=========================================="

# Check if PFX file exists
if (Test-Path $PFX_FILE_PATH) {
    $pfxFileInfo = Get-Item $PFX_FILE_PATH
    Write-LogMessage "PFX file exists: $PFX_FILE_PATH"
    Write-LogMessage "PFX file size: $($pfxFileInfo.Length) bytes"
    
    # If we have the password, we can try to inspect the PFX contents
    if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) {
        try {
            # Try to load the PFX certificate
            $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
            $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PFX_FILE_PATH, $securePwd)
            
            Write-LogMessage "Successfully accessed PFX file with provided password"
            Write-LogMessage "Certificate subject: $($pfxCert.Subject)"
            Write-LogMessage "Certificate issuer: $($pfxCert.Issuer)"
            Write-LogMessage "Certificate thumbprint: $($pfxCert.Thumbprint)"
            Write-LogMessage "Certificate valid from: $($pfxCert.NotBefore)"
            Write-LogMessage "Certificate valid to: $($pfxCert.NotAfter)"
            
            # Check key algorithm
            $keyAlgorithm = $pfxCert.SignatureAlgorithm.FriendlyName
            Write-LogMessage "Signature algorithm: $keyAlgorithm"
            
            # Check if it has private key
            if ($pfxCert.HasPrivateKey) {
                Write-LogMessage "Certificate has private key: Yes"
                $keyType = $pfxCert.PrivateKey.GetType().Name
                Write-LogMessage "Private key type: $keyType"
            } else {
                Write-LogMessage "Certificate has private key: No"
            }
            
            $pfxCert.Dispose()
        } catch {
            Write-LogMessage "WARNING: Could not access PFX file with provided password: $_"
        }
    } else {
        Write-LogMessage "No password provided, cannot inspect PFX contents"
    }
} else {
    Write-LogMessage "WARNING: PFX file not found: $PFX_FILE_PATH"
}

# Additional check for any certificate-related files
Write-LogMessage "=========================================="
Write-LogMessage "Checking for all certificate-related files in folder..."
if (Test-Path $CERT_FOLDER) {
    $certFiles = Get-ChildItem -Path $CERT_FOLDER -Include "*.pfx", "*.p12", "*.cer", "*.crt", "*.key", "*.pem" -Recurse -ErrorAction SilentlyContinue
    if ($certFiles) {
        Write-LogMessage "Certificate-related files found:"
        foreach ($file in $certFiles) {
            Write-LogMessage "  $($file.Name) - $($file.Length) bytes - $($file.LastWriteTime)"
        }
    } else {
        Write-LogMessage "No certificate files found in folder"
    }
} else {
    Write-LogMessage "Certificate folder does not exist: $CERT_FOLDER"
}

# ============================================================================
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================
#
# Available variables for your custom logic:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $PFX_FILE         - The filename of the PFX/P12 certificate (filename only)
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file (folder + filename)
#   $PFX_PASSWORD     - Password for the PFX/P12 file (if available)
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Argument variables (from JSON args array, up to 15):
#   $ARGUMENT_1       - First argument from args array (AWR Parameter 1)
#   $ARGUMENT_2       - Second argument from args array (AWR Parameter 2)
#   $ARGUMENT_3       - Third argument from args array (AWR Parameter 3)
#   $ARGUMENT_4       - Fourth argument from args array (AWR Parameter 4)
#   $ARGUMENT_5       - Fifth argument from args array (AWR Parameter 5)
#   $ARGUMENT_6       - Sixth argument from args array (AWR Parameter 6)
#   $ARGUMENT_7       - Seventh argument from args array (AWR Parameter 7)
#   $ARGUMENT_8       - Eighth argument from args array (AWR Parameter 8)
#   $ARGUMENT_9       - Ninth argument from args array (AWR Parameter 9)
#   $ARGUMENT_10      - Tenth argument from args array (AWR Parameter 10)
#   $ARGUMENT_11      - Eleventh argument from args array (AWR Parameter 11)
#   $ARGUMENT_12      - Twelfth argument from args array (AWR Parameter 12)
#   $ARGUMENT_13      - Thirteenth argument from args array (AWR Parameter 13)
#   $ARGUMENT_14      - Fourteenth argument from args array (AWR Parameter 14)
#   $ARGUMENT_15      - Fifteenth argument from args array (AWR Parameter 15)
#
# JSON-related variables:
#   $JSON_STRING      - The complete decoded JSON string
#   $JSON_OBJECT      - The parsed JSON object
#   $ARGS_ARRAY       - The args array from JSON object
#
# Utility function:
#   Write-LogMessage "text" - Function to write timestamped messages to log file
#
# Example custom logic:
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section..."
Write-LogMessage "=========================================="

#region ------------- AWR parameter overrides -------------------------------
#  The static IIS configuration lives at the TOP of this file, directly under
#  the logging setup. These overrides have to stay here instead: $ARGUMENT_1
#  .. $ARGUMENT_3 only exist once DC1_POST_SCRIPT_DATA has been decoded above.
#
#   AWR Parameter 1 : comma separated site list, or ALL for every https site
#   AWR Parameter 2 : expected subject CN, or NONE to disable the CN check
#   AWR Parameter 3 : REMOVEOLD to delete the certificate that was replaced
# NOTE: arguments are whitespace-stripped during extraction, so site names that
#       contain spaces (e.g. "Default Web Site") must stay in $IIS_TARGET_SITES.
if (-not [string]::IsNullOrWhiteSpace($ARGUMENT_1)) {
    if ($ARGUMENT_1 -match '^(ALL|\*)$') {
        $IIS_SITE_DISCOVERY_MODE = 'AllHttps'
    } else {
        $IIS_TARGET_SITES = @($ARGUMENT_1.Split(',') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $IIS_SITE_DISCOVERY_MODE = 'List'
    }
}
if (-not [string]::IsNullOrWhiteSpace($ARGUMENT_2)) {
    if ($ARGUMENT_2 -eq 'NONE') { $IIS_EXPECTED_SUBJECT_CN = '' } else { $IIS_EXPECTED_SUBJECT_CN = $ARGUMENT_2 }
}
if ($ARGUMENT_3 -eq 'REMOVEOLD') { $IIS_REMOVE_REPLACED_CERTS = $true }

#endregion

#region ------------------------- Helpers -----------------------------------

function Invoke-NetshHttp {
    param([Parameter(Mandatory = $true)][string[]]$NetshArguments)
    $raw = & netsh.exe @NetshArguments 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | Out-String).Trim()
    $result = New-Object PSObject
    $result | Add-Member -MemberType NoteProperty -Name ExitCode -Value $code
    $result | Add-Member -MemberType NoteProperty -Name Output   -Value $text
    return $result
}

function Get-HttpSslRegistration {
    # Reads an http.sys SSL binding. Parsing is value based (40 hex chars for the
    # hash, a GUID for the app id) so it also works on localised Windows builds
    # where the netsh labels are translated.
    param([Parameter(Mandatory = $true)][string]$Selector)

    $show = Invoke-NetshHttp @('http', 'show', 'sslcert', $Selector)
    $text = $show.Output
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $hashMatch  = [regex]::Match($text, '(?m):\s*([0-9a-fA-F]{40})\s*$')
    if (-not $hashMatch.Success) { return $null }
    $appIdMatch = [regex]::Match($text, '(?m):\s*(\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\})\s*$')
    $storeMatch = [regex]::Match($text, '(?mi):\s*(MY|WebHosting|CA|Root|AuthRoot|TrustedPeople)\s*$')

    $appId = $null
    if ($appIdMatch.Success) { $appId = $appIdMatch.Groups[1].Value }
    $storeName = $null
    if ($storeMatch.Success) { $storeName = $storeMatch.Groups[1].Value }

    $reg = New-Object PSObject
    $reg | Add-Member -MemberType NoteProperty -Name Selector   -Value $Selector
    $reg | Add-Member -MemberType NoteProperty -Name Thumbprint -Value $hashMatch.Groups[1].Value.ToUpperInvariant()
    $reg | Add-Member -MemberType NoteProperty -Name AppId      -Value $appId
    $reg | Add-Member -MemberType NoteProperty -Name StoreName  -Value $storeName
    return $reg
}

function Set-HttpSslRegistration {
    # Replaces the http.sys SSL binding for one selector. Returns $true on success.
    param(
        [Parameter(Mandatory = $true)][string]$Selector,
        [Parameter(Mandatory = $true)][string]$Thumbprint,
        [string]$AppId,
        [string]$StoreName = 'MY'
    )

    if ([string]::IsNullOrWhiteSpace($AppId))     { $AppId = $IIS_DEFAULT_APPID }
    if ([string]::IsNullOrWhiteSpace($StoreName)) { $StoreName = 'MY' }

    $delete = Invoke-NetshHttp @('http', 'delete', 'sslcert', $Selector)
    Write-LogMessage "      netsh http delete sslcert $Selector -> exit $($delete.ExitCode)"

    $add = Invoke-NetshHttp @('http', 'add', 'sslcert', $Selector, "certhash=$Thumbprint", "appid=$AppId", "certstorename=$StoreName")
    if ($add.ExitCode -eq 0) {
        Write-LogMessage "      netsh http add sslcert $Selector certhash=$Thumbprint appid=$AppId certstorename=$StoreName -> OK"
        return $true
    }

    Write-LogMessage "      ERROR: netsh http add sslcert $Selector failed (exit $($add.ExitCode)): $($add.Output)"
    return $false
}

function Convert-BindingInformation {
    # "10.160.52.84:9001:"  ->  Ip / Port / HostName
    # "*:9001:iis-01.digicert-demo.com"
    param([Parameter(Mandatory = $true)][string]$BindingInformation)

    $m = [regex]::Match($BindingInformation, '^(?<ip>.*):(?<port>\d+):(?<host>.*)$')
    if (-not $m.Success) { return $null }

    $ip = $m.Groups['ip'].Value
    if ([string]::IsNullOrWhiteSpace($ip) -or $ip -eq '*') { $ip = '0.0.0.0' }

    $parsed = New-Object PSObject
    $parsed | Add-Member -MemberType NoteProperty -Name Ip       -Value $ip
    $parsed | Add-Member -MemberType NoteProperty -Name Port     -Value ([int]$m.Groups['port'].Value)
    $parsed | Add-Member -MemberType NoteProperty -Name HostName -Value $m.Groups['host'].Value
    return $parsed
}

function Get-ServedCertificateThumbprint {
    # Opens a real TLS connection and returns the thumbprint the endpoint serves.
    param(
        [Parameter(Mandatory = $true)][string]$ConnectIp,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$SniName,
        [int]$TimeoutMs = 5000
    )

    $client = $null
    $sslStream = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async = $client.BeginConnect($ConnectIp, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            throw "connection to ${ConnectIp}:$Port timed out"
        }
        $client.EndConnect($async)

        $acceptAll = [System.Net.Security.RemoteCertificateValidationCallback] { param($snd, $crt, $chn, $err) return $true }
        $sslStream = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $acceptAll)
        try {
            $sslStream.AuthenticateAsClient($SniName)
        } catch {
            $sslStream.Dispose()
            $client.Close()
            $client = New-Object System.Net.Sockets.TcpClient
            $client.Connect($ConnectIp, $Port)
            $sslStream = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $acceptAll)
            $sslStream.AuthenticateAsClient($SniName, $null, [System.Security.Authentication.SslProtocols]::Tls12, $false)
        }

        $served = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($sslStream.RemoteCertificate)
        return $served.Thumbprint.ToUpperInvariant()
    } catch {
        Write-LogMessage "      WARNING: TLS probe of ${ConnectIp}:$Port (SNI '$SniName') failed: $_"
        return $null
    } finally {
        if ($sslStream) { $sslStream.Dispose() }
        if ($client)    { $client.Close() }
    }
}

function Add-CertificateToStore {
    # Adds a certificate to a LocalMachine store when it is not already present.
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)][string]$StoreName
    )

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName, 'LocalMachine')
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $findType = [System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint
        $existing = $store.Certificates.Find($findType, $Certificate.Thumbprint, $false)

        $needsAdd = $true
        if ($existing.Count -gt 0) {
            # Re-add when the stored copy has no usable private key but ours has.
            if (-not $Certificate.HasPrivateKey -or $existing[0].HasPrivateKey) { $needsAdd = $false }
        }

        if ($needsAdd) {
            $store.Add($Certificate)
            Write-LogMessage "  Added $($Certificate.Thumbprint) to LocalMachine\$StoreName ($($Certificate.Subject))"
        } else {
            Write-LogMessage "  Already present in LocalMachine\${StoreName}: $($Certificate.Thumbprint)"
        }
        return $true
    } catch {
        Write-LogMessage "  ERROR: Failed to add $($Certificate.Thumbprint) to LocalMachine\${StoreName}: $_"
        return $false
    } finally {
        $store.Close()
    }
}

#endregion

#region ------------------------- Main --------------------------------------

function Update-IisCertificateBindings {

    Write-LogMessage "------------------------------------------"
    Write-LogMessage "IIS certificate replacement - START"
    Write-LogMessage "------------------------------------------"
    Write-LogMessage "  Site discovery mode : $IIS_SITE_DISCOVERY_MODE"
    Write-LogMessage "  Target sites        : $($IIS_TARGET_SITES -join ', ')"
    Write-LogMessage "  Certificate store   : LocalMachine\$IIS_CERT_STORE_NAME"
    Write-LogMessage "  Expected subject CN : $(if ([string]::IsNullOrWhiteSpace($IIS_EXPECTED_SUBJECT_CN)) { '<check disabled>' } else { $IIS_EXPECTED_SUBJECT_CN })"

    # ---- 1. Pre-flight ----------------------------------------------------
    if ([string]::IsNullOrEmpty($PFX_FILE)) {
        Write-LogMessage "ERROR: DC1_POST_SCRIPT_DATA contained no .pfx/.p12 file - nothing to deploy"
        $script:IIS_ERRORS++
        return
    }
    if (-not (Test-Path -LiteralPath $PFX_FILE_PATH)) {
        Write-LogMessage "ERROR: PFX file not found: $PFX_FILE_PATH"
        $script:IIS_ERRORS++
        return
    }

    $mwaDll = Join-Path $env:windir 'system32\inetsrv\Microsoft.Web.Administration.dll'
    if (-not ([System.Management.Automation.PSTypeName]'Microsoft.Web.Administration.ServerManager').Type) {
        if (-not (Test-Path -LiteralPath $mwaDll)) {
            Write-LogMessage "ERROR: $mwaDll not found - IIS does not appear to be installed on this host"
            $script:IIS_ERRORS++
            return
        }
        try {
            Add-Type -Path $mwaDll -ErrorAction Stop
        } catch {
            try {
                [void][System.Reflection.Assembly]::LoadFrom($mwaDll)
            } catch {
                Write-LogMessage "ERROR: Unable to load Microsoft.Web.Administration: $_"
                $script:IIS_ERRORS++
                return
            }
        }
    }
    Write-LogMessage "  Microsoft.Web.Administration is available"

    # ---- 2. Read and import the new certificate ---------------------------
    Write-LogMessage "------------------------------------------"
    Write-LogMessage "Importing new certificate"
    Write-LogMessage "------------------------------------------"

    $pfxPasswordOrNull = $null
    if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) { $pfxPasswordOrNull = $PFX_PASSWORD }

    $keyFlags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor `
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor `
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable

    $pfxCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    try {
        $pfxCollection.Import($PFX_FILE_PATH, $pfxPasswordOrNull, $keyFlags)
    } catch {
        Write-LogMessage "ERROR: Unable to read the PFX (wrong password or corrupt file?): $_"
        $script:IIS_ERRORS++
        return
    }
    Write-LogMessage "  PFX contains $($pfxCollection.Count) certificate(s)"

    $newCert = $pfxCollection | Where-Object { $_.HasPrivateKey } | Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $newCert) {
        Write-LogMessage "ERROR: The PFX holds no certificate with a private key - cannot be used for IIS"
        $script:IIS_ERRORS++
        return
    }

    $newThumbprint = $newCert.Thumbprint.ToUpperInvariant()
    $newCertCn = ''
    try { $newCertCn = $newCert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } catch { }
    $newCertSan = ''
    $sanExtension = $newCert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' } | Select-Object -First 1
    if ($sanExtension) { $newCertSan = ($sanExtension.Format($false) -replace '\s+', ' ') }

    Write-LogMessage "  Subject      : $($newCert.Subject)"
    Write-LogMessage "  Common name  : $newCertCn"
    Write-LogMessage "  SAN          : $newCertSan"
    Write-LogMessage "  Issuer       : $($newCert.Issuer)"
    Write-LogMessage "  Serial       : $($newCert.SerialNumber)"
    Write-LogMessage "  Thumbprint   : $newThumbprint"
    Write-LogMessage "  Valid from   : $($newCert.NotBefore)"
    Write-LogMessage "  Valid to     : $($newCert.NotAfter)"

    $rightNow = Get-Date
    if ($newCert.NotAfter -lt $rightNow) {
        Write-LogMessage "ERROR: The new certificate expired on $($newCert.NotAfter) - refusing to bind it"
        $script:IIS_ERRORS++
        return
    }
    if ($newCert.NotBefore -gt $rightNow) {
        Write-LogMessage "WARNING: The new certificate is not valid before $($newCert.NotBefore) - clients will reject it until then"
    }

    if (-not [string]::IsNullOrWhiteSpace($IIS_EXPECTED_SUBJECT_CN)) {
        $cnMatches = ($newCertCn -eq $IIS_EXPECTED_SUBJECT_CN) -or
                     ($newCert.Subject -match ('CN=' + [regex]::Escape($IIS_EXPECTED_SUBJECT_CN) + '(,|$)'))
        if (-not $cnMatches) {
            Write-LogMessage "ERROR: Safety check failed - expected CN '$IIS_EXPECTED_SUBJECT_CN' but the certificate CN is '$newCertCn'"
            Write-LogMessage "       No binding was touched. Set AWR Parameter 2 to NONE (or clear `$IIS_EXPECTED_SUBJECT_CN) to bypass."
            $script:IIS_ERRORS++
            return
        }
        Write-LogMessage "  CN safety check passed ($IIS_EXPECTED_SUBJECT_CN)"
    }

    if (-not (Add-CertificateToStore -Certificate $newCert -StoreName $IIS_CERT_STORE_NAME)) {
        $script:IIS_ERRORS++
        return
    }

    # Chain certificates: intermediates to CA, roots only when explicitly wanted.
    if ($IIS_IMPORT_CHAIN) {
        foreach ($chainCert in $pfxCollection) {
            if ($chainCert.Thumbprint -eq $newCert.Thumbprint) { continue }
            if ($chainCert.HasPrivateKey) { continue }
            if ($chainCert.Subject -eq $chainCert.Issuer) {
                if ($IIS_IMPORT_ROOT_CA) {
                    [void](Add-CertificateToStore -Certificate $chainCert -StoreName 'Root')
                } else {
                    Write-LogMessage "  Skipped self-signed root (set `$IIS_IMPORT_ROOT_CA = `$true to trust it): $($chainCert.Subject)"
                }
            } else {
                [void](Add-CertificateToStore -Certificate $chainCert -StoreName 'CA')
            }
        }
    }

    # Confirm the store copy really carries a usable private key.
    $storedCert = Get-ChildItem -Path "Cert:\LocalMachine\$IIS_CERT_STORE_NAME" |
                  Where-Object { $_.Thumbprint -eq $newThumbprint } | Select-Object -First 1
    if (-not $storedCert) {
        Write-LogMessage "ERROR: $newThumbprint is not present in LocalMachine\$IIS_CERT_STORE_NAME after import"
        $script:IIS_ERRORS++
        return
    }
    if (-not $storedCert.HasPrivateKey) {
        Write-LogMessage "ERROR: $newThumbprint was imported without a private key - IIS cannot use it"
        $script:IIS_ERRORS++
        return
    }
    Write-LogMessage "  Verified in LocalMachine\${IIS_CERT_STORE_NAME}: private key present"

    # ---- 3. Enumerate the https bindings ----------------------------------
    Write-LogMessage "------------------------------------------"
    Write-LogMessage "Collecting https bindings"
    Write-LogMessage "------------------------------------------"

    $serverManager = New-Object Microsoft.Web.Administration.ServerManager
    $bindingRecords = @()

    try {
        $allSites = @($serverManager.Sites)

        if ($IIS_SITE_DISCOVERY_MODE -eq 'AllHttps') {
            $siteNames = @($allSites |
                Where-Object { @($_.Bindings | Where-Object { $_.Protocol -eq 'https' }).Count -gt 0 } |
                ForEach-Object { $_.Name })
            Write-LogMessage "  Discovered sites with https bindings: $($siteNames -join ', ')"
        } else {
            $siteNames = @($IIS_TARGET_SITES)
        }

        foreach ($siteName in $siteNames) {
            $site = $allSites | Where-Object { $_.Name -eq $siteName } | Select-Object -First 1
            if (-not $site) {
                Write-LogMessage "ERROR: IIS site '$siteName' does not exist on this server"
                $script:IIS_ERRORS++
                continue
            }

            $siteState = 'unknown'
            try { $siteState = [string]$site.State } catch { }
            Write-LogMessage "  Site '$siteName' (id $($site.Id), state $siteState)"

            $httpsBindings = @($site.Bindings | Where-Object { $_.Protocol -eq 'https' })
            if ($httpsBindings.Count -eq 0) {
                Write-LogMessage "    WARNING: no https bindings on this site - skipped"
                continue
            }

            foreach ($binding in $httpsBindings) {
                $bindingInfo = [string]$binding.BindingInformation
                $parsed = Convert-BindingInformation -BindingInformation $bindingInfo
                if (-not $parsed) {
                    Write-LogMessage "    ERROR: could not parse bindingInformation '$bindingInfo' - skipped"
                    $script:IIS_ERRORS++
                    continue
                }

                $sslFlags = 0
                try { $sslFlags = [int]$binding.GetAttributeValue('sslFlags') } catch { $sslFlags = 0 }

                $oldConfigHash = ''
                try {
                    if ($binding.CertificateHash -and $binding.CertificateHash.Length -gt 0) {
                        $oldConfigHash = (($binding.CertificateHash | ForEach-Object { $_.ToString('X2') }) -join '')
                    }
                } catch { }
                $oldConfigStore = ''
                try { $oldConfigStore = [string]$binding.CertificateStoreName } catch { }

                $usesSni = (($sslFlags -band 1) -eq 1)
                $usesCcs = (($sslFlags -band 2) -eq 2)

                if ($usesCcs) {
                    Write-LogMessage "    Binding $bindingInfo uses the Centralised Certificate Store (sslFlags $sslFlags) - skipped, the certificate must be published to the CCS file share instead"
                    continue
                }

                if ($usesSni -and -not [string]::IsNullOrWhiteSpace($parsed.HostName)) {
                    $selector = "hostnameport=$($parsed.HostName):$($parsed.Port)"
                } else {
                    $selector = "ipport=$($parsed.Ip):$($parsed.Port)"
                    if ($usesSni) {
                        Write-LogMessage "    NOTE: binding $bindingInfo has SNI enabled but no host name - treated as an IP:port binding"
                    }
                }

                $record = New-Object PSObject
                $record | Add-Member -MemberType NoteProperty -Name Site           -Value $siteName
                $record | Add-Member -MemberType NoteProperty -Name BindingInfo    -Value $bindingInfo
                $record | Add-Member -MemberType NoteProperty -Name Ip             -Value $parsed.Ip
                $record | Add-Member -MemberType NoteProperty -Name Port           -Value $parsed.Port
                $record | Add-Member -MemberType NoteProperty -Name HostName       -Value $parsed.HostName
                $record | Add-Member -MemberType NoteProperty -Name SslFlags       -Value $sslFlags
                $record | Add-Member -MemberType NoteProperty -Name UsesSni        -Value $usesSni
                $record | Add-Member -MemberType NoteProperty -Name Selector       -Value $selector
                $record | Add-Member -MemberType NoteProperty -Name OldConfigHash  -Value $oldConfigHash
                $record | Add-Member -MemberType NoteProperty -Name OldConfigStore -Value $oldConfigStore
                $record | Add-Member -MemberType NoteProperty -Name OldHttpSysHash -Value ''
                $record | Add-Member -MemberType NoteProperty -Name AppId          -Value ''
                $record | Add-Member -MemberType NoteProperty -Name Binding        -Value $binding
                $bindingRecords += $record

                Write-LogMessage ("    {0,-32} sslFlags={1} {2,-14} current cert={3}" -f $bindingInfo, $sslFlags, $(if ($usesSni) { '(SNI)' } else { '(IP:port)' }), $(if ($oldConfigHash) { $oldConfigHash } else { '<none>' }))
            }
        }

        if ($bindingRecords.Count -eq 0) {
            Write-LogMessage "ERROR: No usable https bindings were found - nothing to update"
            $script:IIS_ERRORS++
            return
        }
        Write-LogMessage "  $($bindingRecords.Count) https binding(s) queued across $(@($bindingRecords | Select-Object -ExpandProperty Site -Unique).Count) site(s)"

        # ---- 4. Snapshot http.sys and write the rollback script ------------
        Write-LogMessage "------------------------------------------"
        Write-LogMessage "Current http.sys SSL registrations"
        Write-LogMessage "------------------------------------------"

        $uniqueSelectors = @($bindingRecords | Select-Object -ExpandProperty Selector -Unique)
        $registrationBySelector = @{}
        foreach ($selector in $uniqueSelectors) {
            $registration = Get-HttpSslRegistration -Selector $selector
            if ($registration) {
                $registrationBySelector[$selector] = $registration
                Write-LogMessage ("  {0,-46} cert={1} appid={2} store={3}" -f $selector, $registration.Thumbprint, $registration.AppId, $registration.StoreName)
            } else {
                Write-LogMessage ("  {0,-46} not registered in http.sys yet" -f $selector)
            }
        }
        foreach ($record in $bindingRecords) {
            if ($registrationBySelector.ContainsKey($record.Selector)) {
                $record.OldHttpSysHash = $registrationBySelector[$record.Selector].Thumbprint
                $record.AppId          = $registrationBySelector[$record.Selector].AppId
            }
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        try {
            if (-not (Test-Path -LiteralPath $IIS_ROLLBACK_DIR)) {
                New-Item -ItemType Directory -Path $IIS_ROLLBACK_DIR -Force | Out-Null
            }

            $snapshot = $bindingRecords | Select-Object Site, BindingInfo, Ip, Port, HostName, SslFlags, UsesSni, Selector, OldConfigHash, OldConfigStore, OldHttpSysHash, AppId
            $snapshotPath = Join-Path $IIS_ROLLBACK_DIR "snapshot-$stamp.json"
            $snapshot | ConvertTo-Json -Depth 4 | Set-Content -Path $snapshotPath -Encoding UTF8
            Write-LogMessage "  Pre-change snapshot written to $snapshotPath"

            $rollbackLines = @(
                '@echo off',
                'REM Rollback of the IIS certificate replacement performed by the DigiCert TLM AWR script',
                "REM Generated $stamp - new thumbprint that was applied: $newThumbprint",
                'REM Run from an elevated command prompt.',
                ''
            )
            foreach ($selector in $uniqueSelectors) {
                if ($registrationBySelector.ContainsKey($selector)) {
                    $registration = $registrationBySelector[$selector]
                    $rollbackAppId = $registration.AppId
                    if ([string]::IsNullOrWhiteSpace($rollbackAppId)) { $rollbackAppId = $IIS_DEFAULT_APPID }
                    $rollbackStore = $registration.StoreName
                    if ([string]::IsNullOrWhiteSpace($rollbackStore)) { $rollbackStore = 'MY' }
                    $rollbackLines += "netsh http delete sslcert $selector"
                    $rollbackLines += "netsh http add sslcert $selector certhash=$($registration.Thumbprint) appid=$rollbackAppId certstorename=$rollbackStore"
                } else {
                    $rollbackLines += "REM $selector had no http.sys registration before the change"
                    $rollbackLines += "netsh http delete sslcert $selector"
                }
            }
            $rollbackLines += ''
            $rollbackLines += 'REM applicationHost.config'
            foreach ($record in $bindingRecords) {
                if ([string]::IsNullOrWhiteSpace($record.OldConfigHash)) {
                    $rollbackLines += "REM $($record.Site) $($record.BindingInfo) had no certificateHash in applicationHost.config"
                    continue
                }
                $rollbackStore = $record.OldConfigStore
                if ([string]::IsNullOrWhiteSpace($rollbackStore)) { $rollbackStore = 'My' }
                $dq = '"'
                $bindingFilter = "/bindings.[protocol='https',bindingInformation='$($record.BindingInfo)']"
                $rollbackLines += ('"%windir%\system32\inetsrv\appcmd.exe" set site /site.name:' + $dq + $record.Site + $dq +
                    ' ' + $dq + $bindingFilter + '.certificateHash:' + $record.OldConfigHash + $dq +
                    ' ' + $dq + $bindingFilter + '.certificateStoreName:' + $rollbackStore + $dq)
            }
            $rollbackPath = Join-Path $IIS_ROLLBACK_DIR "rollback-$stamp.cmd"
            $rollbackLines | Set-Content -Path $rollbackPath -Encoding ASCII
            Write-LogMessage "  Rollback script written to $rollbackPath"
        } catch {
            Write-LogMessage "  WARNING: Could not write the rollback artefacts to ${IIS_ROLLBACK_DIR}: $_"
        }

        # ---- 5. Update applicationHost.config -----------------------------
        Write-LogMessage "------------------------------------------"
        Write-LogMessage "Updating applicationHost.config"
        Write-LogMessage "------------------------------------------"

        $newHashBytes = $newCert.GetCertHash()
        $configChanges = 0
        foreach ($record in $bindingRecords) {
            if ($record.OldConfigHash -eq $newThumbprint -and $record.OldConfigStore -eq $IIS_CERT_STORE_NAME) {
                Write-LogMessage "  $($record.Site) / $($record.BindingInfo) already points at the new certificate"
                continue
            }
            try {
                $record.Binding.CertificateHash      = $newHashBytes
                $record.Binding.CertificateStoreName = $IIS_CERT_STORE_NAME
                $configChanges++
                Write-LogMessage "  $($record.Site) / $($record.BindingInfo): $(if ($record.OldConfigHash) { $record.OldConfigHash } else { '<none>' }) -> $newThumbprint"
            } catch {
                Write-LogMessage "  ERROR: $($record.Site) / $($record.BindingInfo): could not stage the certificate change: $_"
                $script:IIS_ERRORS++
            }
        }

        if ($configChanges -gt 0) {
            try {
                $serverManager.CommitChanges()
                Write-LogMessage "  Committed $configChanges binding change(s) to applicationHost.config"
            } catch {
                Write-LogMessage "ERROR: Failed to commit applicationHost.config: $_"
                Write-LogMessage "       Check that the TLM agent runs elevated and that no other process holds the file."
                $script:IIS_ERRORS++
                return
            }
        } else {
            Write-LogMessage "  applicationHost.config already up to date - nothing committed"
        }
    } finally {
        if ($serverManager) { $serverManager.Dispose() }
    }

    # ---- 6. Update the http.sys SSL registrations --------------------------
    Write-LogMessage "------------------------------------------"
    Write-LogMessage "Updating http.sys SSL registrations"
    Write-LogMessage "------------------------------------------"

    $uniqueSelectors = @($bindingRecords | Select-Object -ExpandProperty Selector -Unique)
    foreach ($selector in $uniqueSelectors) {
        $record = $bindingRecords | Where-Object { $_.Selector -eq $selector } | Select-Object -First 1
        $sites = @($bindingRecords | Where-Object { $_.Selector -eq $selector } | Select-Object -ExpandProperty Site -Unique) -join ', '
        Write-LogMessage "  $selector (used by: $sites)"

        $current = Get-HttpSslRegistration -Selector $selector
        if ($current -and $current.Thumbprint -eq $newThumbprint) {
            Write-LogMessage "    Already serving $newThumbprint - no netsh change required"
            continue
        }

        # The app id is preserved so the binding keeps its IIS ownership marker,
        # but the store name must be the store the certificate was imported into.
        $appId = ''
        if ($current) { $appId = $current.AppId }
        $storeName = $IIS_CERT_STORE_NAME.ToUpperInvariant()

        if (Set-HttpSslRegistration -Selector $selector -Thumbprint $newThumbprint -AppId $appId -StoreName $storeName) {
            continue
        }

        $script:IIS_ERRORS++
        if ($current) {
            Write-LogMessage "    Attempting to restore the previous registration ($($current.Thumbprint))"
            if (Set-HttpSslRegistration -Selector $selector -Thumbprint $current.Thumbprint -AppId $current.AppId -StoreName $current.StoreName) {
                Write-LogMessage "    Previous registration restored for $selector"
            } else {
                Write-LogMessage "    ERROR: $selector now has NO certificate registered - run the generated rollback script"
            }
        }
    }

    # ---- 7. Verification ---------------------------------------------------
    Write-LogMessage "------------------------------------------"
    Write-LogMessage "Verification"
    Write-LogMessage "------------------------------------------"

    $verifyManager = New-Object Microsoft.Web.Administration.ServerManager
    try {
        foreach ($record in $bindingRecords) {
            $site = $verifyManager.Sites | Where-Object { $_.Name -eq $record.Site } | Select-Object -First 1
            if (-not $site) { continue }
            $binding = $site.Bindings | Where-Object { $_.Protocol -eq 'https' -and [string]$_.BindingInformation -eq $record.BindingInfo } | Select-Object -First 1
            if (-not $binding) {
                Write-LogMessage "  ERROR: $($record.Site) / $($record.BindingInfo) disappeared during the update"
                $script:IIS_ERRORS++
                continue
            }
            $liveHash = ''
            try {
                if ($binding.CertificateHash -and $binding.CertificateHash.Length -gt 0) {
                    $liveHash = (($binding.CertificateHash | ForEach-Object { $_.ToString('X2') }) -join '')
                }
            } catch { }
            if ($liveHash -eq $newThumbprint) {
                Write-LogMessage "  CONFIG OK   $($record.Site) / $($record.BindingInfo)"
            } else {
                Write-LogMessage "  CONFIG FAIL $($record.Site) / $($record.BindingInfo) - config holds '$liveHash', expected '$newThumbprint'"
                $script:IIS_ERRORS++
            }
        }
    } finally {
        if ($verifyManager) { $verifyManager.Dispose() }
    }

    foreach ($selector in $uniqueSelectors) {
        $registration = Get-HttpSslRegistration -Selector $selector
        if ($registration -and $registration.Thumbprint -eq $newThumbprint) {
            Write-LogMessage "  HTTP.SYS OK   $selector"
        } elseif ($registration) {
            Write-LogMessage "  HTTP.SYS FAIL $selector - registered '$($registration.Thumbprint)', expected '$newThumbprint'"
            $script:IIS_ERRORS++
        } else {
            Write-LogMessage "  HTTP.SYS FAIL $selector - no registration found"
            $script:IIS_ERRORS++
        }
    }

    if ($IIS_VERIFY_TLS_HANDSHAKE) {
        foreach ($record in $bindingRecords) {
            $connectIp = $record.Ip
            if ($connectIp -eq '0.0.0.0' -or $connectIp -eq '*') { $connectIp = '127.0.0.1' }

            if ($record.UsesSni -and -not [string]::IsNullOrWhiteSpace($record.HostName)) {
                $sniName = $record.HostName
            } else {
                # An IP literal suppresses the SNI extension, so http.sys answers
                # from the ipport registration - which is what we want to test.
                $sniName = $connectIp
            }

            $servedThumbprint = Get-ServedCertificateThumbprint -ConnectIp $connectIp -Port $record.Port -SniName $sniName
            if ($servedThumbprint -eq $newThumbprint) {
                Write-LogMessage "  TLS OK        $($record.Site) ${connectIp}:$($record.Port) (SNI '$sniName')"
            } elseif ($servedThumbprint) {
                Write-LogMessage "  TLS FAIL      $($record.Site) ${connectIp}:$($record.Port) (SNI '$sniName') served '$servedThumbprint', expected '$newThumbprint'"
                $script:IIS_ERRORS++
            } else {
                Write-LogMessage "  TLS SKIPPED   $($record.Site) ${connectIp}:$($record.Port) - endpoint unreachable (site stopped or firewalled?). Config and http.sys checks above are authoritative."
            }
        }
    }

    # ---- 8. Optionally retire the replaced certificate ---------------------
    if ($IIS_REMOVE_REPLACED_CERTS -and $script:IIS_ERRORS -eq 0) {
        Write-LogMessage "------------------------------------------"
        Write-LogMessage "Removing replaced certificate(s)"
        Write-LogMessage "------------------------------------------"

        $replacedThumbprints = @($bindingRecords |
            ForEach-Object { $_.OldConfigHash; $_.OldHttpSysHash } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.ToUpperInvariant() -ne $newThumbprint } |
            ForEach-Object { $_.ToUpperInvariant() } |
            Select-Object -Unique)

        if ($replacedThumbprints.Count -eq 0) {
            Write-LogMessage "  Nothing to remove"
        } else {
            $allSslCerts = (Invoke-NetshHttp @('http', 'show', 'sslcert')).Output
            foreach ($oldThumbprint in $replacedThumbprints) {
                if ($allSslCerts -match $oldThumbprint) {
                    Write-LogMessage "  Kept $oldThumbprint - still registered on another http.sys endpoint"
                    continue
                }
                $oldCert = Get-ChildItem -Path "Cert:\LocalMachine\$IIS_CERT_STORE_NAME" |
                           Where-Object { $_.Thumbprint -eq $oldThumbprint } | Select-Object -First 1
                if (-not $oldCert) {
                    Write-LogMessage "  $oldThumbprint is not in LocalMachine\$IIS_CERT_STORE_NAME - nothing to do"
                    continue
                }
                try {
                    Remove-Item -Path $oldCert.PSPath -Force
                    Write-LogMessage "  Removed $oldThumbprint ($($oldCert.Subject)) from LocalMachine\$IIS_CERT_STORE_NAME"
                } catch {
                    Write-LogMessage "  WARNING: could not remove ${oldThumbprint}: $_"
                }
            }
        }
    } elseif ($IIS_REMOVE_REPLACED_CERTS) {
        Write-LogMessage "Skipping removal of the replaced certificate because errors were reported above"
    }

    Write-LogMessage "------------------------------------------"
    Write-LogMessage "IIS certificate replacement - END"
    Write-LogMessage "  Sites processed  : $(@($bindingRecords | Select-Object -ExpandProperty Site -Unique) -join ', ')"
    Write-LogMessage "  Bindings updated : $($bindingRecords.Count)"
    Write-LogMessage "  New thumbprint   : $newThumbprint"
    Write-LogMessage "  Errors           : $script:IIS_ERRORS"
    Write-LogMessage "------------------------------------------"
    return
}

Update-IisCertificateBindings | Out-Null

if ($script:IIS_ERRORS -gt 0) {
    Write-LogMessage "ERROR: IIS certificate replacement finished with $script:IIS_ERRORS error(s) - see the entries above"
    $FINAL_EXIT_CODE = 1
} else {
    Write-LogMessage "IIS certificate replacement completed successfully"
}

#endregion




# ----------------------------------------
# END OF CUSTOM LOGIC

Write-LogMessage "Custom script section completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed (exit code $FINAL_EXIT_CODE)"
Write-LogMessage "=========================================="

exit $FINAL_EXIT_CODE