<#
LEGAL_NOTICE
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
LEGAL_NOTICE
#>

<#
.SYNOPSIS
    DigiCert TLM AWR post-issuance script - Cisco Firepower Management Center (FMC)
    certificate import (Internal Certificate object).

.DESCRIPTION
    Triggered by the DigiCert TLM Agent after issuance/renewal. Reads DC1_POST_SCRIPT_DATA,
    extracts the delivered PEM certificate and private key, authenticates to the FMC REST API
    and creates an Internal Certificate object (POST .../object/internalcertificates).

    This script only creates the certificate OBJECT in FMC. It does not assign the certificate
    to a device, VPN or SSL policy and does not deploy configuration.

.NOTES
    Script version : 2.2
    Runtime        : Windows PowerShell 5.1 (also runs on PowerShell 7)
    Log file       : C:\Program Files\DigiCert\TLM Agent\log\fmc_awr.log (override with LOGFILE=)
    TLM delivery   : PEM (separate .crt/.key files, or one combined .pem containing both)

    ARGUMENTS (TLM AWR post-script argument fields)
    ARGUMENT_1  Base64-encoded "username:password" for an FMC account with API access.
                Generate with:
                [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("username:password"))
                (Base64 is encoding, not encryption.)
    ARGUMENT_2  FMC hostname, IP or URL, optional :port    e.g. fmc01.corp.com or https://10.0.0.5:443
    ARGUMENT_3  Certificate object name in FMC
    ARGUMENT_4  Optional settings, semicolon-delimited KEY=VALUE pairs:
                SKIP_TLS_VALIDATION=true|false   (default false) accept any FMC HTTPS certificate.
                                                 Lab use only.
                DRY_RUN=true|false               (default false) validate the delivery, make no FMC calls
                NAME_MODE=timestamp|exact        (default timestamp)
                                                 timestamp: object is named <ARGUMENT_3>-yyyyMMdd-HHmmss,
                                                 so every issuance/renewal creates a new object and never
                                                 collides with an existing name.
                                                 exact: object is named exactly ARGUMENT_3. A name that
                                                 already exists is rejected by FMC and the run fails.
                                                 replace: object is named exactly ARGUMENT_3. If an object with that
                                                 name already exists it is DELETED first, then re-created with the new
                                                 certificate and key (new FMC object id). If FMC refuses the delete
                                                 (for example the object is in use) nothing is changed and the run fails.
                                                 If the create fails after the delete, FMC has no object with that name.
                DOMAIN_UUID=<uuid>               (default: taken from the FMC login response)
                LOGFILE=<full path>
#>

# =============================================================================
# SCRIPT-LEVEL SETTINGS
# =============================================================================
$ScriptVersion = "2.2"

# DigiCert legal notice acceptance - see the LEGAL_NOTICE block at the top of this file.
# Must be "true" or the script exits before making any change.
$LEGAL_NOTICE_ACCEPT = "false"

$script:LOGFILE   = "C:\Program Files\DigiCert\TLM Agent\log\fmc_awr22.log"
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:LogBuffer = New-Object System.Collections.ArrayList
$script:Secrets   = New-Object System.Collections.ArrayList
$script:SkipCert  = @{}
$script:ExitCode  = 0
$script:LeafCert  = $null
$script:AllCerts  = New-Object System.Collections.ArrayList

$ErrorActionPreference = "Stop"

# =============================================================================
# LOGGING
# =============================================================================
function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    [void]$script:LogBuffer.Add($line)
    try {
        $dir = Split-Path -Path $script:LOGFILE -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        [System.IO.File]::AppendAllText($script:LOGFILE, $line + "`r`n", $script:Utf8NoBom)
    }
    catch {
        # logging must never stop the run
    }
    Write-Host $line
}

function Write-Banner {
    param([string]$Text)
    $bar = "=" * 42
    Write-Log $bar
    Write-Log $Text
    Write-Log $bar
}

function Register-Secret {
    param([string]$Value)
    if (-not [string]::IsNullOrEmpty($Value) -and -not $script:Secrets.Contains($Value)) { [void]$script:Secrets.Add($Value) }
}

function Protect-Text {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $out = $Text
    foreach ($s in $script:Secrets) {
        if ($s.Length -ge 4) { $out = $out.Replace($s, ($s.Substring(0, 2) + "***")) }
    }
    return $out
}

