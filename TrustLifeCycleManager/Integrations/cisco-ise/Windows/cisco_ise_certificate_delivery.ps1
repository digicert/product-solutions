<#
.SYNOPSIS
    Import a PEM certificate and private key into Cisco ISE system certificates, bound
    to the correct service(s) and Portal Group Tag.
.DESCRIPTION
    Reads AWR `DC1_POST_SCRIPT_DATA`, extracts the certificate payload and the Post-Script
    Arguments configured for this script in the CLM/TLM UI, then imports the certificate
    into each configured ISE node via the ISE OpenAPI (/api/v1/certs/system-certificate/import),
    setting whichever of admin / eap / ims / pxgrid / radius / saml / portal apply, and the
    Portal Group Tag when "portal" is set.

    ISE nodes, API credentials, portal tag, and service flags all come from the CLM UI's
    Post-Script Parameters for this script (up to 15 supported there) - no separate config
    file. See ARGUMENT_1-5 below for what each parameter field maps to.
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
	subparagraphs (c)(1) and (2) of the Commercial Computer Software-Restricted Rights at 48 CFR 52.227-19,
	as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
	The contractor/manufacturer is DIGICERT, INC.
#>

# =====================================================================
# GLOBALS
# =====================================================================
$LEGAL_NOTICE_ACCEPT   = "false"
$LOG_PATH              = "C:\Program Files\DigiCert\TLM Agent\log\cisco_ise_cert_deploy_debug.log"
$API_CALLS_LOG_PATH    = "C:\Program Files\DigiCert\TLM Agent\log\cisco_ise_cert_deploy_api_calls.log"
$SCRIPT_VERSION        = "2.1.0"

# Make sure the log directory exists before anything tries to write to it - TLM Agent
# normally creates this folder itself, but this is a cheap safety net either way.
$logDir = Split-Path -Path $LOG_PATH -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

# =====================================================================
# CONFIGURATION
# =====================================================================
# Admin Web Request arguments mapping (from the CLM UI's Post-Script Parameters for
# this script - matches the "Parameters" list shown under Run post-delivery scripts):
#   ARGUMENT_1: ISE node (hostname/IP) - comma-separate if pushing to more than one node
#   ARGUMENT_2: ISE API account name
#   ARGUMENT_3: ISE API account password
#   ARGUMENT_4: Portal Group Tag (required only if ARGUMENT_5 includes "portal")
#   ARGUMENT_5: Comma-separated service flags to set true - any of:
#               admin, eap, ims, pxgrid, radius, saml, portal
#               Omit (leave at 4 parameters, as in the current CLM setup) to default to
#               "portal" only, matching ISE's own default UI behavior. Add a 5th parameter
#               in the CLM UI ("Add parameter") whenever a cert needs RADIUS/EAP/pxGrid/etc.
#               instead of - or in addition to - Portal.
#
# Quick reference - what to type, by scenario:
#   Portal only (default, 4 parameters, no ARGUMENT_5):
#       ARGUMENT_4 = Default Portal Certificate Group      ARGUMENT_5 = (do not add)
#   RADIUS DTLS only (no portal involved):
#       ARGUMENT_4 = (leave blank / do not add)            ARGUMENT_5 = radius
#   EAP only:
#       ARGUMENT_4 = (leave blank)                         ARGUMENT_5 = eap
#   pxGrid only:
#       ARGUMENT_4 = (leave blank)                         ARGUMENT_5 = pxgrid
#   Admin + Portal + EAP together (e.g. "Default Portal Certificate Group" bound to all three):
#       ARGUMENT_4 = Default Portal Certificate Group      ARGUMENT_5 = admin,portal,eap
#
# The only two things to remember:
#   1. No ARGUMENT_5 at all -> script assumes "portal" only, and ARGUMENT_4 is required.
#   2. ARGUMENT_5 present -> it decides everything, and ARGUMENT_4 is only required if
#      "portal" is one of the values typed into it.

