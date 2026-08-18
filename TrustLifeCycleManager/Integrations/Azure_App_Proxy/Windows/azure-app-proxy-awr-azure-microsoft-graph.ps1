<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (PFX Format) - Azure App Proxy Upload
.DESCRIPTION
    Processes certificate data delivered by the DigiCert TLM Agent (PFX format) and
    uploads the certificate to an Entra ID Application Proxy (onPremisesPublishing)
    via Microsoft Graph.

    This script is built on the standard AWR post-enrollment template. It receives all
    certificate data from the TLM Agent through the DC1_POST_SCRIPT_DATA environment
    variable (Base64-encoded JSON) and is therefore invoked NON-INTERACTIVELY.

    IMPORTANT: Do NOT add a param() block to this script. The TLM Agent does not pass
    named PowerShell parameters; a [Parameter(Mandatory)] declaration will cause the
    agent run to fail (or hang) during parameter binding, before any log line is written,
    even though the same script runs fine when launched by hand. Target/connection values
    are configured in the CONFIGURATION section below instead.
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

# The Microsoft.Graph module exposes a very large number of functions/variables.
# On Windows PowerShell 5.1 this can exceed the default runspace limits when the
# module is imported, so raise them before anything else runs.
$MaximumFunctionCount = 32768
$MaximumVariableCount = 32768

# ============================================================================
# CONFIGURATION
# ============================================================================
$LEGAL_NOTICE_ACCEPT = "false"   # Set to "true" to accept the legal notice and proceed with execution
$LOGFILE             = "C:\Certs\azure-app-proxy.log"

# Dry-run mode:
#   "true"  = do NOT call Microsoft Graph. Instead, log the exact Graph operations
#             (cmdlets, parameters, and payload shape) that WOULD have been executed.
#             Secrets, the PFX password, and the raw PFX bytes are never written out.
#   "false" = execute the Graph operations for real.
$DRY_RUN = "false"

# ---- Azure / Entra ID configuration ----------------------------------------
# All values below are configured here (top of file) rather than passed as AWR
# arguments, so this script targets one fixed Application Proxy per deployment.

$AZURE_TENANT_ID       = "7637ffcf-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # Entra ID tenant ID
$AZURE_CONNECTION_APPID = "551fee0c-xxxx-xxxx-xxxx-xxxxxxxxxxxx"  # App registration (client) ID used to authenticate to Graph
$AZURE_CLIENT_SECRET   = "xxxxxxxxxxxxxxx-xxxxxxxx"   # Client secret for the connection app registration (KEEP SECURE)

# Object/App ID of the TARGET Application Proxy in Entra ID whose custom-domain
# certificate should be replaced. (Previously supplied as -targetapplicationID;
# now a fixed configuration value.)
$APP_PROXY_OBJECT_ID   = "8f473c7e-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# ---- Optional: certificate-based auth alternative ---------------------------
# If you prefer certificate auth over a client secret, populate a thumbprint and
# switch the Connect-MgGraph call in the custom section accordingly, e.g.:
# $AZURE_CERT_THUMBPRINT = (Get-ChildItem Cert:\LocalMachine\My |
#     Where-Object { $_.Subject -like "*your-graph-auth-cert*" }).Thumbprint

# ============================================================================
# FUNCTIONS
# ============================================================================
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# ============================================================================
# START
# ============================================================================
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format) - Azure App Proxy Upload"
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

# Log initial configuration (never log the client secret in plaintext)
Write-LogMessage "Configuration:"
Write-LogMessage "  LEGAL_NOTICE_ACCEPT : $LEGAL_NOTICE_ACCEPT"
Write-LogMessage "  DRY_RUN             : $DRY_RUN"
Write-LogMessage "  LOGFILE             : $LOGFILE"
Write-LogMessage "  AZURE_TENANT_ID     : $AZURE_TENANT_ID"
Write-LogMessage "  CONNECTION_APPID    : $AZURE_CONNECTION_APPID"
Write-LogMessage "  APP_PROXY_OBJECT_ID : $APP_PROXY_OBJECT_ID"
if (-not [string]::IsNullOrEmpty($AZURE_CLIENT_SECRET)) {
    Write-LogMessage "  CLIENT_SECRET       : Configured ($($AZURE_CLIENT_SECRET.Length) characters, value not logged)"
} else {
    Write-LogMessage "  CLIENT_SECRET       : NOT configured"
}