function Limit-Text {
    param([string]$Text, [int]$Max = 2000)
    if ([string]::IsNullOrEmpty($Text)) { return "(empty)" }
    $flat = ($Text -replace "[\r\n]+", " ")
    if ($flat.Length -le $Max) { return $flat }
    return $flat.Substring(0, $Max) + " ...(truncated, $($flat.Length) chars total)"
}

function ConvertTo-Bool {
    param([string]$Value, [bool]$Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    return @("true", "yes", "1", "on") -contains $Value.Trim().ToLowerInvariant()
}

# =============================================================================
# PEM HELPERS
# =============================================================================
function ConvertFrom-PemCertificate {
    param([string]$Pem)
    $b64 = ($Pem -replace '-----(BEGIN|END) CERTIFICATE-----', '') -replace '\s', ''
    $raw = [Convert]::FromBase64String($b64)
    return (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList (, $raw))
}

# =============================================================================
# FMC REST CALL WRAPPER
# Logs: "<op> via: METHOD URL", "<op> HTTP status", "<op> response"
# Never throws on an HTTP error - the caller decides. The FMC error body is always logged.
# =============================================================================
function Get-HeaderValue {
    param($Headers, [string]$Name)
    if ($null -eq $Headers) { return "" }
    $v = $Headers[$Name]
    if ($null -eq $v) { return "" }
    return ("" + @($v)[0])
}

function Invoke-FmcRequest {
    param(
        [string]$Operation,
        [string]$Method,
        [string]$Url,
        [hashtable]$Headers,
        [string]$Body,
        [int]$TimeoutSec = 60
    )
    Write-Log "$Operation via: $Method $Url"

    $p = @{ Uri = $Url; Method = $Method; UseBasicParsing = $true; TimeoutSec = $TimeoutSec; ErrorAction = "Stop" }
    foreach ($k in $script:SkipCert.Keys) { $p[$k] = $script:SkipCert[$k] }
    if ($Headers) { $p["Headers"] = $Headers }
    if ($Body) { $p["Body"] = $Body; $p["ContentType"] = "application/json" }

    $status = 0
    $text = ""
    $respHeaders = $null
    $errorText = $null
    try {
        $r = Invoke-WebRequest @p
        $status = [int]$r.StatusCode
        $text = "" + $r.Content
        $respHeaders = $r.Headers
    }
    catch {
        $errorText = $_.Exception.Message
        $resp = $_.Exception.Response
        if ($resp) { try { $status = [int]$resp.StatusCode } catch { } }
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $text = $_.ErrorDetails.Message
        }
        elseif ($resp -and $resp.GetType().GetMethod("GetResponseStream")) {
            try {
                $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $text = $sr.ReadToEnd()
                $sr.Close()
            }
            catch { }
        }
    }

    Write-Log "$Operation HTTP status: $status"
    if ($errorText -and $status -eq 0) { Write-Log "$Operation connection error: $errorText" }
    Write-Log "$Operation response: $(Protect-Text (Limit-Text $text))"

    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($text)) { try { $json = $text | ConvertFrom-Json } catch { $json = $null } }
    $ok = ($status -ge 200 -and $status -lt 300)
    if ($ok) { Write-Log "$Operation response indicates success" } else { Write-Log "$Operation response indicates failure" }

    return [pscustomobject]@{ Status = $status; Text = $text; Json = $json; Headers = $respHeaders; Success = $ok; Error = $errorText }
}

