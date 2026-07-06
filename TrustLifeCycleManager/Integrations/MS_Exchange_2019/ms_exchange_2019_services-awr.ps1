<#
Legal Notice (version January 1, 2026)
Copyright © 2026 DigiCert. All rights reserved.
DigiCert and its logo are registered trademarks of DigiCert, Inc.
Other names may be trademarks of their respective owners.
For the purposes of this Legal Notice, "DigiCert" refers to:
- DigiCert, Inc., if you are located in the United States;
- DigiCert Ireland Limited, if you are located outside of the United States or Japan;
- DigiCert Japan G.K., if you are located in Japan.
The software described in this notice is provided by DigiCert and distributed under licenses restricting its use, copying, distribution, and decompilation or reverse engineering. No part of the software may be reproduced in any form by any means without prior written authorization of DigiCert and its licensors, if any.
Use of the software is subject to the terms and conditions of your agreement with DigiCert, including any dispute resolution and applicable law provisions. The terms set out herein are supplemental to your agreement and, in the event of conflict, these terms control.
THE SOFTWARE IS PROVIDED "AS IS" AND ALL EXPRESS OR IMPLIED CONDITIONS, REPRESENTATIONS AND WARRANTIES, INCLUDING ANY IMPLIED WARRANTY OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE OR NON-INFRINGEMENT, ARE DISCLAIMED, EXCEPT TO THE EXTENT THAT SUCH DISCLAIMERS ARE HELD TO BE LEGALLY INVALID.
Export Regulation: The software and related technical data and services (collectively "Controlled Technology") are subject to the import and export laws of the United States, specifically the U.S. Export Administration Regulations (EAR), and the laws of any country where Controlled Technology is imported or re-exported.
US Government Restricted Rights: The software is provided with "Restricted Rights," Use, duplication, or disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software—Restricted Rights at 48 CFR 52.227-19, as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any successor regulations.
The contractor/manufacturer is DIGICERT, INC.
#>

# DigiCert TLM Agent Post-Script: Exchange 2019 Certificate Replacement
# Drop into: C:\Program Files\DigiCert\TLM Agent\user-scripts\
# Logs to:   C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log

# Legal notice acceptance variable
$legal_notice_accept = $false  # Set to true to accept and execute script, false to deny

$ErrorActionPreference = "Stop"

# ── Config ────────────────────────────────────────────────────────────────────
# All environment-specific settings live here so the rest of the script needs no edits.
$LogFilePath      = "C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log"
# Exchange 2013/2016/2019 install under the "V15" path regardless of the marketing year.
$ExchangeShellPsc = "C:\Program Files\Microsoft\Exchange Server\V15\bin\exshell.psc1"
# Services the certificate is bound to via Enable-ExchangeCertificate. Comma-separated,
# no spaces (the value is passed verbatim to the -Services parameter). Drop any service
# you don't want the cert enabled for (e.g. "IIS,SMTP").
$ExchangeServices = "POP,IMAP,IIS,SMTP"

# IIS SSL bindings to (re)point at the new certificate. Default Exchange 2019 layout:
#   Default Web Site  -> 443 (client-facing: OWA, ECP, EWS, ActiveSync, Autodiscover)
#   Exchange Back End -> 444 (internal back-end services)
$IISSiteBindings = @{
    "Default Web Site"  = 443
    "Exchange Back End" = 444
}

