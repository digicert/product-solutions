<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (PFX Format) - MS Remote Desktop Services
.DESCRIPTION
    Admin Web Request (AWR) template that decodes the DC1_POST_SCRIPT_DATA payload, imports the
    delivered PFX, and applies it to the RDP-Tcp listener and the RDS roles (Publishing, Web Access,
    SSO/Redirector). In a high-availability deployment it is intended to run on the RD Connection
    Broker that currently holds the RD Management Server role. The certificate import and RDP-Tcp
    listener are local operations that always run; the deployment-level roles (applied once via the
    broker, which distributes them to the role servers) are only attempted when an actual RDS
    deployment is detected, otherwise they are skipped with a note rather than recorded as failures.
    Any enabled step that genuinely fails is recorded and the script exits non-zero so Trust
    Lifecycle Manager reflects the true outcome instead of a false "success".
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
$LEGAL_NOTICE_ACCEPT = "true"   # Set to "true" to accept the legal notice and allow execution.
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\awr-template-logfile.log"

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
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
# CUSTOM SCRIPT SECTION - MS REMOTE DESKTOP SERVICES CERTIFICATE DEPLOYMENT
# ============================================================================
#
# Available variables (populated above):
#   $CERT_FOLDER      - Folder where certificates are stored
#   $PFX_FILE         - PFX/P12 filename only
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file
#   $PFX_PASSWORD     - Password for the PFX/P12 file
#   $FILES_ARRAY      - Comma-joined list of delivered files
#   $ARGUMENT_1..15   - AWR parameters from the JSON args array
#   $JSON_OBJECT      - Parsed JSON object
#   Write-LogMessage "text" - timestamped logging
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section (RDS certificate deployment)..."
Write-LogMessage "=========================================="

# ---- Which artifacts to configure -------------------------------------------------
$Install_RDP_Listener_Certificate   = $true    # RDP-Tcp listener certificate (local, via WMI)
$Install_RDS_Publishing_Certificate = $true    # RD Connection Broker Publishing certificate
$Install_RDS_WebAccess_Certificate  = $true    # RD Web Access certificate
$Install_RDS_SSO_Certificate        = $true    # RD SSO / Redirector certificate

# Optional RD Connection Broker FQDN. Leave empty to operate against the local deployment.
# Can also be supplied via AWR Parameter 1 ($ARGUMENT_1). When set, it is passed as
# -ConnectionBroker to the RDS cmdlets; the certificate must be resolvable by that broker.
#
# NOTE: on a standalone RD Session Host, ARGUMENT_1 is often the host's own FQDN. That host is
# NOT a Connection Broker and has no deployment, so passing it as -ConnectionBroker will point the
# role cmdlets at a non-existent deployment. The deployment probe below handles that case by
# skipping the deployment-level roles. Only set this to a REAL Connection Broker FQDN.
$RDS_Connection_Broker_FQDN = if (-not [string]::IsNullOrWhiteSpace($ARGUMENT_1)) { $ARGUMENT_1 } else { "" }

# ---- Active-broker resolution (HA management-role failover safety net) -------------
# The RDS deployment cmdlets only work against the broker that currently holds the RD
# Management Server role. Normally that is THIS host, so no configuration is needed. If the
# role has failed over to another broker, the script probes the entries below and targets
# whichever broker currently answers - so certificate deployment keeps working after a failover.
#
#   $RDS_Broker_Candidates : explicit broker FQDNs to probe (most reliable). For this
#                            deployment, e.g. @("broker1.domain.com","broker2.domain.com")
#   $RDS_HA_Broker_DNS     : RD Connection Broker cluster (HA) DNS name; resolved and reverse
#                            looked-up as a best-effort source of candidates, e.g. "ha-dns.domain.com"
$RDS_Broker_Candidates = @()
$RDS_HA_Broker_DNS     = ""

# ---- Failure tracking (report the TRUE outcome, not a false success) --------------
$RdsFailures = New-Object System.Collections.Generic.List[string]

