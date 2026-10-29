#!/usr/bin/env pwsh

<#
.SYNOPSIS
    DigiCert TLM AWR post-script: MuleSoft CloudHub 2.0 private space TLS context (ingress certificate) deployment.

.DESCRIPTION
    Runs on a TLM Agent after issuance and deploys the certificate, private key and CA chain to a
    MuleSoft Anypoint CloudHub 2.0 private space TLS context through the CloudHub 2.0 REST API:
      - Authenticates with an Anypoint Connected App (client credentials)
      - Sends the leaf as the certificate and the intermediates as the CA path (self-signed root excluded by default)
      - TLS context not found       -> creates it (POST) with a TLS 1.2/1.3 ECDHE-GCM cipher set
      - TLS context on same cert    -> no change (leaf thumbprint matches the deployed file name), exit 0
      - TLS context on older cert   -> replaces the keystore in place (PATCH)
      - Re-reads the TLS context and verifies the new CN / expiry landed
      - Every API call is bounded by a timeout, 429/5xx are retried with back-off

    CloudHub 2.0 API (base https://anypoint.mulesoft.com/runtimefabric/api):
      GET   /organizations/{orgId}/privatespaces/{spaceId}/tlsContexts
      POST  /organizations/{orgId}/privatespaces/{spaceId}/tlsContexts
      PATCH /organizations/{orgId}/privatespaces/{spaceId}/tlsContexts/{tlsContextId}

    All deployment values come from the AWR post-script arguments. Nothing customer-specific is hard coded.

.NOTES
    ===========================================================================
    AWR POST-SCRIPT ARGUMENTS
    ===========================================================================
      ARG          NAME               REQUIRED   DESCRIPTION                         EXAMPLE
      ARGUMENT_1   ORG_ID             Required   Anypoint Org / Business Group ID    3598da9f-eae1-4d5c-ad9e-8936732cf3cf
      ARGUMENT_2   PRIVATE_SPACE_ID   Required   CloudHub 2.0 private space ID       16280aa6-5aad-4d56-aa33-5ef1b56b36ce
      ARGUMENT_3   TLS_CONTEXT_NAME   Optional   TLS context to create / update      api-contoso-com
      ARGUMENT_4   CLIENT_ID          Required   Connected App client ID (32 hex)    a2df3e44215e4007a3faa112a3f6d7c3
      ARGUMENT_5   CLIENT_SECRET      Required   Connected App client secret         ********************************
      ARGUMENT_6   CONTROL_PLANE      Optional   Anypoint control plane              US  |  EU  |  GOV

    Blank = default (optional arguments only):
      ARGUMENT_1/2/4/5 blank  -> script stops before any change (required)
      ARGUMENT_3 blank        -> name derived from the certificate CN (api.contoso.com -> api-contoso-com)
      ARGUMENT_6 blank        -> $CONTROL_PLANE_DEFAULT from SCRIPT SETTINGS (US)

    Position-independent form: any argument may be written as NAME=value, e.g. TLS_CONTEXT_NAME=api-contoso-com
    or CONTROL_PLANE=EU. A NAME=value argument is read by its name, whatever position it is in.
    Unused arguments can be left blank, entered as '-', or left out at the end. The script validates every
    argument (GUID format, client ID format, control plane) and stops BEFORE making any change if a value
    is in the wrong position.

    ---------------------------------------------------------------------------
    WHERE TO FIND THE VALUES
    ---------------------------------------------------------------------------
      ORG_ID            Access Management > Business Groups > <org> > Organization ID
      PRIVATE_SPACE_ID  Runtime Manager > Private Spaces > <space> - GUID after /privatespaces/ in the URL
      CLIENT_ID/SECRET  Access Management > Connected Apps > <app>  (type: App acts on its own behalf)

    Connected App scopes (Runtime Manager), granted on the Business Group that owns the private space:
      - Cloudhub Network Administrator    (create / update TLS contexts)
      - Cloudhub Network Viewer           (read private spaces and TLS contexts)

    ---------------------------------------------------------------------------
    TLM CERTIFICATE DELIVERY
    ---------------------------------------------------------------------------
      - PEM (recommended): certificate, unencrypted private key and chain as separate files.
        An encrypted key is supported - the payload password is sent to Anypoint as keyPassphrase.
      - PFX: supported, but the agent must run the script with PowerShell 7+ (pwsh) to export the key.

    Security: the client secret is read from ARGUMENT_5 and is never written to the log (masked as ***).
    AWR arguments are visible to TLM users who can view the automation profile - restrict that access, and
    rotate the Connected App secret in Anypoint Access Management if it is exposed.

    Manual / lab test (no TLM Agent):
      .\Invoke-MuleSoftCH2CertDeploy.ps1 -CertFile .\api.crt -KeyFile .\api.key -ChainFile .\chain.pem `
          -OrgId <org> -SpaceId <space> -TlsContextName api-contoso-com -ClientId <id> -ClientSecret <secret> -DryRun
      -DryRun shows the request without changing anything. -Force redeploys even when the cert is current.

    Exit codes: 0 = deployed or already current, 1 = failure (TLM marks the AWR job failed).

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

[CmdletBinding()]
param(
    # Manual-run / lab parameters. Ignored for any value supplied through the TLM AWR payload.
    [switch]$DryRun,
    [switch]$Force,
    [string]$CertFile,
    [string]$KeyFile,
    [string]$ChainFile,
    [string]$OrgId,
    [string]$SpaceId,
    [string]$TlsContextName,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$ControlPlane,
    [string]$LogFile
)

# ============================================================================
# SCRIPT SETTINGS
# Set once per environment. Deployment targets come from the AWR arguments.
# ============================================================================
$LEGAL_NOTICE_ACCEPT   = "false"
$LOG_FILE              = "C:\Program Files\DigiCert\TLM Agent\log\mulesoft_ch2_data.log"
$SCRIPT_VERSION        = "1.0.0"

$CONTROL_PLANE_DEFAULT = "US"       # US | EU | GOV - used when ARGUMENT_6 is blank
$API_TIMEOUT_SECONDS   = 120        # per Anypoint API call
$API_MAX_ATTEMPTS      = 4          # retries for HTTP 429 / 5xx (exponential back-off)
$VERIFY_DELAY_SECONDS  = 5          # wait before re-reading the TLS context
$INCLUDE_ROOT_CA       = "false"    # "true" = also send the self-signed root in the chain

# Cipher set applied only when a NEW TLS context is created (existing contexts keep their ciphers)
$NEW_CONTEXT_CIPHERS = [ordered]@{
    aes128GcmSha256            = $false
    aes128Sha256               = $false
    aes256GcmSha384            = $false
    aes256Sha256               = $false
    dheRsaAes128Sha256         = $false
    dheRsaAes256GcmSha384      = $false
    dheRsaAes256Sha256         = $false
    ecdheEcdsaAes128GcmSha256  = $true
    ecdheEcdsaAes256GcmSha384  = $true
    ecdheRsaAes128GcmSha256    = $true
    ecdheRsaAes256GcmSha384    = $true
    ecdheEcdsaChacha20Poly1305 = $true
    ecdheRsaChacha20Poly1305   = $true
    dheRsaChacha20Poly1305     = $false
    tlsAes256GcmSha384         = $true
    tlsChacha20Poly1305Sha256  = $true
    tlsAes128GcmSha256         = $true
}
# ============================================================================
# END OF SCRIPT SETTINGS
# ============================================================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (-not $LogFile)    { $LogFile    = $LOG_FILE }
$GuidPattern     = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
$ClientIdPattern = '^[0-9a-fA-F]{32}$'

#region ---------- Logging ----------
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line    # Write-Host, not Write-Output: logging must never leak into function return values
}
#endregion

#region ---------- AWR argument parsing ----------
function Resolve-AwrArguments {
    <#
      Returns a hashtable NAME -> value. Supports positional ARGUMENT_n and NAME=value in any position.
      '-', 'none', 'n/a', 'na', 'default' and blank mean "not supplied".
    #>
    param([object[]]$RawArgs)
    $names  = @('ORG_ID', 'PRIVATE_SPACE_ID', 'TLS_CONTEXT_NAME', 'CLIENT_ID', 'CLIENT_SECRET', 'CONTROL_PLANE')
    $result = @{}
    foreach ($n in $names) { $result[$n] = '' }

    $positional = @()
    foreach ($raw in @($RawArgs)) {
        $v = "$raw".Trim()
        if ($v -match '^([A-Za-z_]+)\s*=\s*(.*)$' -and $names -contains $Matches[1].ToUpper()) {
            $result[$Matches[1].ToUpper()] = $Matches[2].Trim()
            $positional += $null          # keeps positions of following arguments stable
        } else {
            $positional += $v
        }
    }
    for ($i = 0; $i -lt $names.Count -and $i -lt $positional.Count; $i++) {
        $n = $names[$i]
        if ($null -ne $positional[$i] -and -not $result[$n]) { $result[$n] = $positional[$i] }
    }
    foreach ($n in $names) {
        if ($result[$n] -match '^(?i)(-|none|n/a|na|default)?$') { $result[$n] = '' }
    }
    return $result
}

function Hide-Value {
    <# Shows a value in an error message without exposing it: first 4 characters + length. #>
    param([string]$Value)
    if ($Value.Length -le 4) { return "'****' (length $($Value.Length))" }
    return "'$($Value.Substring(0,4))****' (length $($Value.Length))"
}

function Assert-Settings {
    <# Validates every value BEFORE any change. Detects values that are in the wrong position.
       Values are masked in messages: a shifted argument list can put the client secret in any position. #>
    $errors = @()
    if (-not $script:OrgId)  { $errors += 'ARGUMENT_1 ORG_ID is required.' }
    elseif ($script:OrgId -notmatch $GuidPattern) {
        $errors += "ARGUMENT_1 ORG_ID $(Hide-Value $script:OrgId) is not a GUID (8-4-4-4-12). Check for a missing/extra character or a shifted argument."
    }
    if (-not $script:SpaceId) { $errors += 'ARGUMENT_2 PRIVATE_SPACE_ID is required.' }
    elseif ($script:SpaceId -notmatch $GuidPattern) {
        $errors += "ARGUMENT_2 PRIVATE_SPACE_ID $(Hide-Value $script:SpaceId) is not a GUID (8-4-4-4-12)."
    }
    if ($script:OrgId -and $script:SpaceId -and $script:OrgId -eq $script:SpaceId) {
        $errors += 'ARGUMENT_1 and ARGUMENT_2 are identical - ORG_ID and PRIVATE_SPACE_ID are different values.'
    }
    if ($script:TlsContextName -and $script:TlsContextName -match $GuidPattern) {
        $errors += "ARGUMENT_3 TLS_CONTEXT_NAME $(Hide-Value $script:TlsContextName) looks like a GUID - arguments appear shifted."
    }
    if ($script:TlsContextName -and $script:TlsContextName -match '^[0-9a-fA-F]{32}$') {
        $errors += "ARGUMENT_3 TLS_CONTEXT_NAME $(Hide-Value $script:TlsContextName) looks like a client ID/secret - arguments appear shifted."
    }
    if (-not $script:ClientId) { $errors += 'ARGUMENT_4 CLIENT_ID is required.' }
    elseif ($script:ClientId -notmatch $ClientIdPattern) {
        $errors += "ARGUMENT_4 CLIENT_ID $(Hide-Value $script:ClientId) is not a 32-character hex Connected App ID (check for spaces or a shifted argument)."
    }
    if ([string]::IsNullOrWhiteSpace($script:ClientSecret)) { $errors += 'ARGUMENT_5 CLIENT_SECRET is required.' }
    elseif ($script:ClientSecret -match $GuidPattern) {
        $errors += 'ARGUMENT_5 CLIENT_SECRET looks like a GUID - arguments appear shifted.'
    }
    if ($script:ControlPlane -notin 'US', 'EU', 'GOV') {
        $errors += "ARGUMENT_6 CONTROL_PLANE $(Hide-Value $script:ControlPlane) must be US, EU or GOV."
    }
    if ($errors) { throw ("Argument validation failed - no change made:`n  - " + ($errors -join "`n  - ")) }
}
#endregion

#region ---------- Certificate helpers ----------
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value } else { return $null }
}

function ConvertTo-PemCert {
    param([byte[]]$Der)
    $b64 = [Convert]::ToBase64String($Der)
    $sb  = New-Object Text.StringBuilder
    [void]$sb.Append("-----BEGIN CERTIFICATE-----`n")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        [void]$sb.Append($b64.Substring($i, [Math]::Min(64, $b64.Length - $i))).Append("`n")
    }
    [void]$sb.Append("-----END CERTIFICATE-----`n")
    return $sb.ToString()
}