# ── TLS validation for the ISE API calls ────────────────────────────────────────
# Default behavior below is standard .NET certificate validation - i.e. NO bypass.
# That will fail against ISE nodes using the self-signed "Default self-signed server
# certificate" shown in a fresh lab build, which is expected: either (a) get the ISE
# Admin certificate signed by a CA this host already trusts (the real fix for anything
# beyond a throwaway lab), or (b) pin certificates below.
#
# TWO KINDS OF PINS - use the right one for the job:
#   PinnedNodeThumbprints   - pins one exact LEAF certificate. Stops matching the
#                             moment that cert is replaced (i.e. every rotation).
#                             Only useful for a one-off manual test/unblock.
#   PinnedIssuerThumbprints - pins the ISSUING CA certificate. Any leaf certificate
#                             issued by that CA is trusted, so this survives every
#                             future rotation automatically - this is what unattended
#                             automation should run on. Only needs updating again if
#                             the Issuing CA itself is ever replaced (rare, planned).
# Get an issuing CA's thumbprint on the Windows host with:
#   Get-ChildItem Cert:\LocalMachine\CA | Select Subject, Thumbprint
#
# Only use $AllowInsecureTlsBypass for quick, temporary lab testing - it disables ALL
# validation for these calls, including hostname and trust checks, and every use is
# logged loudly since this call transmits API credentials and the new cert's private key.
$PinnedNodeThumbprints   = @()
$PinnedIssuerThumbprints = @()
$AllowInsecureTlsBypass  = $false

# =====================================================================
# LOGGING
# =====================================================================
$Banner = "=========================================="

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")][string]$Level = "INFO",
        [switch]$ApiCall
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    if ($Level -ne "DEBUG") {
        Write-Host $line
    }

    $targetPath = if ($ApiCall) { $API_CALLS_LOG_PATH } else { $LOG_PATH }
    if ([string]::IsNullOrWhiteSpace($targetPath)) {
        return
    }

    try {
        Add-Content -Path $targetPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging failures must not block certificate operations.
    }
}

function Test-RequiredPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -Path $Path)) {
        throw "$Label path not found: $Path"
    }
}

# =====================================================================
# POST-SCRIPT DATA / ARGUMENTS
# =====================================================================
function Get-PostScriptDataObject {
    $encoded = $env:DC1_POST_SCRIPT_DATA
    if ([string]::IsNullOrWhiteSpace($encoded)) {
        throw "DC1_POST_SCRIPT_DATA environment variable is not set"
    }
    Write-Log -Message "DC1_POST_SCRIPT_DATA is set (length: $($encoded.Length) characters)"

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
        Write-Log -Message "JSON decoded successfully (length: $($json.Length) characters)"
        $jsonObject = $json | ConvertFrom-Json
        Write-Log -Message "JSON parsed successfully"

        $jsonForLog = $jsonObject | Select-Object *
        if ($jsonForLog.PSObject.Properties.Name -contains 'password' -and $jsonForLog.password) {
            $jsonForLog.password = "********"
        }
        if ($jsonForLog.PSObject.Properties.Name -contains 'args' -and $jsonForLog.args) {
            # Select-Object copies the object shallowly - $jsonForLog.args is still the SAME
            # array reference as $jsonObject.args. Clone it before masking so this logging
            # step can't corrupt the real credentials Resolve-ArgumentsFromJson reads later.
            $maskedArgs = @($jsonForLog.args | ForEach-Object { $_ })
            if ($maskedArgs.Count -ge 3) {
                $maskedArgs[2] = "********"   # ARGUMENT_3: ISE API account password
            }
            $jsonForLog.args = $maskedArgs
        }
        Write-Log -Message $Banner
        Write-Log -Message "Raw JSON content (credentials obfuscated):"
        Write-Log -Message ($jsonForLog | ConvertTo-Json -Compress)
        Write-Log -Message $Banner

        return $jsonObject
    } catch {
        throw "Failed to decode or parse DC1_POST_SCRIPT_DATA: $($_.Exception.Message)"
    }
}