# =============================================================================
# MAIN
# =============================================================================
try {
    # -------------------------------------------------------------------------
    # S00 Legal notice, runtime
    # -------------------------------------------------------------------------
    Write-Banner "Cisco FMC post-issuance script v$ScriptVersion started"
    Write-Log "Checking legal notice acceptance..."
    if ($LEGAL_NOTICE_ACCEPT -ne "true") {
        Write-Log "ERROR: Legal notice not accepted. Set `$LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
        Write-Log "ERROR: Script execution terminated due to legal notice non-acceptance. No changes made."
        $script:ExitCode = 1
        throw "LEGAL_NOTICE_NOT_ACCEPTED"
    }
    Write-Log "Legal notice accepted, proceeding with script execution."
    Write-Log "  SCRIPT_VERSION: $ScriptVersion"
    Write-Log "  POWERSHELL: $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    Write-Log "  CLR: $([System.Environment]::Version)"
    Write-Log "  COMPUTERNAME: $env:COMPUTERNAME"

    # -------------------------------------------------------------------------
    # S01 DC1_POST_SCRIPT_DATA extraction
    # -------------------------------------------------------------------------
    Write-Banner "Starting DC1_POST_SCRIPT_DATA extraction..."
    $rawData = $env:DC1_POST_SCRIPT_DATA
    if ([string]::IsNullOrWhiteSpace($rawData)) { throw "DC1_POST_SCRIPT_DATA environment variable is not set. This script must be run by the DigiCert TLM Agent." }
    Write-Log "DC1_POST_SCRIPT_DATA is set (length: $($rawData.Length) characters)"
    try {
        $jsonString = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($rawData.Trim()))
        $certInfo = $jsonString | ConvertFrom-Json
    }
    catch { throw "Failed to decode/parse DC1_POST_SCRIPT_DATA: $($_.Exception.Message)" }
    Write-Log "JSON decoded and parsed successfully"

    $argList = @()
    if ($certInfo.PSObject.Properties["args"] -and $certInfo.args) { $argList = @($certInfo.args) }
    Write-Log "Args array count: $($argList.Count)"
    if ($argList.Count -lt 3) { throw "Expected at least 3 arguments (base64 credentials, FMC host, certificate name). Got: $($argList.Count)" }
    $arg1 = ("" + $argList[0]).Trim()
    $arg2 = ("" + $argList[1]).Trim()
    $arg3 = ("" + $argList[2]).Trim()
    $arg4 = ""
    if ($argList.Count -ge 4 -and $null -ne $argList[3]) { $arg4 = ("" + $argList[3]).Trim() }
    if ([string]::IsNullOrWhiteSpace($arg1)) { throw "ARGUMENT_1 (base64 username:password) is required" }
    if ([string]::IsNullOrWhiteSpace($arg2)) { throw "ARGUMENT_2 (FMC host) is required" }
    if ([string]::IsNullOrWhiteSpace($arg3)) { throw "ARGUMENT_3 (certificate object name) is required" }

    # Credentials (base64 username:password)
    try { $decodedCreds = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($arg1)) }
    catch { throw "ARGUMENT_1 is not valid base64. Encode 'username:password' as base64 before passing it as this argument." }
    $colon = $decodedCreds.IndexOf(":")
    if ($colon -lt 1) { throw "Decoded ARGUMENT_1 has no ':' separator. Expected base64(username:password)" }
    $fmcUser = $decodedCreds.Substring(0, $colon)
    $fmcPass = $decodedCreds.Substring($colon + 1)
    if ([string]::IsNullOrEmpty($fmcPass)) { throw "Decoded ARGUMENT_1 has an empty password" }
    Register-Secret $fmcPass
    Register-Secret $arg1
    Write-Log "ARGUMENT_1 decoded - Username: '$fmcUser', Password: ********"
    Write-Log "ARGUMENT_2 (FMC host): $arg2"
    Write-Log "ARGUMENT_3 (certificate name): $arg3"
    Write-Log "ARGUMENT_4 (options): $(if ($arg4) { $arg4 } else { '(empty)' })"

    # Options (ARGUMENT_4)
    $knownOptions = @("SKIP_TLS_VALIDATION", "DRY_RUN", "NAME_MODE", "DOMAIN_UUID", "LOGFILE")
    $opts = @{}
    if ($arg4) {
        foreach ($pair in $arg4.Split(";")) {
            $pr = $pair.Trim()
            if (-not $pr) { continue }
            $i = $pr.IndexOf("=")
            if ($i -lt 1) { Write-Log "WARNING: Ignoring malformed option '$pr' (expected KEY=VALUE)"; continue }
            $k = $pr.Substring(0, $i).Trim().ToUpperInvariant()
            $v = $pr.Substring($i + 1).Trim()
            if ($knownOptions -notcontains $k) { Write-Log "WARNING: Unknown option '$k' ignored"; continue }
            $opts[$k] = $v
        }
    }
    if ($opts.ContainsKey("LOGFILE") -and $opts["LOGFILE"]) {
        $script:LOGFILE = $opts["LOGFILE"]
        try {
            $dir = Split-Path -Path $script:LOGFILE -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [System.IO.File]::AppendAllText($script:LOGFILE, (($script:LogBuffer -join "`r`n") + "`r`n"), $script:Utf8NoBom)
        }
        catch { }
        Write-Log "LOGFILE: $($script:LOGFILE) (lines from the start of this run copied in)"
    }
    $skipTls = ConvertTo-Bool $opts["SKIP_TLS_VALIDATION"] $false
    $dryRun  = ConvertTo-Bool $opts["DRY_RUN"] $false
    $nameMode = "timestamp"
    if ($opts.ContainsKey("NAME_MODE") -and $opts["NAME_MODE"]) { $nameMode = $opts["NAME_MODE"].ToLowerInvariant() }
    if (@("timestamp", "exact", "replace") -notcontains $nameMode) { throw "NAME_MODE must be 'timestamp', 'exact' or 'replace'" }
    $domainOverride = ""
    if ($opts.ContainsKey("DOMAIN_UUID")) { $domainOverride = $opts["DOMAIN_UUID"] }
    Write-Log "Resolved options: SKIP_TLS_VALIDATION=$skipTls DRY_RUN=$dryRun NAME_MODE=$nameMode DOMAIN_UUID=$(if ($domainOverride) { $domainOverride } else { '(from login)' })"

    # Files and key passphrase
    $certFolder = $null
    foreach ($k in @("certfolder", "cert_folder", "certFolder")) {
        if ($certInfo.PSObject.Properties[$k] -and $certInfo.$k) { $certFolder = "" + $certInfo.$k; break }
    }
    if (-not $certFolder) { throw "Certificate folder not found in DC1_POST_SCRIPT_DATA" }
    $files = @()
    if ($certInfo.PSObject.Properties["files"] -and $certInfo.files) { $files = @($certInfo.files) }
    Write-Log "CERT_FOLDER: $certFolder"
    Write-Log "Files array: $($files -join ', ')"

    $keyPassphrase = ""
    foreach ($k in @("password", "pfx_password", "keystore_password", "passphrase")) {
        if ($certInfo.PSObject.Properties[$k] -and $certInfo.$k) { $keyPassphrase = "" + $certInfo.$k; Write-Log "Key passphrase found in payload field '$k' (length: $($keyPassphrase.Length))"; break }
    }
    Register-Secret $keyPassphrase

    # -------------------------------------------------------------------------
    # S02 Certificate and key
    # -------------------------------------------------------------------------
    Write-Banner "Starting certificate validation..."
    $pemFiles = @($files | Where-Object { $_ -match '\.(pem|crt|cer|key)$' })
    if ($pemFiles.Count -eq 0) {
        throw "No PEM files (.pem/.crt/.cer/.key) in the TLM delivery ($($files -join ', ')). Set the TLM AWR delivery format to PEM."
    }

    $certBlocks = New-Object System.Collections.ArrayList
    $keyPem = $null
    $keyFileName = $null
    foreach ($f in $pemFiles) {
        $path = Join-Path $certFolder $f
        if (-not (Test-Path -LiteralPath $path)) { Write-Log "WARNING: Listed file not found on disk: $path"; continue }
        $content = Get-Content -LiteralPath $path -Raw
        $blocks = [regex]::Matches($content, '(?s)-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----')
        foreach ($b in $blocks) { [void]$certBlocks.Add($b.Value.Trim()) }
        if (-not $keyPem) {
            $km = [regex]::Match($content, '(?s)-----BEGIN (ENCRYPTED |RSA |EC )?PRIVATE KEY-----.*?-----END (ENCRYPTED |RSA |EC )?PRIVATE KEY-----')
            if ($km.Success) { $keyPem = $km.Value.Trim(); $keyFileName = $f }
        }
        Write-Log "File ${f}: $($blocks.Count) certificate block(s), private key: $(if ($keyFileName -eq $f) { 'yes' } else { 'no' })"
    }
    if ($certBlocks.Count -eq 0) { throw "No PEM certificate block found in the delivered files" }
    if (-not $keyPem) { throw "No PEM private key block found in the delivered files" }

    # Pick the leaf: the certificate that is not the issuer of any other certificate in the delivery
    $parsed = New-Object System.Collections.ArrayList
    foreach ($b in $certBlocks) { [void]$parsed.Add([pscustomobject]@{ Pem = $b; Cert = (ConvertFrom-PemCertificate $b) }) }
    foreach ($pc in $parsed) { [void]$script:AllCerts.Add($pc.Cert) }
    $leafEntry = $null
    foreach ($pc in $parsed) {
        $isIssuerOfOther = $false
        foreach ($other in $parsed) {
            if ($other -ne $pc -and $other.Cert.Issuer -eq $pc.Cert.Subject -and $other.Cert.Subject -ne $other.Cert.Issuer) { $isIssuerOfOther = $true }
        }
        if (-not $isIssuerOfOther -and $pc.Cert.Subject -ne $pc.Cert.Issuer) { $leafEntry = $pc; break }
    }
    if (-not $leafEntry) { $leafEntry = $parsed[0] }
    $script:LeafCert = $leafEntry.Cert
    $certPem = $leafEntry.Pem
    if ($parsed.Count -gt 1) {
        Write-Log "NOTE: $($parsed.Count) certificates in the delivery; only the leaf certificate is sent to FMC. Import the issuing CA chain into FMC separately if it is not already trusted."
    }

    $leaf = $script:LeafCert
    $san = ($leaf.Extensions | Where-Object { $_.Oid.Value -eq "2.5.29.17" } | ForEach-Object { $_.Format($false) }) -join "; "
    Write-Log "Certificate subject: $($leaf.Subject)"
    Write-Log "Certificate issuer: $($leaf.Issuer)"
    Write-Log "Certificate serial: $($leaf.SerialNumber)"
    Write-Log "Certificate thumbprint: $($leaf.Thumbprint)"
    Write-Log "Certificate valid from: $($leaf.NotBefore)"
    Write-Log "Certificate valid to: $($leaf.NotAfter)"
    Write-Log "Certificate SANs: $san"
    Write-Log "Public key algorithm: $($leaf.PublicKey.Oid.FriendlyName)"
    if ($leaf.NotAfter -le (Get-Date)) { throw "Certificate expired on $($leaf.NotAfter)" }
    if ($leaf.NotBefore -gt (Get-Date)) { Write-Log "WARNING: Certificate is not yet valid (NotBefore $($leaf.NotBefore)) - check clock skew" }

    $keyEncrypted = ($keyPem -match "BEGIN ENCRYPTED PRIVATE KEY") -or ($keyPem -match "Proc-Type:\s*4,ENCRYPTED")
    Write-Log "Private key found in $keyFileName (encrypted: $keyEncrypted)"
    if ($keyEncrypted -and [string]::IsNullOrEmpty($keyPassphrase)) {
        throw "The delivered private key is encrypted but no passphrase was found in DC1_POST_SCRIPT_DATA. Set 'Password for certificate files' on the TLM AWR destination."
    }
    if (-not $keyEncrypted -and $keyPassphrase) {
        Write-Log "NOTE: Private key is not encrypted; passPhrase will not be sent to FMC."
    }

    # Object name
    $certName = $arg3
    if ($nameMode -eq "timestamp") { $certName = "$arg3-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    Write-Log "FMC certificate object name: $certName (NAME_MODE=$nameMode)"
    Write-Log "Certificate validation section completed"

    if ($dryRun) {
        Write-Banner "DRY_RUN=true - delivery validated, no FMC calls made"
        Write-Log "Would create Internal Certificate '$certName' on $arg2 (cert $($certPem.Length) chars, key $($keyPem.Length) chars, passPhrase sent: $($keyEncrypted))"
        throw "DRY_RUN_COMPLETE"
    }

    # -------------------------------------------------------------------------
    # S03 TLS / transport
    # -------------------------------------------------------------------------
    Write-Banner "Starting FMC REST API integration..."
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($skipTls) { $script:SkipCert = @{ SkipCertificateCheck = $true } }
    }
    elseif ($skipTls) {
        if (-not ("TrustAllCertsPolicy" -as [type])) {
            Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) {
        return true;
    }
}
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
    if ($skipTls) {
        Write-Log "WARNING: SKIP_TLS_VALIDATION=true - the FMC HTTPS certificate is NOT validated. Use for lab only."
    }
    else {
        Write-Log "FMC HTTPS certificate will be validated against this host's trust store."
    }

    # Offer TLS 1.3 + 1.2 (15360 = Tls13 12288 + Tls12 3072); fall back to TLS 1.2 only on runtimes without TLS 1.3
    $tlsApplied = $null
    foreach ($mask in @(15360, 3072)) {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]$mask
            $tlsApplied = [System.Net.ServicePointManager]::SecurityProtocol
            break
        }
        catch { continue }
    }
    Write-Log "TLS protocols enabled for this session: $tlsApplied"
    try { $netRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release } catch { $netRelease = $null }
    Write-Log ".NET Framework Release key: $netRelease (378389 = 4.5, 394802 = 4.6.2, 528040 = 4.8)"
    if ($PSVersionTable.PSVersion.Major -lt 6 -and -not (([int]$tlsApplied) -band 3072)) {
        Write-Log "WARNING: TLS 1.2 could not be enabled on this host. FMC 7.x requires TLS 1.2+, so the connection will fail. Upgrade .NET Framework (4.6.2 or later) or run under PowerShell 7+."
    }

    if ($arg2 -match '^https?://') { $baseUrl = $arg2.TrimEnd("/") } else { $baseUrl = "https://$arg2" }
    Write-Log "FMC base URL: $baseUrl"

    # -------------------------------------------------------------------------
    # S04 Authenticate
    # -------------------------------------------------------------------------
    Write-Banner "Step 1: Authenticating to FMC..."
    $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("${fmcUser}:${fmcPass}"))
    $auth = Invoke-FmcRequest -Operation "FMC authentication" -Method "POST" -Url "$baseUrl/api/fmc_platform/v1/auth/generatetoken" -Headers @{ Authorization = "Basic $basic" }
    if (-not $auth.Success) {
        if ($auth.Status -eq 0 -and $auth.Error) {
            if ($auth.Error -match "trust|certificate|SSL|TLS|secure channel") {
                Write-Log "HINT: TLS/connection failure. If the FMC uses a self-signed or internal-CA certificate, trust it on this host or set SKIP_TLS_VALIDATION=true (lab only). If the error mentions 'secure channel', check TLS 1.2 support on this host (see .NET Framework Release key above)."
            }
        }
        elseif ($auth.Status -eq 401) { Write-Log "HINT: HTTP 401 - check the FMC username/password in ARGUMENT_1 and that the account has API access." }
        throw "FMC authentication failed (HTTP $($auth.Status))"
    }
    $accessToken = Get-HeaderValue $auth.Headers "X-auth-access-token"
    if (-not $accessToken) { throw "FMC did not return X-auth-access-token" }
    Register-Secret $accessToken
    $domainUuid = $domainOverride
    if (-not $domainUuid) { $domainUuid = Get-HeaderValue $auth.Headers "DOMAIN_UUID" }
    if (-not $domainUuid) { throw "FMC did not return DOMAIN_UUID. Set DOMAIN_UUID=<uuid> in ARGUMENT_4." }
    Write-Log "SUCCESS: Authenticated. Domain UUID: $domainUuid"

    # -------------------------------------------------------------------------
    # S05 Create the Internal Certificate object
    # -------------------------------------------------------------------------
    $certUrl = "$baseUrl/api/fmc_config/v1/domain/$domainUuid/object/internalcertificates"
    $fmcHeaders = @{ "X-auth-access-token" = $accessToken }
    $handled = $false

    $deleted = $false
    if ($nameMode -eq "replace") {
        Write-Banner "Step 2: Looking for an existing Internal Certificate object named '$certName'..."
        $existingId = ""
        $offset = 0
        for ($page = 0; $page -lt 50 -and -not $existingId; $page++) {
            $list = Invoke-FmcRequest -Operation "List Internal Certificates" -Method "GET" -Url "${certUrl}?offset=$offset&limit=1000" -Headers $fmcHeaders
            if (-not $list.Success) { throw "Could not list Internal Certificates (HTTP $($list.Status)). Nothing was changed." }
            $items = @()
            if ($list.Json -and $list.Json.PSObject.Properties["items"]) { $items = @($list.Json.items) }
            foreach ($it in $items) { if ($it.name -eq $certName) { $existingId = "" + $it.id; break } }
            $hasNext = $false
            if ($list.Json -and $list.Json.PSObject.Properties["paging"] -and $list.Json.paging.PSObject.Properties["next"] -and $list.Json.paging.next) { $hasNext = $true }
            if (-not $hasNext) { break }
            $offset += 1000
        }

        if ($existingId) {
            Write-Log "Existing object found: '$certName' (id $existingId). It will be deleted and re-created with the new certificate and key."
            Write-Banner "Step 3: Deleting existing object '$certName'..."
            $del = Invoke-FmcRequest -Operation "Delete Internal Certificate" -Method "DELETE" -Url "$certUrl/$existingId" -Headers $fmcHeaders
            if (-not $del.Success) {
                if ($del.Status -eq 400 -or $del.Status -eq 409 -or $del.Status -eq 422) { Write-Log "HINT: FMC refused the delete. The object is probably in use by a policy or configuration. Nothing was changed and no new object was created." }
                elseif ($del.Status -eq 401 -or $del.Status -eq 403) { Write-Log "HINT: The FMC account is not permitted to delete certificate objects." }
                throw "FMC would not delete the existing object (HTTP $($del.Status)). Nothing was changed."
            }
            $deleted = $true
            Write-Log "Existing object '$certName' (id $existingId) deleted."
        }
        else {
            Write-Log "No existing object named '$certName'. Creating it."
        }
    }

    if (-not $handled) {
    Write-Banner "Step 2: Creating Internal Certificate object '$certName'..."
    $body = [ordered]@{ name = $certName; cert = $certPem; privateKey = $keyPem; type = "InternalCertificate" }
    if ($keyEncrypted) { $body["passPhrase"] = $keyPassphrase }
    $bodyJson = $body | ConvertTo-Json -Depth 5

    $certUrl = "$baseUrl/api/fmc_config/v1/domain/$domainUuid/object/internalcertificates"
    $create = Invoke-FmcRequest -Operation "Create Internal Certificate" -Method "POST" -Url $certUrl -Headers @{ "X-auth-access-token" = $accessToken } -Body $bodyJson
    if (-not $create.Success) {
        if ($create.Status -eq 422 -or $create.Status -eq 400) {
            Write-Log "HINT: FMC rejected the request. Common causes: an object named '$certName' already exists (use NAME_MODE=timestamp), the key does not match the certificate, or the passphrase is wrong. See the FMC response above."
        }
        elseif ($create.Status -eq 401 -or $create.Status -eq 403) { Write-Log "HINT: The FMC account is not permitted to create certificate objects." }
        if ($deleted) { Write-Log "ERROR: The previous object '$certName' was already DELETED and the new one could NOT be created. FMC currently has no object named '$certName'. Fix the cause above and run the script again, or re-import the certificate manually." }
        throw "FMC certificate import failed (HTTP $($create.Status))"
    }
    $newId = ""
    if ($create.Json -and $create.Json.PSObject.Properties["id"]) { $newId = "" + $create.Json.id }
    Write-Log "SUCCESS: Internal Certificate object created. FMC object id: $newId"
    }

    # -------------------------------------------------------------------------
    # S06 Verify
    # -------------------------------------------------------------------------
    if ($newId) {
        $verify = Invoke-FmcRequest -Operation "Verify Internal Certificate" -Method "GET" -Url "$certUrl/$newId" -Headers @{ "X-auth-access-token" = $accessToken }
        if ($verify.Success -and $verify.Json) {
            foreach ($fld in @("name", "subjectCommonName", "issuerCommonName", "validityEndDate")) {
                if ($verify.Json.PSObject.Properties[$fld]) { Write-Log "  FMC object $fld`: $($verify.Json.$fld)" }
            }
            if ($verify.Json.PSObject.Properties["name"] -and $verify.Json.name -ne $certName) {
                Write-Log "WARNING: FMC object name '$($verify.Json.name)' differs from the requested '$certName'"
            }
        }
        else {
            Write-Log "WARNING: Could not read the new object back from FMC (HTTP $($verify.Status)); the create call itself succeeded."
        }
    }
    Write-Log "NOTE: The certificate now exists as an Internal Certificate object in FMC. Assigning it to a device, VPN or SSL policy and deploying is a separate step."
}
catch {
    if ($_.Exception.Message -eq "DRY_RUN_COMPLETE") {
        # normal end of a dry run
    }
    elseif ($_.Exception.Message -ne "LEGAL_NOTICE_NOT_ACCEPTED") {
        Write-Log "ERROR: $($_.Exception.Message)"
        $script:ExitCode = 1
    }
}
finally {
    foreach ($c in $script:AllCerts) { try { $c.Reset() } catch { } }
    try { [System.Net.ServicePointManager]::CertificatePolicy = $null } catch { }
    if ($script:ExitCode -eq 0) { Write-Banner "Script execution completed successfully" }
    else { Write-Banner "Script execution completed with errors (exit code 1)" }
}
exit $script:ExitCode