# ── Logging (matches sample script pattern exactly) ───────────────────────────
function Log-Message {
    param (
        [string]$message,
        [string]$logFilePath = "C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp : $message"
    Add-Content -Path $logFilePath -Value $logEntry
    Write-Host $message
}

# ── Base64 decode (matches sample script pattern exactly) ─────────────────────
function Decode-Base64 {
    param (
        [string]$base64String
    )
    $bytes = [System.Convert]::FromBase64String($base64String)
    $decodedString = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $decodedString
}

# ── STEP 1: Decode DC1_POST_SCRIPT_DATA and extract fields ────────────────────
Log-Message "DigiCert TLM Post-Script starting..."

# Check legal notice acceptance
if ($legal_notice_accept -eq $false) {
    Log-Message "Legal notice acceptance is set to false - script execution denied"
    Log-Message "Script execution stopped - legal notice not accepted"
    exit 0
}

Log-Message "Legal notice accepted - proceeding with script execution"

$base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")

if ([string]::IsNullOrEmpty($base64Json)) {
    Log-Message "ERROR: DC1_POST_SCRIPT_DATA is empty. Ensure this is configured as a Post-Script in TLM Agent."
    exit 1
}

try {
    $jsonString = Decode-Base64 -base64String $base64Json
    Log-Message "Decoded JSON: $jsonString"

    $jsonObject = $jsonString | ConvertFrom-Json
    Log-Message "Arguments: $($jsonObject.args)"
} catch {
    Log-Message "ERROR: Failed to decode DC1_POST_SCRIPT_DATA. $_"
    exit 1
}

# Extract values from JSON - password comes from the DigiCert UI PKCS12 field
$certFolder  = $jsonObject.certfolder
$pfxFileName = $jsonObject.files[0]
$pfxPassword = $jsonObject.password
$pfxFilePath = Join-Path -Path $certFolder -ChildPath $pfxFileName

Log-Message "Cert folder : $certFolder"
Log-Message "PFX file    : $pfxFileName"
Log-Message "PFX path    : $pfxFilePath"

if (-not (Test-Path -Path $pfxFilePath)) {
    Log-Message "ERROR: PFX file not found: $pfxFilePath"
    exit 1
}

# ── STEP 2: Extract CN and create versioned archive folder ────────────────────
# The archive folder keeps a timestamped copy of every deployed PFX, giving an audit
# trail and a rollback source if a renewal needs to be reverted.
try {
    $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $pfxFilePath,
        $pfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
    )
    # Pull just the CN value out of the full subject DN (e.g. "CN=mail.contoso.com, O=Contoso" -> "mail.contoso.com").
    $commonName = ($x509.Subject -replace "^CN=([^,]+).*", '$1').Trim()
    Log-Message "Certificate CN      : $commonName"
    Log-Message "Certificate Expires : $($x509.NotAfter)"
} catch {
    # A bad password or unreadable PFX shouldn't abort the run here; fall back to the
    # file name for the archive folder and let STEP 3's import surface the real error.
    Log-Message "WARNING: Could not read CN from PFX, using filename. $_"
    $commonName = [System.IO.Path]::GetFileNameWithoutExtension($pfxFileName)
}

$timestamp  = Get-Date -Format "yyyy_MM_dd_HH_mm_ss"
$folderName = "${commonName}_pfx_${timestamp}"
$archiveDir = Join-Path -Path $certFolder -ChildPath $folderName

try {
    New-Item -ItemType Directory -Path $archiveDir -Force | Out-Null
    Copy-Item -Path $pfxFilePath -Destination (Join-Path $archiveDir $pfxFileName)
    Log-Message "Archive folder created: $archiveDir"
} catch {
    Log-Message "ERROR: Could not create archive folder. $_"
    exit 1
}

# ── STEP 3: Import PFX into LocalMachine\My ───────────────────────────────────
try {
    $pfxSecure = ConvertTo-SecureString -String $pfxPassword -Force -AsPlainText

    # -Exportable keeps the private key exportable so the cert can later be moved to
    # another host or re-exported for backup. Drop this flag to harden the key against export.
    $cert = Import-PfxCertificate `
        -FilePath          $pfxFilePath `
        -CertStoreLocation Cert:\LocalMachine\My `
        -Password          $pfxSecure `
        -Exportable

    if ($null -eq $cert) {
        throw "Import-PfxCertificate returned null."
    }

    $thumbprint = $cert.Thumbprint
    Log-Message "Certificate imported successfully. Thumbprint: $thumbprint"
} catch {
    Log-Message "ERROR: Failed to import the certificate. $_"
    exit 1
}

# ── STEP 4: Enable cert for Exchange services via child process ───────────────
# Exchange snap-in cannot load in the same process as TLM Agent.
# Child script lines are written with Set-Content (no here-strings) to avoid
# brace/syntax corruption that caused the previous parse errors.

$tempScriptPath = Join-Path $env:TEMP ("EnableExchangeCert_" + [Guid]::NewGuid().ToString() + ".ps1")

$childLines = @(
    "function Log-Message {",
    "    param([string]`$message)",
    "    `$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'",
    "    Add-Content -Path '$LogFilePath' -Value (`"`$timestamp [CHILD] `$message`")",
    "}",
    "try {",
    "    Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop",
    "    Log-Message 'Exchange snap-in loaded.'",
    "    `$ErrorActionPreference = 'Stop'",
    "    Enable-ExchangeCertificate -Thumbprint '$thumbprint' -Services $ExchangeServices -Confirm:`$false -Force -ErrorAction Stop",
    "    Log-Message 'Enable-ExchangeCertificate succeeded. Thumbprint: $thumbprint'",
    "    exit 0",
    "} catch {",
    "    Log-Message `"ERROR in Enable-ExchangeCertificate: `$_`"",
    "    if (`$_.Exception.Message -like '*KeyAlgorithmUnsupported*') {",
    "        Log-Message 'CRITICAL: Certificate uses an unsupported key algorithm for Exchange.'",
    "    }",
    "    exit 1",
    "}"
)

Set-Content -Path $tempScriptPath -Value $childLines -Encoding UTF8
Log-Message "Temporary Exchange script written to: $tempScriptPath"