function Get-PemCertBlocks {
    param([string]$Text)
    $rx = [regex]'-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----'
    return @($rx.Matches($Text) | ForEach-Object { $_.Value })
}

function Split-PemFile {
    <#
      Splits PEM text into its private key and certificate blocks. Handles separate files and combined
      files (key + leaf + chain in one .pem, in any order). Key formats: PKCS#8 (PRIVATE KEY),
      encrypted PKCS#8 (ENCRYPTED PRIVATE KEY), PKCS#1 (RSA PRIVATE KEY), SEC1 (EC PRIVATE KEY).
    #>
    param([string]$Text)
    $result = @{ Key = $null; KeyEncrypted = $false; Certs = @() }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $result }
    $km = [regex]::Match($Text, '-----BEGIN ((?:ENCRYPTED |RSA |EC )?PRIVATE KEY)-----[\s\S]+?-----END \1-----')
    if ($km.Success) {
        $result.Key = $km.Value.Trim() + "`n"
        $result.KeyEncrypted = ($km.Groups[1].Value -eq 'ENCRYPTED PRIVATE KEY' -or $km.Value -match 'Proc-Type:\s*4,ENCRYPTED')
    }
    $result.Certs = @(Get-PemCertBlocks -Text $Text)
    return $result
}

function Get-OrderedChain {
    <# Returns @{ Leaf = X509Certificate2; Pem = leaf + intermediates; Count } #>
    param([string[]]$PemBlocks)
    $byThumb = @{}
    foreach ($b in $PemBlocks) {
        $b64 = ($b -replace '-----(BEGIN|END) CERTIFICATE-----', '') -replace '\s', ''
        $x   = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, [Convert]::FromBase64String($b64))
        if (-not $byThumb.ContainsKey($x.Thumbprint)) { $byThumb[$x.Thumbprint] = $x }
    }
    $certs = @($byThumb.Values)
    if ($certs.Count -eq 0) { throw 'No certificates found in the TLM payload. Check the TLM certificate format includes the certificate (PEM), not only the key.' }

    # Leaf = the certificate that did not issue any other certificate in the set
    $leaf = $certs | Where-Object {
        $subj = $_.Subject
        -not ($certs | Where-Object { $_.Issuer -eq $subj -and $_.Subject -ne $subj })
    } | Select-Object -First 1
    if (-not $leaf) { $leaf = $certs[0] }

    $ordered = New-Object Collections.ArrayList
    [void]$ordered.Add($leaf)
    $current = $leaf
    while ($current.Subject -ne $current.Issuer) {
        $next = $certs | Where-Object { $_.Subject -eq $current.Issuer -and -not $ordered.Contains($_) } | Select-Object -First 1
        if (-not $next) { break }
        if ($next.Subject -eq $next.Issuer -and $INCLUDE_ROOT_CA -ne 'true') { break }
        [void]$ordered.Add($next)
        $current = $next
    }
    $pem      = ($ordered | ForEach-Object { ConvertTo-PemCert -Der $_.RawData }) -join ''
    $leafPem  = ConvertTo-PemCert -Der $leaf.RawData
    $chainPem = (@($ordered | Select-Object -Skip 1) | ForEach-Object { ConvertTo-PemCert -Der $_.RawData }) -join ''
    return @{ Leaf = $leaf; Pem = $pem; LeafPem = $leafPem; ChainPem = $chainPem; Count = $ordered.Count }
}