function Resolve-ArgumentsFromJson {
    param([Parameter(Mandatory = $true)][pscustomobject]$JsonObject)

    $apiArgs = @('', '', '', '', '')
    if ($JsonObject.args) {
        for ($i = 0; $i -lt [Math]::Min($JsonObject.args.Count, 5); $i++) {
            $apiArgs[$i] = ([string]$JsonObject.args[$i]).Trim()
        }
    }

    $iseNodes = @()
    if (-not [string]::IsNullOrWhiteSpace($apiArgs[0])) {
        $iseNodes = $apiArgs[0].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    $serviceFlags = @('portal')
    if (-not [string]::IsNullOrWhiteSpace($apiArgs[4])) {
        $serviceFlags = $apiArgs[4].Split(',') | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    }

    return @{
        IseNodes        = @($iseNodes)
        AccountName     = $apiArgs[1]
        AccountPassword = $apiArgs[2]
        PortalTag       = $apiArgs[3]
        ServiceFlags    = @($serviceFlags)
    }
}

function Resolve-DeploymentTarget {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ClmArguments
    )

    $target = @{
        IseNodes        = $ClmArguments.IseNodes
        AccountName     = $ClmArguments.AccountName
        AccountPassword = $ClmArguments.AccountPassword
        PortalTag       = $ClmArguments.PortalTag
        ServiceFlags    = $ClmArguments.ServiceFlags
    }

    if ($target.IseNodes.Count -eq 0) {
        throw "No ISE nodes resolved. Set ARGUMENT_1 (ISE node hostname/IP) in the CLM post-script Parameters."
    }
    if ([string]::IsNullOrWhiteSpace($target.AccountName)) {
        throw "No ISE API account name resolved. Set ARGUMENT_2 in the CLM post-script Parameters."
    }
    if ([string]::IsNullOrWhiteSpace($target.AccountPassword)) {
        throw "No ISE API account password resolved. Set ARGUMENT_3 in the CLM post-script Parameters."
    }
    if (($target.ServiceFlags -contains 'portal') -and [string]::IsNullOrWhiteSpace($target.PortalTag)) {
        throw "Service flags include 'portal' but no Portal Group Tag was resolved. Set ARGUMENT_4 in the CLM post-script Parameters."
    }

    Write-Log -Message $Banner
    Write-Log -Message "DEPLOYMENT TARGET:"
    Write-Log -Message $Banner
    Write-Log -Message "  ISE Nodes      : $($target.IseNodes -join ', ')"
    Write-Log -Message "  API Account    : $($target.AccountName)"
    Write-Log -Message "  Portal Tag     : $(if ($target.PortalTag) { $target.PortalTag } else { '(not set - not needed unless portal flag is on)' })"
    Write-Log -Message "  Service Flags  : $($target.ServiceFlags -join ', ')"
    Write-Log -Message $Banner

    return $target
}

# =====================================================================
# CERTIFICATE / PEM HANDLING
# =====================================================================
function Resolve-CertificateFilePath {
    param([Parameter(Mandatory = $true)][pscustomobject]$JsonObject)

    $certFolder = [string]$JsonObject.certfolder
    $pemFile = $null

    if ($JsonObject.files) {
        $pemFile = $JsonObject.files | Where-Object { $_ -match '\.pem$' } | Select-Object -First 1
    }

    if ([string]::IsNullOrWhiteSpace($certFolder)) { throw "certfolder is missing" }
    if ([string]::IsNullOrWhiteSpace([string]$pemFile)) { throw "No .pem file found in POST_SCRIPT_DATA files[]" }

    Test-RequiredPath -Path $certFolder -Label "Certificate folder"

    $pemPath = Join-Path -Path $certFolder -ChildPath $pemFile
    Test-RequiredPath -Path $pemPath -Label "PEM file"

    Write-Log -Message $Banner
    Write-Log -Message "EXTRACTION SUMMARY:"
    Write-Log -Message $Banner
    Write-Log -Message "  Certificate folder : $certFolder"
    Write-Log -Message "  Certificate file   : $pemFile"
    Write-Log -Message "  Certificate path   : $pemPath"
    Write-Log -Message "  File size          : $((Get-Item -Path $pemPath).Length) bytes"
    Write-Log -Message $Banner

    return $pemPath
}