try {
    if (Test-Path $ExchangeShellPsc) {
        Log-Message "Running child process via Exchange Management Shell PSC..."
        $process = Start-Process powershell.exe `
            -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-Command & {Import-Module '$ExchangeShellPsc'; & '$tempScriptPath'}" `
            -Wait -PassThru
    } else {
        Log-Message "WARNING: exshell.psc1 not found, falling back to direct snap-in load."
        $process = Start-Process powershell.exe `
            -ArgumentList "-NoProfile", "-ExecutionPolicy Bypass", "-File", $tempScriptPath `
            -Wait -PassThru
    }

    if ($process.ExitCode -ne 0) {
        throw "Exchange enablement child process exited with code $($process.ExitCode)."
    }

    Log-Message "Exchange certificate enabling process completed successfully."

} catch {
    Log-Message "ERROR: Failed during Exchange cert enablement. $_"
    if (Test-Path $tempScriptPath) {
        Remove-Item -Path $tempScriptPath -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

if (Test-Path $tempScriptPath) {
    Remove-Item -Path $tempScriptPath -Force -ErrorAction SilentlyContinue
}

# ── STEP 5: Update IIS SSL bindings ───────────────────────────────────────────
try {
    Import-Module WebAdministration -ErrorAction Stop
    Log-Message "WebAdministration module loaded."
} catch {
    Log-Message "ERROR: Failed to load WebAdministration module. $_"
    exit 1
}

foreach ($siteName in $IISSiteBindings.Keys) {
    $port = $IISSiteBindings[$siteName]
    Log-Message "Processing IIS site '$siteName' on port $port..."

    $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
    if (-not $site) {
        Log-Message "WARNING: IIS site '$siteName' not found, skipping."
        continue
    }

    $binding = Get-WebBinding -Name $siteName -Protocol https | Where-Object { $_.bindingInformation -like "*:${port}:*" }

    if (-not $binding) {
        Log-Message "WARNING: No HTTPS binding on port $port for '$siteName'. Creating binding."
        New-WebBinding -Name $siteName -Protocol https -Port $port -IPAddress "*" -SslFlags 0
        $binding = Get-WebBinding -Name $siteName -Protocol https | Where-Object { $_.bindingInformation -like "*:${port}:*" }
    }

    try {
        $binding.AddSslCertificate($thumbprint, "My")
        Log-Message "IIS '$siteName':$port bound to thumbprint $thumbprint"
    } catch {
        Log-Message "ERROR: Failed to bind cert to IIS '$siteName':$port. $_"
        exit 1
    }
}

# ── STEP 6: Restart services ──────────────────────────────────────────────────
# Exchange and IIS pick up the new certificate binding only after their services
# recycle. Restart failures are logged as warnings, not fatal — a manual restart
# can complete the rollout without re-running the whole script.
Log-Message "Restarting IIS..."
try {
    # /noforce lets in-flight requests drain instead of being killed mid-request.
    & iisreset /restart /noforce | Out-Null
    Log-Message "IIS restarted successfully."
} catch {
    Log-Message "WARNING: IIS restart failed. $_"
}

foreach ($svc in @("MSExchangeTransport", "MSExchangeImap4", "MSExchangePop3")) {
    try {
        Restart-Service $svc -Force -ErrorAction Stop
        Log-Message "$svc restarted successfully."
    } catch {
        Log-Message "WARNING: $svc restart failed (may not be running). $_"
    }
}

# ── STEP 7: Verify IIS bindings via netsh ─────────────────────────────────────
# Post-restart sanity check: confirm the HTTP.sys SSL binding actually resolves to
# the new thumbprint. This catches cases where the IIS binding was set but the
# underlying HTTP.sys registration didn't update.
Log-Message "Verifying IIS SSL bindings..."

foreach ($siteName in $IISSiteBindings.Keys) {
    $port = $IISSiteBindings[$siteName]
    try {
        # 0.0.0.0:$port is the HTTP.sys wildcard binding IIS registers for "*:port:".
        # netsh reports the thumbprint in lowercase, so the comparison below lowercases too.
        $netshOut = (& netsh http show sslcert ipport="0.0.0.0:$port" 2>&1) | Out-String
        if ($netshOut -match $thumbprint.ToLower()) {
            Log-Message "VERIFIED: '$siteName':$port is using the correct certificate."
        } else {
            Log-Message "WARNING: '$siteName':$port thumbprint mismatch. Check IIS bindings manually."
        }
    } catch {
        Log-Message "WARNING: Could not verify '$siteName':$port. $_"
    }
}

# ── Done ──────────────────────────────────────────────────────────────────────
Log-Message "COMPLETE: Certificate replacement finished. CN=$commonName Thumbprint=$thumbprint Archive=$archiveDir"
exit 0