function Read-PfxAsPem {
    param([string]$Path, [string]$Password)
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw 'PFX delivery requires PowerShell 7+ to export the private key as PEM. Use PEM delivery in the TLM profile, or run the AWR script with pwsh.'
    }
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable -bor `
             [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
    $col = New-Object Security.Cryptography.X509Certificates.X509Certificate2Collection
    $col.Import($Path, $Password, $flags)
    $keyCert = $col | Where-Object { $_.HasPrivateKey } | Select-Object -First 1
    if (-not $keyCert) { throw "PFX $Path contains no private key." }
    $alg = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($keyCert)
    if (-not $alg) { $alg = [Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($keyCert) }
    if (-not $alg) { throw 'Unsupported private key algorithm in PFX (expected RSA or ECDSA).' }
    $keyPem  = [string]::new([Security.Cryptography.PemEncoding]::Write('PRIVATE KEY', $alg.ExportPkcs8PrivateKey()))
    $certPem = ($col | ForEach-Object { ConvertTo-PemCert -Der $_.RawData }) -join ''
    return @{ CertPem = $certPem; KeyPem = "$keyPem`n" }
}

function Test-ExpiryMatch {
    <# Anypoint expirationDate is date-only (yyyy-MM-dd). Match the leaf NotAfter date in UTC or local time. #>
    param([string]$ExpirationDate, [datetime]$NotAfter)
    if ([string]::IsNullOrWhiteSpace($ExpirationDate)) { return $false }
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParse($ExpirationDate, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$d)) { return $false }
    return ($d.Date -eq $NotAfter.ToUniversalTime().Date -or $d.Date -eq $NotAfter.ToLocalTime().Date)
}
#endregion