function Add-RdsFailure {
    param([string]$Message)
    $RdsFailures.Add($Message)
    Write-LogMessage "FAILURE: $Message"
}

# Resolved broker splat for the RD cmdlets, populated by Resolve-ActiveBroker below.
# Until resolution runs it is $null and Get-RDCommonParams falls back to the configured FQDN.
$script:ResolvedBrokerParams = $null

function Get-RDCommonParams {
    if ($null -ne $script:ResolvedBrokerParams) { return $script:ResolvedBrokerParams }
    $p = @{}
    if (-not [string]::IsNullOrWhiteSpace($RDS_Connection_Broker_FQDN)) {
        $p['ConnectionBroker'] = $RDS_Connection_Broker_FQDN
    }
    return $p
}

# Returns $true if the RD management endpoint answers for the given broker (empty = local host).
# In HA only the broker currently holding the RD Management Server role responds.
function Test-BrokerReachable {
    param([string]$BrokerFqdn)
    try {
        if ([string]::IsNullOrWhiteSpace($BrokerFqdn)) {
            Get-RDServer -ErrorAction Stop | Out-Null
        } else {
            Get-RDServer -ConnectionBroker $BrokerFqdn -ErrorAction Stop | Out-Null
        }
        return $true
    } catch {
        return $false
    }
}

# Best-effort list of candidate broker FQDNs to probe during a management-role failover.
function Get-BrokerCandidateList {
    $list = New-Object System.Collections.Generic.List[string]

    # Explicit candidate FQDNs (most reliable)
    foreach ($c in $RDS_Broker_Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c)) { [void]$list.Add($c.Trim()) }
    }

    # HA cluster DNS name -> A records -> reverse DNS to hostnames (best effort)
    if (-not [string]::IsNullOrWhiteSpace($RDS_HA_Broker_DNS)) {
        try {
            foreach ($addr in [System.Net.Dns]::GetHostAddresses($RDS_HA_Broker_DNS)) {
                try {
                    $name = ([System.Net.Dns]::GetHostEntry($addr.IPAddressToString)).HostName
                    if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$list.Add($name) }
                } catch { }
            }
        } catch {
            Write-LogMessage "Broker discovery: could not resolve HA DNS name '$RDS_HA_Broker_DNS' ($($_.Exception.Message))"
        }
    }

    return ($list | Select-Object -Unique)
}

# Resolves which broker currently holds the RD Management Server role and stores the splat in
# $script:ResolvedBrokerParams (@{} for the local host, or @{ConnectionBroker=<fqdn>}). This makes
# the script resilient to an HA management-role failover: if the local node is no longer the
# management server, it targets whichever broker currently answers. Returns $true on success.
function Resolve-ActiveBroker {
    # 1) Operator-specified broker (config value or AWR Parameter 1) wins if it answers.
    if (-not [string]::IsNullOrWhiteSpace($RDS_Connection_Broker_FQDN)) {
        if (Test-BrokerReachable -BrokerFqdn $RDS_Connection_Broker_FQDN) {
            Write-LogMessage "Active RD Management Server: $RDS_Connection_Broker_FQDN (from configuration/argument)"
            $script:ResolvedBrokerParams = @{ ConnectionBroker = $RDS_Connection_Broker_FQDN }
            return $true
        }
        Write-LogMessage "Configured broker '$RDS_Connection_Broker_FQDN' did not answer as the active management server; trying local host and discovery."
    }

    # 2) Local host is the active management server (the normal case).
    if (Test-BrokerReachable) {
        Write-LogMessage "Active RD Management Server: local host"
        $script:ResolvedBrokerParams = @{}
        return $true
    }

    Write-LogMessage "Local host is not the active RD Management Server - locating the active broker (possible management-role failover)..."

    # 3) Probe discovered candidates and target the one that answers.
    foreach ($cand in (Get-BrokerCandidateList)) {
        if (Test-BrokerReachable -BrokerFqdn $cand) {
            Write-LogMessage "Active RD Management Server: $cand (discovered)"
            $script:ResolvedBrokerParams = @{ ConnectionBroker = $cand }
            return $true
        }
        Write-LogMessage "Broker candidate '$cand' is not the active management server."
    }

    Write-LogMessage "Could not resolve an active RD Management Server (local host and all candidates were unreachable)."
    $script:ResolvedBrokerParams = $null
    return $false
}