function Get-PemContents {
    param([Parameter(Mandatory = $true)][string]$PemPath)

    $rawPem = Get-Content -Path $PemPath -Raw

    # DigiCert only encrypts the private key when a PFX/export password is set on the
    # certificate profile. If that field is left blank, the key ships as a plain PKCS#8
    # "PRIVATE KEY" block, not "ENCRYPTED PRIVATE KEY" - match both so a blank password
    # doesn't make the script throw on an otherwise valid delivery.
    $privateKeyMatch = [regex]::Match(
        $rawPem,
        '-----BEGIN ((?:ENCRYPTED )?PRIVATE KEY)-----.*?-----END \1-----',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $privateKeyMatch.Success) {
        throw "No PKCS#8 private key block ('PRIVATE KEY' or 'ENCRYPTED PRIVATE KEY') found in PEM file."
    }
    $isEncrypted = $privateKeyMatch.Groups[1].Value -like "ENCRYPTED*"
    Write-Log -Message "Private key format: $(if ($isEncrypted) { 'PKCS#8 ENCRYPTED PRIVATE KEY' } else { 'PKCS#8 PRIVATE KEY (unencrypted)' })"

    $certificateMatch = [regex]::Match(
        $rawPem,
        '-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $certificateMatch.Success) {
        throw "Certificate block not found in PEM file"
    }

    return @{
        PrivateKeyData  = $privateKeyMatch.Value
        CertificateData = $certificateMatch.Value
        IsEncrypted     = $isEncrypted
    }
}

function Get-X509FromPemBlock {
    param([Parameter(Mandatory = $true)][string]$PemCertificateBlock)

    $base64 = ($PemCertificateBlock -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', '' -replace '\s', '')
    $bytes = [System.Convert]::FromBase64String($base64)
    return New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(, $bytes)
}

function Write-NewCertificateDetails {
    param([Parameter(Mandatory = $true)]$X509)

    $sanExtension = $X509.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }
    $sanNames = @()
    if ($sanExtension) {
        $sanNames = $sanExtension.Format($false) -split "," | ForEach-Object { ($_ -replace "^DNS Name=", "").Trim() } | Where-Object { $_ }
    }

    Write-Log -Message $Banner
    Write-Log -Message "NEW CERTIFICATE (from PEM):"
    Write-Log -Message $Banner
    Write-Log -Message "  Subject           : $($X509.Subject)"
    Write-Log -Message "  Issuer            : $($X509.Issuer)"
    Write-Log -Message "  Serial Number     : $($X509.SerialNumber)"
    Write-Log -Message "  Thumbprint (SHA1) : $($X509.Thumbprint)"
    Write-Log -Message "  Not Before        : $($X509.NotBefore)"
    Write-Log -Message "  Not After         : $($X509.NotAfter)"
    Write-Log -Message "  Subject Alt Names : $($sanNames -join ', ')"
    Write-Log -Message $Banner
}

# =====================================================================
# ISE REQUEST BODY
# =====================================================================
function New-IseRequestBody {
    param(
        [Parameter(Mandatory = $true)][string]$CertificateName,
        [Parameter(Mandatory = $true)][string[]]$ServiceFlags,
        [string]$PortalTag,
        [Parameter(Mandatory = $true)][string]$CertificateData,
        [Parameter(Mandatory = $true)][string]$PrivateKeyData,
        [string]$KeyPassword
    )

    $validFlags = @('admin', 'eap', 'ims', 'pxgrid', 'radius', 'saml', 'portal')
    $flagState = @{}
    foreach ($f in $validFlags) { $flagState[$f] = $false }
    foreach ($requested in $ServiceFlags) {
        if ($validFlags -contains $requested) {
            $flagState[$requested] = $true
        } else {
            Write-Log -Message "Ignoring unrecognized service flag '$requested'. Valid flags: $($validFlags -join ', ')" -Level "WARN"
        }
    }

    $appliedFlags = ($flagState.GetEnumerator() | Where-Object { $_.Value } | ForEach-Object { $_.Key }) -join ', '
    Write-Log -Message "Service flags to apply: $appliedFlags"

    $bodyObject = [ordered]@{
        name                                  = $CertificateName
        admin                                 = $flagState['admin']
        eap                                   = $flagState['eap']
        ims                                   = $flagState['ims']
        pxgrid                                = $flagState['pxgrid']
        radius                                = $flagState['radius']
        saml                                  = $flagState['saml']
        portal                                = $flagState['portal']
        data                                  = $CertificateData
        privateKeyData                        = $PrivateKeyData
        password                              = $KeyPassword
        allowExtendedValidity                 = $true
        allowOutOfDateCert                    = $true
        allowPortalTagTransferForSameSubject  = $true
        allowReplacementOfCertificates        = $true
        allowReplacementOfPortalGroupTag      = $true
        allowRoleTransferForSameSubject       = $true
        allowSHA1Certificates                 = $true
        allowWildCardCertificates             = $false
        validateCertificateExtensions         = $false
    }

    if ($flagState['portal']) {
        $bodyObject.portalGroupTag = $PortalTag
    }

    return ($bodyObject | ConvertTo-Json -Depth 5)
}