#region ---------- Anypoint API ----------
function Invoke-Anypoint {
    param(
        [string]$Method, [string]$Uri, $Body, [string]$Token,
        [string]$ContentType = 'application/json'
    )
    $headers = @{ Accept = 'application/json' }
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }

    for ($attempt = 1; $attempt -le $API_MAX_ATTEMPTS; $attempt++) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; Headers = $headers; ContentType = $ContentType
                    UseBasicParsing = $true; TimeoutSec = $API_TIMEOUT_SECONDS }
            if ($null -ne $Body) {
                if ($Body -is [string]) { $p['Body'] = [Text.Encoding]::UTF8.GetBytes($Body) } else { $p['Body'] = $Body }
            }
            return Invoke-RestMethod @p
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            $detail = $null
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
            elseif ($_.Exception.Response -and ($_.Exception.Response | Get-Member -Name GetResponseStream -ErrorAction SilentlyContinue)) {
                try { $detail = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
            }
            if (-not $detail) { $detail = $_.Exception.Message }
            if (-not $status -and $_.Exception.Message -match '(?i)timed out|timeout') {
                throw "TIMEOUT after ${API_TIMEOUT_SECONDS}s: $Method $Uri - no response from Anypoint. If the private space shows 'Saved changes are being applied' or a FAILED network, changes are queued and will not complete until the space is healthy."
            }
            if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $API_MAX_ATTEMPTS) {
                $wait = [int][Math]::Pow(2, $attempt)
                Write-Log "HTTP $status on $Method $Uri - retry $attempt/$($API_MAX_ATTEMPTS - 1) in ${wait}s" 'WARN'
                Start-Sleep -Seconds $wait
                continue
            }
            throw "HTTP $status $Method $Uri :: $detail"
        }
    }
}