# Detects whether an actual RDS deployment exists on the (local or specified) Connection Broker.
# Get-RDCertificate uses the same deployment/broker code path as Set-RDCertificate, so it is a
# faithful predictor: if it throws "a deployment does not exist", the role cmdlets will too.
# Returns $true only when a configurable deployment is present.
function Test-RDSDeployment {
    param([hashtable]$Common)
    try {
        Get-RDCertificate @Common -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-LogMessage "RDS deployment probe: no configurable deployment found ($($_.Exception.Message))"
        return $false
    }
}

# Sets and verifies an RDS role certificate. A missing role server or missing deployment is treated
# as a skip-with-note (a configuration reality, not a delivery failure). Any other error is recorded
# as a failure so the overall run is marked failed, while remaining roles are still attempted.
function Set-RDSRoleCertificate {
    param([string]$Role, [string]$Thumbprint)

    if (-not (Get-Module -Name RemoteDesktop)) {
        Add-RdsFailure "$Role : RemoteDesktop module not available - cannot configure this role."
        return
    }

    $common = Get-RDCommonParams
    try {
        # Set-RDCertificate imports the PFX into the deployment and distributes it to the role
        # servers. It takes the certificate via -ImportPath/-Password (there is NO -Thumbprint
        # parameter); the cert is already in LocalMachine\My for the local RDP listener above.
        $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
        Set-RDCertificate -Role $Role -ImportPath $PFX_FILE_PATH -Password $securePwd -Force -ErrorAction Stop @common
        Write-LogMessage "Set-RDCertificate succeeded for role $Role"
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'does not contain|does not exist') {
            # Deployment lacks this specific role server, or there is no deployment at all.
            # Not a certificate-delivery failure - note and skip so a standalone/partial
            # deployment does not report a false failure to TLM.
            Write-LogMessage "NOTE: $Role is not part of this deployment - skipping. ($msg)"
        } else {
            Add-RdsFailure "$Role : Set-RDCertificate failed. $msg"
        }
        return
    }

    try {
        $applied = Get-RDCertificate -Role $Role -ErrorAction Stop @common
        if ($applied.Thumbprint -eq $Thumbprint) {
            Write-LogMessage "Verified $Role certificate is correctly applied"
        } else {
            Add-RdsFailure "$Role : verification mismatch - expected $Thumbprint but deployment reports '$($applied.Thumbprint)'."
        }
    } catch {
        Add-RdsFailure "$Role : Get-RDCertificate verification failed. $_"
    }
}