# =====================================================================
# TLS VALIDATION (secure-by-default, with optional pinning / opt-in bypass)
# =====================================================================
if (-not ("IseCertificateValidator" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;

public static class IseCertificateValidator
{
    public static readonly RemoteCertificateValidationCallback Callback = Validate;
    private static readonly HashSet<string> PinnedThumbprints = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    private static readonly HashSet<string> PinnedIssuerThumbprints = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    public static bool AllowInsecureBypass = false;
    public static string LastResult = "";

    public static void AddPinnedThumbprint(string thumbprint)
    {
        string normalized = Normalize(thumbprint);
        if (normalized.Length > 0)
        {
            PinnedThumbprints.Add(normalized);
        }
    }

    public static void AddPinnedIssuerThumbprint(string thumbprint)
    {
        string normalized = Normalize(thumbprint);
        if (normalized.Length > 0)
        {
            PinnedIssuerThumbprints.Add(normalized);
        }
    }

    private static string Normalize(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        return value.Replace(":", "").Replace(" ", "").Replace("-", "").ToUpperInvariant();
    }

    private static bool Validate(
        object sender,
        X509Certificate certificate,
        X509Chain chain,
        SslPolicyErrors sslPolicyErrors)
    {
        if (sslPolicyErrors == SslPolicyErrors.None)
        {
            LastResult = "TRUSTED (standard chain validation passed)";
            return true;
        }

        string thumbprint = certificate != null ? Normalize(certificate.GetCertHashString()) : "";

        string chainDetail = "";
        if (chain != null && chain.ChainStatus != null && chain.ChainStatus.Length > 0)
        {
            List<string> statusParts = new List<string>();
            foreach (var status in chain.ChainStatus)
            {
                statusParts.Add(status.Status.ToString() + ": " + status.StatusInformation.Trim());
            }
            chainDetail = " | ChainStatus: " + string.Join("; ", statusParts.ToArray());
        }

        // Issuer-CA pinning: survives every future leaf rotation automatically.
        // Deliberately scoped to ChainErrors ONLY - never bypasses a hostname
        // mismatch (RemoteCertificateNameMismatch), so a cert for the wrong
        // node still gets rejected even if it happens to chain to a pinned CA.
        if (sslPolicyErrors == SslPolicyErrors.RemoteCertificateChainErrors
            && chain != null && chain.ChainElements != null && PinnedIssuerThumbprints.Count > 0)
        {
            foreach (X509ChainElement element in chain.ChainElements)
            {
                string elementThumbprint = Normalize(element.Certificate.Thumbprint);
                if (PinnedIssuerThumbprints.Contains(elementThumbprint))
                {
                    LastResult = "TRUSTED_VIA_ISSUER_PIN (leaf " + thumbprint + " chains to pinned issuing CA " + elementThumbprint + "; standard check failed with: " + sslPolicyErrors.ToString() + ")" + chainDetail;
                    return true;
                }
            }
        }

        if (thumbprint.Length > 0 && PinnedThumbprints.Contains(thumbprint))
        {
            LastResult = "PINNED (" + sslPolicyErrors.ToString() + " - untrusted by standard checks, but presented thumbprint " + thumbprint + " matches an approved node certificate)" + chainDetail;
            return true;
        }

        if (AllowInsecureBypass)
        {
            LastResult = "INSECURE_BYPASS (validation disabled - underlying error(s): " + sslPolicyErrors.ToString() + ")" + chainDetail;
            return true;
        }

        LastResult = "REJECTED: " + sslPolicyErrors.ToString() + " (thumbprint " + thumbprint + " not pinned and insecure bypass is disabled)" + chainDetail;
        return false;
    }
}
"@
}

function Initialize-IseTlsValidator {
    [IseCertificateValidator]::AllowInsecureBypass = $AllowInsecureTlsBypass
    foreach ($tp in $PinnedNodeThumbprints) {
        [IseCertificateValidator]::AddPinnedThumbprint($tp)
    }
    foreach ($tp in $PinnedIssuerThumbprints) {
        [IseCertificateValidator]::AddPinnedIssuerThumbprint($tp)
    }
    if ($AllowInsecureTlsBypass) {
        Write-Log -Message "SECURITY WARNING: AllowInsecureTlsBypass is TRUE. TLS certificate validation is disabled for ISE API calls in this run - use only for temporary lab testing." -Level "WARN"
    } elseif ($PinnedIssuerThumbprints.Count -gt 0 -or $PinnedNodeThumbprints.Count -gt 0) {
        Write-Log -Message "TLS validation: standard trust checks, plus $($PinnedIssuerThumbprints.Count) pinned issuer CA thumbprint(s) (survives leaf rotation) and $($PinnedNodeThumbprints.Count) pinned leaf thumbprint(s) as fallbacks for untrusted chains."
    } else {
        Write-Log -Message "TLS validation: standard .NET trust checks only (no pinning, no bypass)."
    }
}

function New-IseBasicAuthHeader {
    param(
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $pair = "{0}:{1}" -f $Username, $Password
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pair)
    return "Basic " + [System.Convert]::ToBase64String($bytes)
}

# =====================================================================
# ISE API CALLS
# =====================================================================
function Get-IseNodeCertificates {
    # Best-effort lookup of what's already on the node, purely for the log's OLD-vs-NEW
    # picture. Non-fatal: the ISE OpenAPI path parameter here is the node's own configured
    # hostname (not necessarily the IP/FQDN used to connect), so this can legitimately miss
    # if $Node isn't that exact hostname - that's fine, the import itself doesn't depend on it.
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][hashtable]$Headers
    )

    $uri = "https://$Node/api/v1/certs/system-certificate/$Node"
    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -Headers $Headers -ErrorAction Stop
        return $response.response
    } catch {
        Write-Log -Message "Could not list existing certificates on '$Node' for OLD-cert comparison (non-fatal): $($_.Exception.Message)" -Level "WARN"
        return $null
    }
}