function Get-CtxKeyStore {
    <# CloudHub 2.0 returns keyStore at the top level of a TLS context; tolerate a tlsConfig.keyStore shape too. #>
    param($Ctx)
    $ks = Get-Prop $Ctx 'keyStore'
    if (-not $ks) { $ks = Get-Prop (Get-Prop $Ctx 'tlsConfig') 'keyStore' }
    return $ks
}

function Get-TlsContextByName {
    param([string]$CtxBase, [string]$Token, [string]$Name)
    $list  = Invoke-Anypoint -Method GET -Uri $CtxBase -Token $Token
    $items = @()
    if     ($list -is [array])      { $items = $list }
    elseif (Get-Prop $list 'value') { $items = @($list.value) }
    elseif (Get-Prop $list 'items') { $items = @($list.items) }
    elseif (Get-Prop $list 'data')  { $items = @($list.data) }
    elseif ($list)                  { $items = @($list) }
    return ($items | Where-Object { $_ -and $_.name -eq $Name } | Select-Object -First 1)
}
#endregion

# ============================================================================
# MAIN
# ============================================================================
$token = $null; $resolvedSecret = $null; $keyPem = $null
try {
    Write-Log "===== MuleSoft CloudHub 2.0 TLS context deploy v$SCRIPT_VERSION - start ====="

    if ($LEGAL_NOTICE_ACCEPT -ne 'true') {
        throw 'LEGAL_NOTICE_ACCEPT is not "true". Review the legal notice in the script header and set it in SCRIPT SETTINGS. No change made.'
    }

    # ---------- 1. Inputs: TLM AWR payload or manual parameters ----------
    $certTexts = @(); $keyPassphrase = $null; $pfxPath = $null; $pfxPassword = $null

    if (-not [string]::IsNullOrWhiteSpace($env:DC1_POST_SCRIPT_DATA)) {
        Write-Log 'Mode: TLM AWR (DC1_POST_SCRIPT_DATA present)'
        $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:DC1_POST_SCRIPT_DATA)) | ConvertFrom-Json

        $a = Resolve-AwrArguments -RawArgs @(Get-Prop $payload 'args')
        if ($a.ORG_ID)           { $OrgId          = $a.ORG_ID }
        if ($a.PRIVATE_SPACE_ID) { $SpaceId        = $a.PRIVATE_SPACE_ID }
        if ($a.TLS_CONTEXT_NAME) { $TlsContextName = $a.TLS_CONTEXT_NAME }
        if ($a.CLIENT_ID)        { $ClientId       = $a.CLIENT_ID }
        if ($a.CLIENT_SECRET)    { $ClientSecret   = $a.CLIENT_SECRET }
        if ($a.CONTROL_PLANE)    { $ControlPlane   = $a.CONTROL_PLANE }

        $certFolder = Get-Prop $payload 'certfolder'
        $pwdField   = @('password', 'keystorepassword', 'pfxpassword') | ForEach-Object { Get-Prop $payload $_ } | Where-Object { $_ } | Select-Object -First 1

        foreach ($f in @(Get-Prop $payload 'files')) {
            $path = if ($certFolder) { Join-Path $certFolder $f } else { $f }
            if (-not (Test-Path $path)) { throw "TLM file not found: $path" }
            $ext = [IO.Path]::GetExtension($path).ToLower()
            Write-Log "Payload file: $([IO.Path]::GetFileName($path))"
            if ($ext -in '.pfx', '.p12') { $pfxPath = $path; $pfxPassword = $pwdField; continue }
            # A file may hold the key, the certificates, or both (combined PEM) - extract each part separately
            $parts = Split-PemFile -Text (Get-Content -Path $path -Raw)
            if ($parts.Key) {
                if ($keyPem -and $keyPem -ne $parts.Key) { Write-Log "More than one private key in payload - using the one from $([IO.Path]::GetFileName($path))." 'WARN' }
                $keyPem = $parts.Key
                if ($parts.KeyEncrypted) { $keyPassphrase = $pwdField }
            }
            if ($parts.Certs.Count -gt 0) { $certTexts += ($parts.Certs -join "`n") }
            Write-Log ("  contains: {0} certificate(s){1}" -f $parts.Certs.Count, $(if ($parts.Key) { $(if ($parts.KeyEncrypted) { ' + encrypted private key' } else { ' + private key' }) } else { '' }))
        }
    } else {
        Write-Log 'Mode: manual run (parameters)'
        foreach ($n in 'CertFile', 'KeyFile') {
            if (-not (Get-Variable -Name $n -ValueOnly)) { throw "DC1_POST_SCRIPT_DATA not set and -$n not supplied." }
        }
        foreach ($mf in @($CertFile, $ChainFile, $KeyFile) | Where-Object { $_ } | Select-Object -Unique) {
            $parts = Split-PemFile -Text (Get-Content $mf -Raw)
            if ($parts.Certs.Count -gt 0) { $certTexts += ($parts.Certs -join "`n") }
            if ($parts.Key) { $keyPem = $parts.Key }
        }
    }

    $OrgId = "$OrgId".Trim(); $SpaceId = "$SpaceId".Trim(); $TlsContextName = "$TlsContextName".Trim(); $ClientId = "$ClientId".Trim()
    $ControlPlane = if ("$ControlPlane".Trim()) { "$ControlPlane".Trim().ToUpper() } else { $CONTROL_PLANE_DEFAULT.ToUpper() }

    if ($pfxPath) {
        Write-Log "Converting PFX to PEM: $([IO.Path]::GetFileName($pfxPath))"
        $conv = Read-PfxAsPem -Path $pfxPath -Password $pfxPassword
        $certTexts += $conv.CertPem
        $keyPem = $conv.KeyPem
    }
    if (-not $keyPem) { throw 'No private key found in the TLM payload. Enable key delivery (PEM KEY or PFX) in the TLM profile.' }

    # ---------- 2. Certificate chain ----------
    $blocks = @(); foreach ($t in $certTexts) { $blocks += Get-PemCertBlocks -Text $t }
    $chain  = Get-OrderedChain -PemBlocks $blocks
    $leaf   = $chain.Leaf
    $leafCN = $leaf.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
    Write-Log ("Leaf: CN={0} | Serial={1} | Thumbprint={2} | NotAfter={3:u} | chain certs={4}" -f `
        $leafCN, $leaf.SerialNumber, $leaf.Thumbprint, $leaf.NotAfter.ToUniversalTime(), $chain.Count)
    if ($leaf.NotAfter -lt (Get-Date)) { throw 'Leaf certificate is already expired - refusing to deploy.' }

    if (-not $TlsContextName) {
        $TlsContextName = (($leafCN -replace '^\*\.', 'wildcard-') -replace '[^A-Za-z0-9-]', '-').ToLower().Trim('-')
        Write-Log "ARGUMENT_3 blank - TLS context name derived from CN: $TlsContextName"
    }

    # ---------- 3. Validate every setting before any change ----------
    Assert-Settings
    Write-Log ("Settings: ORG_ID={0} | PRIVATE_SPACE_ID={1} | TLS_CONTEXT_NAME={2} | CLIENT_ID={3} | CLIENT_SECRET={4} | CONTROL_PLANE={5}" -f `
        $OrgId, $SpaceId, $TlsContextName, $ClientId, '***', $ControlPlane)

    # ---------- 4. Authenticate ----------
    $base = switch ($ControlPlane) {
        'EU'    { 'https://eu1.anypoint.mulesoft.com' }
        'GOV'   { 'https://gov.anypoint.mulesoft.com' }
        default { 'https://anypoint.mulesoft.com' }
    }
    $resolvedSecret = $ClientSecret.Trim()
    $tok = Invoke-Anypoint -Method POST -Uri "$base/accounts/api/v2/oauth2/token" `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{ grant_type = 'client_credentials'; client_id = $ClientId; client_secret = $resolvedSecret }
    $token = $tok.access_token
    $resolvedSecret = $null; $ClientSecret = $null
    if (-not $token) { throw 'Token response did not contain access_token.' }
    Write-Log 'Authenticated to Anypoint Platform (connected app).'

    $ctxBase = "$base/runtimefabric/api/organizations/$OrgId/privatespaces/$SpaceId/tlsContexts"

    # ---------- 5. Find existing TLS context ----------
    $existing = Get-TlsContextByName -CtxBase $ctxBase -Token $token -Name $TlsContextName

    # The leaf thumbprint is embedded in the file names. Anypoint returns fileName on every read, so the
    # next run can tell exactly which certificate is deployed (CN + expiry date alone cannot: a reissue
    # often has the same CN and the same expiry date).
    # Anypoint limits file names to 64 characters: use the first 16 hex characters of the thumbprint
    # (unique per certificate) and shorten the context-name prefix if needed.
    $thumb = $leaf.Thumbprint.Substring(0, 16).ToLower()
    function New-KsFileName([string]$Suffix) {
        $tail   = "-$thumb-$Suffix"
        $prefix = $TlsContextName
        if ($prefix.Length + $tail.Length -gt 64) { $prefix = $prefix.Substring(0, 64 - $tail.Length).TrimEnd('-', '.') }
        return "$prefix$tail"
    }
    # Anypoint accepts exactly ONE certificate in 'certificate' (RB-1003 otherwise).
    # Intermediates go in the CA path ('capath'); if the API rejects capath, the leaf is deployed alone.
    $keyStore = [ordered]@{
        source              = 'PEM'
        certificate         = $chain.LeafPem
        certificateFileName = (New-KsFileName "cert.pem")
        key                 = $keyPem
        keyFileName         = (New-KsFileName "key.pem")
    }
    if ($keyPassphrase) { $keyStore['keyPassphrase'] = $keyPassphrase }
    $keyStoreWithChain = [ordered]@{}
    foreach ($k in @($keyStore.Keys)) { $keyStoreWithChain[$k] = $keyStore[$k] }
    if ($chain.ChainPem) {
        $keyStoreWithChain['capath']         = $chain.ChainPem
        $keyStoreWithChain['capathFileName'] = (New-KsFileName "ca.pem")
    }

    if ($existing) {
        if ((Get-Prop $existing 'type') -eq 'default') { throw "TLS context '$TlsContextName' is the platform default context and cannot be modified." }
        $exKs     = Get-CtxKeyStore $existing
        $exExpiry = Get-Prop $exKs 'expirationDate'
        $exCN     = Get-Prop $exKs 'cn'
        $exFile   = [string](Get-Prop $exKs 'fileName')
        Write-Log "Existing context id=$($existing.id) | CN=$exCN | expires=$exExpiry | file=$exFile"

        if (-not $Force -and $exFile -and $exFile.ToLower().Contains($thumb)) {
            Write-Log "Certificate already deployed (thumbprint $($leaf.Thumbprint) matches the deployed file $exFile) - nothing to do. Use -Force to redeploy."
            Write-Log '===== Completed (no change) ====='
            exit 0
        }
        if ($Force) {
            Write-Log '-Force specified - redeploying the certificate.'
        } elseif ($exCN -eq $leafCN -and (Test-ExpiryMatch -ExpirationDate $exExpiry -NotAfter $leaf.NotAfter)) {
            Write-Log 'Deployed certificate has the same CN and expiry date but a different/unknown thumbprint - deploying the new certificate.'
        } else {
            Write-Log 'Deployed certificate differs from the new certificate - deploying.'
        }
        $method = 'PATCH'; $uri = "$ctxBase/$($existing.id)"
        $bodies = @(
            [ordered]@{ tlsConfig = [ordered]@{ keyStore = $keyStoreWithChain } },
            [ordered]@{ tlsConfig = [ordered]@{ keyStore = $keyStore } }
        )
    } else {
        Write-Log "TLS context '$TlsContextName' not found - will create."
        $method = 'POST'; $uri = $ctxBase
        $bodies = @(
            [ordered]@{ name = $TlsContextName; tlsConfig = [ordered]@{ keyStore = $keyStoreWithChain }; ciphers = $NEW_CONTEXT_CIPHERS },
            [ordered]@{ name = $TlsContextName; tlsConfig = [ordered]@{ keyStore = $keyStore }; ciphers = $NEW_CONTEXT_CIPHERS }
        )
    }

    if (-not $chain.ChainPem) { $bodies = @($bodies[1]) }

    if ($DryRun) {
        $json = $bodies[0] | ConvertTo-Json -Depth 10
        $redacted = $json -replace '("key"\s*:\s*")[^"]*(")', '$1<redacted>$2' -replace '("keyPassphrase"\s*:\s*")[^"]*(")', '$1<redacted>$2'
        Write-Log "DRY RUN - would $method $uri" 'WARN'
        Write-Log "Payload (key redacted; leaf-only body is the automatic fallback if capath is rejected):`n$redacted" 'DEBUG'
        exit 0
    }

    # ---------- 6. Deploy (leaf + capath chain first; leaf only if the API rejects capath) ----------
    $resp = $null; $chainAttached = $false
    Write-Log "Sending $method to Anypoint (timeout ${API_TIMEOUT_SECONDS}s): leaf certificate$(if ($chain.ChainPem) { ' + CA path (intermediates)' })..."
    for ($b = 0; $b -lt $bodies.Count; $b++) {
        $json = $bodies[$b] | ConvertTo-Json -Depth 10
        $withChain = [bool]($bodies[$b].tlsConfig.keyStore.Contains('capath'))
        try {
            $resp = Invoke-Anypoint -Method $method -Uri $uri -Body $json -Token $token
            $chainAttached = $withChain
            Write-Log "$method accepted ($(if ($withChain) { 'leaf + CA path chain' } else { 'leaf certificate only' }))"
            break
        } catch {
            if ($withChain -and $b -lt $bodies.Count - 1 -and $_.Exception.Message -match '^HTTP (400|422) ' -and $_.Exception.Message -match '(?i)capath|additional propert') {
                Write-Log "API did not accept the CA path field ($($_.Exception.Message.Split([char]10)[0])) - retrying with the leaf certificate only." 'WARN'
                continue
            }
            throw
        }
    }
    if ($chain.ChainPem -and -not $chainAttached) {
        Write-Log 'Intermediate chain NOT attached - clients that do not already have the issuing CA may fail validation. Add the CA path in Runtime Manager if required.' 'WARN'
    }
    $ctxId = if ($existing) { $existing.id } else { Get-Prop $resp 'id' }
    Write-Log "$method succeeded. TLS context id=$ctxId"

    # ---------- 7. Verify ----------
    Start-Sleep -Seconds $VERIFY_DELAY_SECONDS
    $check = Get-TlsContextByName -CtxBase $ctxBase -Token $token -Name $TlsContextName
    if (-not $check) { throw "TLS context '$TlsContextName' not found after $method." }
    $ks     = Get-CtxKeyStore $check
    $newExp = Get-Prop $ks 'expirationDate'
    $newCN  = Get-Prop $ks 'cn'
    $sans   = (@(Get-Prop $ks 'san') | Where-Object { $_ }) -join ', '
    $newFile = [string](Get-Prop $ks 'fileName')
    Write-Log "Verify: id=$($check.id) | CN=$newCN | expires=$newExp | file=$newFile | SAN=$sans"
    $thumbOk  = [bool]($newFile -and $newFile.ToLower().Contains($thumb))
    $expiryOk = Test-ExpiryMatch -ExpirationDate $newExp -NotAfter $leaf.NotAfter
    if ($thumbOk -and $expiryOk) {
        Write-Log "Verified: deployed file carries thumbprint $($leaf.Thumbprint) and expiry $newExp matches."
    } elseif ($thumbOk) {
        Write-Log "Deployed file carries thumbprint $($leaf.Thumbprint), but expirationDate '$newExp' does not match the leaf yet (Anypoint may still be applying). Confirm in Runtime Manager." 'WARN'
    } elseif ($expiryOk) {
        Write-Log "Expiry $newExp matches; fileName does not carry the thumbprint - the next run may redeploy (harmless)." 'WARN'
    } else {
        throw "Post-deploy check failed: fileName '$newFile' and expiry '$newExp' do not match the deployed leaf (thumbprint $($leaf.Thumbprint), NotAfter $($leaf.NotAfter.ToUniversalTime().ToString('yyyy-MM-dd')))."
    }

    Write-Log '===== Completed successfully ====='
    exit 0
}
catch {
    foreach ($l in ($_.Exception.Message -split "`n")) { Write-Log $l 'ERROR' }
    Write-Log '===== FAILED =====' 'ERROR'
    exit 1
}
finally {
    $token = $null; $resolvedSecret = $null; $keyPem = $null; $ClientSecret = $null
    [GC]::Collect()
}