# ============================================================================
# READ AND DECODE TLM AGENT DATA
# ============================================================================
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
    $JSON_BYTES  = [System.Convert]::FromBase64String($CERT_INFO)
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

# ============================================================================
# EXTRACT ARGUMENTS FROM JSON (AWR Parameters 1-15)
# ============================================================================
# Retained from the standard template so the documented $ARGUMENT_1..15 variables
# are available in the custom section, even though this script sources its target
# configuration from the CONFIGURATION block above.
Write-LogMessage "Extracting arguments from JSON..."

$ARGUMENT_1 = ""; $ARGUMENT_2 = ""; $ARGUMENT_3 = ""; $ARGUMENT_4 = ""; $ARGUMENT_5 = ""
$ARGUMENT_6 = ""; $ARGUMENT_7 = ""; $ARGUMENT_8 = ""; $ARGUMENT_9 = ""; $ARGUMENT_10 = ""
$ARGUMENT_11 = ""; $ARGUMENT_12 = ""; $ARGUMENT_13 = ""; $ARGUMENT_14 = ""; $ARGUMENT_15 = ""

if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"

    for ($i = 0; $i -lt [Math]::Min($ARGS_ARRAY.Count, 15); $i++) {
        $value = ($ARGS_ARRAY[$i] -replace '\s', '').Trim()
        Set-Variable -Name "ARGUMENT_$($i + 1)" -Value $value
        Write-LogMessage "ARGUMENT_$($i + 1) extracted: '$value' (length: $($value.Length))"
    }
}

# ============================================================================
# EXTRACT CERTIFICATE DETAILS FROM JSON
# ============================================================================
# Extract cert folder
$CERT_FOLDER = $JSON_OBJECT.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .pfx / .p12 file name
$PFX_FILE = ""
if ($JSON_OBJECT.files) {
    $PFX_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.pfx$|\.p12$' } | Select-Object -First 1
}
Write-LogMessage "Extracted PFX_FILE: $PFX_FILE"

# Extract the PFX password from JSON (check common field names)
$PFX_PASSWORD = ""
if     ($JSON_OBJECT.password)           { $PFX_PASSWORD = $JSON_OBJECT.password }
elseif ($JSON_OBJECT.pfx_password)       { $PFX_PASSWORD = $JSON_OBJECT.pfx_password }
elseif ($JSON_OBJECT.keystore_password)  { $PFX_PASSWORD = $JSON_OBJECT.keystore_password }
elseif ($JSON_OBJECT.passphrase)         { $PFX_PASSWORD = $JSON_OBJECT.passphrase }

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "ERROR: No PFX password found in JSON"
    exit 1
} else {
    Write-LogMessage "PFX password extracted from JSON (length: $($PFX_PASSWORD.Length) characters)"
    # Obfuscated confirmation only - never log the full password
    if ($PFX_PASSWORD.Length -ge 3) {
        Write-LogMessage "PFX password (masked): $($PFX_PASSWORD.Substring(0,3))***"
    } else {
        Write-LogMessage "PFX password (masked): ***"
    }
}

# Construct full PFX path
$PFX_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $PFX_FILE
$FILES_ARRAY   = $JSON_OBJECT.files -join ','

# ============================================================================
# EXTRACTION SUMMARY
# ============================================================================
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "  Certificate folder : $CERT_FOLDER"
Write-LogMessage "  PFX file           : $PFX_FILE"
Write-LogMessage "  PFX file path      : $PFX_FILE_PATH"
Write-LogMessage "  All files in array : $FILES_ARRAY"
Write-LogMessage "=========================================="