function Import-IseCertificateToNode {
    param(
        [Parameter(Mandatory = $true)][string]$Node,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string]$Body,
        [AllowEmptyString()]
        [string]$PortalTag = ""
    )

    $uri = "https://$Node/api/v1/certs/system-certificate/import"
    $authHeader = New-IseBasicAuthHeader -Username $Credential.UserName -Password $Credential.GetNetworkCredential().Password
    $headers = @{ Accept = "application/json"; Authorization = $authHeader }

    Write-Log -Message "Invoking ISE import API on node '$Node'"
    Write-Log -Message "POST $uri" -Level "DEBUG" -ApiCall

    # Force TLS 1.2, and apply whichever TLS policy is configured above (standard / pinned /
    # insecure bypass). The callback is native .NET code, not a PowerShell script block, so
    # it works in Windows PowerShell 5.1 without requiring a runspace on the TLS thread.
    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    $previousCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [IseCertificateValidator]::Callback

    try {
        if (-not [string]::IsNullOrWhiteSpace($PortalTag)) {
            $existing = Get-IseNodeCertificates -Node $Node -Headers $headers
            if ($existing) {
                $currentForTag = $existing | Where-Object { $_.groupTag -eq $PortalTag -or $_.portalsUsingTheTag -like "*$PortalTag*" }
                if ($currentForTag) {
                    Write-Log -Message "OLD certificate(s) currently using Portal Group Tag '$PortalTag' on '$Node':"
                    foreach ($c in $currentForTag) {
                        Write-Log -Message "  - $($c.friendlyName) | Issued To: $($c.issuedTo) | Expires: $($c.expirationDate) | Used By: $($c.usedBy)"
                    }
                } else {
                    Write-Log -Message "No existing certificate found on '$Node' currently using Portal Group Tag '$PortalTag' (first-time assignment)."
                }
            }
        }

        $request = @{
            Headers     = $headers
            Uri         = $uri
            Method      = "POST"
            Body        = $Body
            ContentType = "application/json"
        }

        $response = Invoke-RestMethod @request
        Write-Log -Message "TLS validation result for this call: $([IseCertificateValidator]::LastResult)" -Level "DEBUG" -ApiCall
        return $response
    } catch {
        Write-Log -Message "TLS validation result for this call: $([IseCertificateValidator]::LastResult)" -Level "DEBUG" -ApiCall
        $errorMsg = $_.Exception.Message

        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
            $statusText = $_.Exception.Response.StatusDescription
            $detailedError = $null
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                try {
                    $detailedError = $reader.ReadToEnd()
                } finally {
                    $reader.Dispose()
                }
            }
            $errorMsg = "ISE API rejected the request. HTTP $statusCode $statusText. ISE Details: $detailedError"
        } elseif ($_.Exception.InnerException) {
            $errorMsg = "$errorMsg Inner exception: $($_.Exception.InnerException.Message)"
        }
        throw $errorMsg
    } finally {
        # Restore the process-wide settings so this policy applies only to this API call.
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCertificateCallback
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
    }
}