# ---- Preconditions ---------------------------------------------------------------
# Do NOT gate on Get-RDServer. In an HA deployment only the active RD Management Server
# answers Get-RDServer, and the management role can fail over between brokers - so a healthy
# broker/web/session host would be wrongly labelled "not an RDS server" and skipped (a false
# success). The certificate import + RDP-Tcp listener are LOCAL operations that must run here
# regardless; the deployment-level roles are gated separately by the deployment probe below.
if ([string]::IsNullOrEmpty($PFX_FILE_PATH) -or -not (Test-Path $PFX_FILE_PATH)) {
    Add-RdsFailure "PFX file not found at '$PFX_FILE_PATH' - cannot configure RDS."
}
elseif ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Add-RdsFailure "No PFX password available - cannot import certificate."
}
else {
    # ---- Import the certificate into LocalMachine\My ------------------------------
    $thumbprint = $null
    try {
        $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
        $cert = Import-PfxCertificate -FilePath $PFX_FILE_PATH `
                    -CertStoreLocation "Cert:\LocalMachine\My" `
                    -Password $securePwd -ErrorAction Stop
        $thumbprint = $cert.Thumbprint
        Write-LogMessage "Certificate imported to LocalMachine\My. Thumbprint: $thumbprint"

        $thumbprintFile = Join-Path -Path $CERT_FOLDER -ChildPath "certificate_thumbprint.txt"
        $thumbprint | Out-File -FilePath $thumbprintFile -Force
        Write-LogMessage "Saved thumbprint to: $thumbprintFile"
    } catch {
        Add-RdsFailure "Failed to import certificate into LocalMachine\My. $_"
    }

    if ($thumbprint) {
        # ---- Grant private-key access via certutil repairstore --------------------
        Write-LogMessage "Repairing certificate store for thumbprint: $thumbprint"
        try {
            $repair = Start-Process cmd.exe -ArgumentList "/c certutil -repairstore my $thumbprint" -Wait -NoNewWindow -PassThru
            if ($repair.ExitCode -ne 0) {
                Add-RdsFailure "certutil -repairstore returned exit code $($repair.ExitCode)."
            } else {
                Write-LogMessage "certutil repair command completed"
            }
        } catch {
            Add-RdsFailure "certutil -repairstore could not be launched. $_"
        }

        # ---- RDP listener certificate (local, via WMI) ----------------------------
        # This is the applicable configuration for a standalone RD Session Host and does
        # NOT require an RDS deployment.
        if ($Install_RDP_Listener_Certificate) {
            Write-LogMessage "Configuring RDP listener certificate"
            try {
                $tsConfig = Get-WmiObject -Namespace "Root\CIMv2\TerminalServices" -Class Win32_TSGeneralSetting -Filter "TerminalName='RDP-Tcp'" -ErrorAction Stop
                if ($tsConfig) {
                    $tsConfig.PSBase.Properties["SSLCertificateSHA1Hash"].Value = $thumbprint
                    $tsConfig.Put() | Out-Null
                    Write-LogMessage "Updated RDP listener certificate thumbprint via WMI"
                    try {
                        Restart-Service -Name "TermService" -Force -ErrorAction Stop
                        Write-LogMessage "Restarted Terminal Services (TermService)"
                    } catch {
                        Add-RdsFailure "RDP listener : failed to restart TermService. $_"
                    }
                } else {
                    Add-RdsFailure "RDP listener : could not retrieve the RDP-Tcp TS configuration."
                }
            } catch {
                Add-RdsFailure "RDP listener : failed to set certificate thumbprint via WMI. $_"
            }
        } else {
            Write-LogMessage "Install_RDP_Listener_Certificate is false - skipping RDP listener configuration"
        }

        # ---- RDS deployment-level role certificates -------------------------------
        # Publishing / Web Access / SSO(Redirector) exist ONLY inside a Connection
        # Broker-based deployment (New-RDSessionDeployment / Server Manager wizard).
        # Detect the deployment first and skip these steps gracefully if none exists,
        # so a standalone RDSH does not report a false failure to TLM.
        $needRdsRoles = $Install_RDS_Publishing_Certificate -or $Install_RDS_WebAccess_Certificate -or $Install_RDS_SSO_Certificate

        # Tracks whether the local host is the active RD Management Server; populated after
        # importing the RemoteDesktop module so Get-RDServer is available.
        $localHostIsActiveMgmtServer = $false

        if ($needRdsRoles) {
            try {
                Import-Module RemoteDesktop -ErrorAction Stop
                Write-LogMessage "Successfully imported RemoteDesktop module"
                # Probe the local host BEFORE Resolve-ActiveBroker so we know whether this host
                # owns the RD Management Server role independently of any configured FQDN.
                $localHostIsActiveMgmtServer = Test-BrokerReachable
                Write-LogMessage "Local host is active RD Management Server: $localHostIsActiveMgmtServer"
            } catch {
                Add-RdsFailure "RemoteDesktop module could not be imported - RDS roles cannot be configured. $_"
                $needRdsRoles = $false
            }
        }

        $deploymentExists = $false
        if ($needRdsRoles) {
            # Resolve the broker that currently holds the RD Management Server role (handles HA
            # management-role failover) before probing the deployment.
            $brokerResolved = Resolve-ActiveBroker
            if ($brokerResolved) {
                $commonProbe = Get-RDCommonParams
                $deploymentExists = Test-RDSDeployment -Common $commonProbe
                if ($deploymentExists) {
                    Write-LogMessage "RDS deployment detected - proceeding with deployment-level role certificates"
                } else {
                    Write-LogMessage "NOTE: No RDS deployment present on the target Connection Broker. Publishing / Web Access / SSO roles require a deployment created via New-RDSessionDeployment or the Server Manager wizard. Skipping these role steps."
                    Write-LogMessage "NOTE: On a standalone RD Session Host the RDP listener certificate above is the applicable configuration; this is a successful outcome."
                }
            } else {
                Write-LogMessage "NOTE: No active RD Connection Broker (management server) could be reached from this host or the configured candidates. Skipping the deployment-level role certificates. If the RD Management Server role has failed over, set `$RDS_Connection_Broker_FQDN / AWR Parameter 1, or list the brokers in `$RDS_Broker_Candidates / `$RDS_HA_Broker_DNS."
            }
        }

        if ($deploymentExists) {
            # In an HA deployment with a single Agent Job covering both Connection Brokers, both
            # hosts run Set-RDCertificate -ImportPath.  Set-RDCertificate always imports the PFX
            # into the target broker's LocalMachine\My store, so the passive broker's call (routed
            # to the active broker via -ConnectionBroker) causes a second copy of the same cert to
            # land in the active broker's store on top of the one already imported by
            # Import-PfxCertificate and the active broker's own Set-RDCertificate call.
            #
            # Guard: only the host that currently holds the RD Management Server role calls
            # Set-RDCertificate.  The passive broker skips these steps; the active broker applies
            # all deployment-level role certificates through its own job execution.
            #
            # Exception: if the operator explicitly configured $RDS_Connection_Broker_FQDN /
            # AWR Parameter 1 (intentional remote-delegation from a non-broker host such as an
            # RD Session Host or RD Web Access server), honour that intent and run Set-RDCertificate
            # even though the local host is not the active management server.
            $passiveBrokerSkip = (-not $localHostIsActiveMgmtServer) -and [string]::IsNullOrWhiteSpace($RDS_Connection_Broker_FQDN)

            if ($passiveBrokerSkip) {
                Write-LogMessage "NOTE: This host is not the active RD Management Server and no explicit Connection Broker FQDN is configured. Skipping Set-RDCertificate for deployment-level roles (Publishing / Web Access / SSO) on this passive broker to prevent duplicate certificate imports into the active broker's LocalMachine\My store. The active broker applies these roles via its own execution of this script."
            } else {
                if ($Install_RDS_Publishing_Certificate) {
                    Write-LogMessage "Configuring RD Publishing certificate"
                    Set-RDSRoleCertificate -Role "RDPublishing" -Thumbprint $thumbprint
                } else {
                    Write-LogMessage "Install_RDS_Publishing_Certificate is false - skipping"
                }

                if ($Install_RDS_WebAccess_Certificate) {
                    Write-LogMessage "Configuring RD Web Access certificate"
                    Set-RDSRoleCertificate -Role "RDWebAccess" -Thumbprint $thumbprint
                    Write-LogMessage "Note: you may also need to update the IIS HTTPS binding for the RD Web Access site"
                } else {
                    Write-LogMessage "Install_RDS_WebAccess_Certificate is false - skipping"
                }

                if ($Install_RDS_SSO_Certificate) {
                    Write-LogMessage "Configuring RD SSO (Redirector) certificate"
                    Set-RDSRoleCertificate -Role "RDRedirector" -Thumbprint $thumbprint
                } else {
                    Write-LogMessage "Install_RDS_SSO_Certificate is false - skipping"
                }
            }
        }
    }
}

Write-LogMessage "Custom script section completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
if ($RdsFailures -and $RdsFailures.Count -gt 0) {
    Write-LogMessage "Script execution completed with $($RdsFailures.Count) failure(s):"
    foreach ($f in $RdsFailures) { Write-LogMessage "  - $f" }
    Write-LogMessage "=========================================="
    exit 1
}

Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

exit 0