# ============================================================================
# VALIDATE PFX AND CAPTURE CERTIFICATE DETAILS
# ============================================================================
if (-not (Test-Path $PFX_FILE_PATH)) {
    Write-LogMessage "ERROR: PFX file not found: $PFX_FILE_PATH"
    exit 1
}

$CERT_SERIAL     = ""
$CERT_THUMBPRINT = ""
try {
    $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
    $pfxCert   = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PFX_FILE_PATH, $securePwd)

    Write-LogMessage "PFX file validated successfully"
    Write-LogMessage "=========================================="
    Write-LogMessage "Certificate Details:"
    Write-LogMessage "  Subject             : $($pfxCert.Subject)"
    Write-LogMessage "  Issuer              : $($pfxCert.Issuer)"
    Write-LogMessage "  Serial Number       : $($pfxCert.SerialNumber)"
    Write-LogMessage "  Thumbprint          : $($pfxCert.Thumbprint)"
    Write-LogMessage "  Valid From          : $($pfxCert.NotBefore)"
    Write-LogMessage "  Valid To            : $($pfxCert.NotAfter)"
    Write-LogMessage "  Signature Algorithm : $($pfxCert.SignatureAlgorithm.FriendlyName)"
    Write-LogMessage "  Has Private Key     : $($pfxCert.HasPrivateKey)"
    Write-LogMessage "=========================================="

    # Capture for post-upload verification
    $CERT_SERIAL     = $pfxCert.SerialNumber
    $CERT_THUMBPRINT = $pfxCert.Thumbprint

    $pfxCert.Dispose()
} catch {
    Write-LogMessage "ERROR: Failed to validate PFX file: $_"
    exit 1
}

# ============================================================================
# CUSTOM SCRIPT SECTION - AZURE APP PROXY UPLOAD
# ============================================================================
#
# Available variables for custom logic:
#   $CERT_FOLDER      - Folder path where certificates are stored
#   $PFX_FILE         - PFX/P12 filename only
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file
#   $PFX_PASSWORD     - Password for the PFX/P12 file
#   $CERT_SERIAL      - Serial number of the validated certificate
#   $CERT_THUMBPRINT  - Thumbprint of the validated certificate
#   $ARGUMENT_1..15   - AWR Parameters from the JSON args array (unused here)
#   $JSON_STRING      - Complete decoded JSON string
#   $JSON_OBJECT      - Parsed JSON object
#
# Configuration values (from top of file):
#   $AZURE_TENANT_ID, $AZURE_CONNECTION_APPID, $AZURE_CLIENT_SECRET, $APP_PROXY_OBJECT_ID
#
# Utility:
#   Write-LogMessage "text" - timestamped log entry
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting Azure App Proxy certificate upload..."
Write-LogMessage "=========================================="

# --- Validate required configuration before attempting any Graph call --------
$missingConfig = @()
if ([string]::IsNullOrEmpty($AZURE_TENANT_ID))        { $missingConfig += "AZURE_TENANT_ID" }
if ([string]::IsNullOrEmpty($AZURE_CONNECTION_APPID)) { $missingConfig += "AZURE_CONNECTION_APPID" }
if ([string]::IsNullOrEmpty($AZURE_CLIENT_SECRET))    { $missingConfig += "AZURE_CLIENT_SECRET" }
if ([string]::IsNullOrEmpty($APP_PROXY_OBJECT_ID))    { $missingConfig += "APP_PROXY_OBJECT_ID" }

if ($missingConfig.Count -gt 0) {
    if ($DRY_RUN -eq "true") {
        # In dry run we still want to preview the intended operations, so a missing
        # value is only a warning here rather than a hard stop.
        Write-LogMessage "WARNING (dry run): Missing configuration value(s): $($missingConfig -join ', ')"
        Write-LogMessage "Continuing dry run so the intended Graph operations can still be previewed."
    } else {
        Write-LogMessage "ERROR: Missing required configuration value(s): $($missingConfig -join ', ')"
        Write-LogMessage "Populate these in the CONFIGURATION section at the top of the script."
        exit 1
    }
}