function Test-IsValidIseNode {
    param([Parameter(Mandatory = $true)][string]$Node)

    if ([string]::IsNullOrWhiteSpace($Node)) {
        return $false
    }
    if ($Node -like "*ISE NODE*") {
        return $false
    }
    return $true
}

function Invoke-IseImportAcrossNodes {
    param(
        [Parameter(Mandatory = $true)][string[]]$Nodes,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [Parameter(Mandatory = $true)][string]$Body,
        [AllowEmptyString()]
        [string]$PortalTag = ""
    )

    $successfulNodes = @()
    $failedNodes = @()
    $skippedNodes = @()

    foreach ($node in $Nodes) {
        $trimmedNode = ([string]$node).Trim()

        if (-not (Test-IsValidIseNode -Node $trimmedNode)) {
            $skippedNodes += $trimmedNode
            Write-Log -Message "Skipping invalid or placeholder node entry: '$trimmedNode'" -Level "WARN"
            continue
        }

        try {
            $response = Import-IseCertificateToNode -Node $trimmedNode -Credential $Credential -Body $Body -PortalTag $PortalTag
            $status = if ($response -and $response.id) { "Success (id: $($response.id))" } else { "Success" }
            $successfulNodes += $trimmedNode
            Write-Log -Message "Certificate import completed for node '$trimmedNode': $status"
        } catch {
            $failedNodes += $trimmedNode
            Write-Log -Message "Certificate import failed for node '$trimmedNode': $($_.Exception.Message)" -Level "ERROR"
        }
    }

    return @{
        SuccessfulNodes = $successfulNodes
        FailedNodes     = $failedNodes
        SkippedNodes    = $skippedNodes
    }
}

function Write-NodeImportSummary {
    param([Parameter(Mandatory = $true)][hashtable]$Result)

    Write-Log -Message $Banner
    Write-Log -Message "NODE IMPORT SUMMARY:"
    Write-Log -Message $Banner
    Write-Log -Message ("  Success: {0}, Failed: {1}, Skipped: {2}" -f $Result.SuccessfulNodes.Count, $Result.FailedNodes.Count, $Result.SkippedNodes.Count)
    if ($Result.SuccessfulNodes.Count -gt 0) {
        Write-Log -Message ("  Successful nodes: " + ($Result.SuccessfulNodes -join ", "))
    }
    if ($Result.FailedNodes.Count -gt 0) {
        Write-Log -Message ("  Failed nodes: " + ($Result.FailedNodes -join ", ")) -Level "ERROR"
    }
    Write-Log -Message $Banner
}

function Test-ImportResult {
    param([Parameter(Mandatory = $true)][hashtable]$Result)

    if ($Result.SuccessfulNodes.Count -eq 0) {
        throw "No node imports succeeded"
    }
    if ($Result.FailedNodes.Count -gt 0 -or $Result.SkippedNodes.Count -gt 0) {
        throw ("Import did not complete on all nodes. Success: {0}, Failed: {1}, Skipped: {2}" -f $Result.SuccessfulNodes.Count, $Result.FailedNodes.Count, $Result.SkippedNodes.Count)
    }
}

# =====================================================================
# MAIN
# =====================================================================
function Main {
    try {
        Write-Log -Message $Banner
        Write-Log -Message "Cisco ISE Certificate Deployment script started. Version: $SCRIPT_VERSION"
        Write-Log -Message $Banner
        Write-Log -Message "Configuration:"
        Write-Log -Message "  LEGAL_NOTICE_ACCEPT   : $LEGAL_NOTICE_ACCEPT"
        Write-Log -Message "  LOG_PATH              : $LOG_PATH"
        Write-Log -Message "  API_CALLS_LOG_PATH    : $API_CALLS_LOG_PATH"
        Write-Log -Message "  AllowInsecureTlsBypass: $AllowInsecureTlsBypass"
        Write-Log -Message "  PinnedNodeThumbprints : $($PinnedNodeThumbprints.Count) configured"
        Write-Log -Message "  PinnedIssuerThumbprints: $($PinnedIssuerThumbprints.Count) configured"
        Write-Log -Message $Banner

        if ($LEGAL_NOTICE_ACCEPT -ne "true") {
            Write-Log -Message "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=\"true\" to proceed." -Level "ERROR"
            exit 1
        }

        Initialize-IseTlsValidator

        $jsonObject = Get-PostScriptDataObject
        $clmArguments = Resolve-ArgumentsFromJson -JsonObject $jsonObject
        $pemPath = Resolve-CertificateFilePath -JsonObject $jsonObject
        $pemPayload = Get-PemContents -PemPath $pemPath

        $x509 = Get-X509FromPemBlock -PemCertificateBlock $pemPayload.CertificateData
        $commonName = ($x509.Subject -replace "^CN=([^,]+).*", '$1').Trim()
        Write-NewCertificateDetails -X509 $x509

        $target = Resolve-DeploymentTarget -ClmArguments $clmArguments

        $keyPassword = [string]$jsonObject.password
        if ($pemPayload.IsEncrypted -and [string]::IsNullOrWhiteSpace($keyPassword)) {
            throw "Private key is encrypted but no password was found in the certificate order (json.password is blank). Set an export/PFX password on the DigiCert certificate profile, or re-issue without encryption."
        }
        if (-not $pemPayload.IsEncrypted -and -not [string]::IsNullOrWhiteSpace($keyPassword)) {
            Write-Log -Message "A password was supplied but the private key is not encrypted - ignoring password for the ISE API call." -Level "WARN"
            $keyPassword = ""
        }

        $certificateName = "{0}_{1}" -f $commonName, (Get-Date -Format "yyyy-MM-dd_HHmmss")
        $secureApiPassword = ConvertTo-SecureString -String $target.AccountPassword -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($target.AccountName, $secureApiPassword)

        $body = New-IseRequestBody -CertificateName $certificateName -ServiceFlags $target.ServiceFlags -PortalTag $target.PortalTag -CertificateData $pemPayload.CertificateData -PrivateKeyData $pemPayload.PrivateKeyData -KeyPassword $keyPassword

        $result = Invoke-IseImportAcrossNodes -Nodes $target.IseNodes -Credential $credential -Body $body -PortalTag $target.PortalTag
        Write-NodeImportSummary -Result $result
        Test-ImportResult -Result $result

        Write-Log -Message $Banner
        Write-Log -Message "SUMMARY:"
        Write-Log -Message $Banner
        Write-Log -Message "  Certificate Name : $certificateName"
        Write-Log -Message "  Common Name      : $commonName"
        Write-Log -Message "  Thumbprint       : $($x509.Thumbprint)"
        Write-Log -Message "  Not After        : $($x509.NotAfter)"
        Write-Log -Message "  Portal Tag       : $($target.PortalTag)"
        Write-Log -Message "  Service Flags    : $($target.ServiceFlags -join ', ')"
        Write-Log -Message "  Nodes Updated    : $($result.SuccessfulNodes -join ', ')"
        Write-Log -Message $Banner
        Write-Log -Message "ISE Cert Deployment script completed successfully. Version: $SCRIPT_VERSION"
        Write-Log -Message $Banner
        exit 0
    } catch {
        Write-Log -Message "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
        Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
        exit 1
    }
}

Main