# --- Build the onPremisesPublishing update body ------------------------------
# This is a local, side-effect-free operation and is done the same way in both
# dry-run and live mode. The Graph body requires the PFX bytes (Base64) and the
# PFX password in plaintext; $PFX_PASSWORD is already plaintext from the TLM JSON,
# so it is used directly - no SecureString round-trip is needed.
# Reading the file here also confirms, during a dry run, that the PFX is readable
# and reports the resulting payload size.
Write-LogMessage "Preparing certificate payload for App Proxy update..."
Write-LogMessage "  Target App Object ID : $APP_PROXY_OBJECT_ID"
Write-LogMessage "  PFX Path             : $PFX_FILE_PATH"

$pfxBytes  = [System.IO.File]::ReadAllBytes($PFX_FILE_PATH)
$pfxBase64 = [System.Convert]::ToBase64String($pfxBytes)

$params = @{
    onPremisesPublishing = @{
        verifiedCustomDomainKeyCredential = @{
            type  = "X509CertAndPassword"
            value = $pfxBase64
        }
        verifiedCustomDomainPasswordCredential = @{
            value = $PFX_PASSWORD
        }
    }
}

$verifyUri = "https://graph.microsoft.com/beta/applications/$APP_PROXY_OBJECT_ID/onPremisesPublishing"

try {
    if ($DRY_RUN -eq "true") {
        # ====================================================================
        # DRY RUN - log the intended Graph operations, execute nothing
        # ====================================================================
        Write-LogMessage "=========================================="
        Write-LogMessage "DRY RUN ENABLED - no Microsoft Graph calls will be made."
        Write-LogMessage "The following operations WOULD have been executed:"
        Write-LogMessage "=========================================="
        Write-LogMessage "[DRY RUN] Import-Module Microsoft.Graph"
        Write-LogMessage "[DRY RUN] Connect-MgGraph -TenantId '$AZURE_TENANT_ID' ``"
        Write-LogMessage "[DRY RUN]     -ClientSecretCredential <PSCredential UserName='$AZURE_CONNECTION_APPID' Password=*** (client secret, not logged)> ``"
        Write-LogMessage "[DRY RUN]     -NoWelcome"
        Write-LogMessage "[DRY RUN] Update-MgApplication -ApplicationId '$APP_PROXY_OBJECT_ID' -BodyParameter <payload>"
        Write-LogMessage "[DRY RUN]     payload.onPremisesPublishing.verifiedCustomDomainKeyCredential.type      = X509CertAndPassword"
        Write-LogMessage "[DRY RUN]     payload.onPremisesPublishing.verifiedCustomDomainKeyCredential.value     = <Base64 PFX: $($pfxBytes.Length) bytes / $($pfxBase64.Length) Base64 chars> (value not logged)"
        Write-LogMessage "[DRY RUN]     payload.onPremisesPublishing.verifiedCustomDomainPasswordCredential.value = *** (PFX password, not logged)"
        Write-LogMessage "[DRY RUN] Invoke-MgGraphRequest -Method GET -Uri '$verifyUri'"
        Write-LogMessage "[DRY RUN] Disconnect-MgGraph"
        Write-LogMessage "=========================================="
        Write-LogMessage "DRY RUN complete - no changes were made to Azure App Proxy."
    }
    else {
        # ====================================================================
        # LIVE RUN - execute the Graph operations
        # ====================================================================

        # --- Build the client-secret credential for Graph authentication -----
        $secureSecret           = ConvertTo-SecureString -String $AZURE_CLIENT_SECRET -AsPlainText -Force
        $ClientSecretCredential = New-Object System.Management.Automation.PSCredential($AZURE_CONNECTION_APPID, $secureSecret)

        # --- Import the Microsoft Graph module -------------------------------
        # NOTE: The TLM Agent runs as LocalSystem (or a dedicated service account).
        # Install Microsoft.Graph with -Scope AllUsers so it is visible to that
        # identity; a CurrentUser-scoped install under an interactive profile will
        # NOT be found here and this import will fail.
        Write-LogMessage "Importing Microsoft.Graph module..."
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module Microsoft.Graph.Applications -ErrorAction Stop
        Write-LogMessage "Microsoft.Graph module imported successfully"

        # --- Connect to Graph ------------------------------------------------
        Write-LogMessage "Connecting to Microsoft Graph (Tenant: $AZURE_TENANT_ID)..."
        Connect-MgGraph -TenantId $AZURE_TENANT_ID -ClientSecretCredential $ClientSecretCredential -NoWelcome -ErrorAction Stop
        Write-LogMessage "Connected to Microsoft Graph successfully"

        # --- Upload the certificate ------------------------------------------
        # onPremisesPublishing is beta-only; Update-MgApplication targets v1.0 and rejects it.
        Write-LogMessage "Uploading certificate to Application Proxy..."
        $updateUri = "https://graph.microsoft.com/beta/applications/$APP_PROXY_OBJECT_ID"
        Invoke-MgGraphRequest -Method PATCH -Uri $updateUri -Body ($params | ConvertTo-Json -Depth 10) -ContentType "application/json" -ErrorAction Stop
        Write-LogMessage "Certificate uploaded to Azure App Proxy successfully!"

        # --- Verify the upload -----------------------------------------------
        Write-LogMessage "=========================================="
        Write-LogMessage "Verifying certificate upload..."
        Write-LogMessage "=========================================="

        # $APP_PROXY_OBJECT_ID is the application object ID; query onPremisesPublishing directly.
        $certMetadata = Invoke-MgGraphRequest -Method GET -Uri $verifyUri -ErrorAction Stop

        if ($certMetadata) {
            $meta = $certMetadata.verifiedCustomDomainCertificatesMetadata

            Write-LogMessage "Certificate verified on Azure App Proxy:"
            Write-LogMessage "  External URL   : $($certMetadata.externalUrl)"
            Write-LogMessage "  Subject        : $($meta.subjectName)"
            Write-LogMessage "  Thumbprint     : $($meta.thumbprint)"
            Write-LogMessage "  Issue Date     : $($meta.issueDate)"
            Write-LogMessage "  Expiry Date    : $($meta.expiryDate)"
            Write-LogMessage "  Serial Number  : $CERT_SERIAL"

            # Thumbprint match check (compare case-insensitively; Graph may omit separators)
            if ($meta.thumbprint) {
                $reported = ($meta.thumbprint -replace '[^0-9A-Fa-f]', '')
                $expected = ($CERT_THUMBPRINT -replace '[^0-9A-Fa-f]', '')
                if ($reported -ieq $expected) {
                    Write-LogMessage "SUCCESS: Thumbprint verification passed - certificate matches!"
                } else {
                    Write-LogMessage "WARNING: Thumbprint mismatch!"
                    Write-LogMessage "  Expected : $expected"
                    Write-LogMessage "  Found    : $reported"
                }
            }

            # Days until expiry
            if ($meta.expiryDate) {
                try {
                    $expiryDate      = [DateTime]::Parse($meta.expiryDate)
                    $daysUntilExpiry = ($expiryDate - (Get-Date)).Days
                    Write-LogMessage "  Days until expiry: $daysUntilExpiry"
                } catch {
                    Write-LogMessage "WARNING: Could not parse expiry date '$($meta.expiryDate)': $_"
                }
            }
        } else {
            Write-LogMessage "WARNING: Could not retrieve certificate metadata for verification"
        }

        # --- Clean session teardown ------------------------------------------
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-LogMessage "Disconnected from Microsoft Graph"
    }
} catch {
    Write-LogMessage "ERROR: Azure App Proxy upload failed: $_"
    Write-LogMessage "Error details: $($_.Exception.Message)"
    # Best-effort disconnect before exiting (no-op in dry run / if never connected)
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
    exit 1
} finally {
    # Clear the secret and the in-memory PFX bytes as soon as we are done
    if ($secureSecret) { $secureSecret.Dispose() }
    if ($pfxBytes)     { [Array]::Clear($pfxBytes, 0, $pfxBytes.Length) }
}

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed successfully"
Write-LogMessage "=========================================="

exit 0