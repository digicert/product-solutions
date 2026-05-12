<#
Legal Notice (version January 1, 2026)
Copyright (c) 2026 DigiCert. All rights reserved.
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
US Government Restricted Rights: The software is provided with "Restricted Rights." Use, duplication, or
disclosure by the U.S. Government is subject to restrictions as set forth in subparagraph (c)(1)(ii) of the
Rights in Technical Data and Computer Software clause at DFARS 252.227-7013,
subparagraphs (c)(1) and (2) of the Commercial Computer Software-Restricted Rights at 48 CFR 52.227-19,
as applicable, and the Technical Data - Commercial Items clause at DFARS 252.227-7015 (Nov 1995) and any
successor regulations. The contractor/manufacturer is DIGICERT, INC.
#>

# =============================================================================
# DigiCert Trust Lifecycle Manager (TLM) -- AWR Post-Enrollment Script
# Palo Alto Panorama Certificate Upload
#
# Uploads a PEM certificate + private key to Palo Alto Panorama via the
# PAN-OS XML API. Designed to run non-interactively as a TLM AWR
# post-enrollment script. All configuration is via DC1_POST_SCRIPT_DATA
# arguments or the variables below.
#
# Supports two modes (set via MODE variable below):
#
#   template  - Uploads to a Panorama device template, commits, and pushes
#               to all firewalls in the template stack. Use for GlobalProtect,
#               SSL Decryption, LDAP, Captive Portal, IPSec, etc.
#
#   system    - Uploads directly to Panorama itself. Use for the Panorama
#               management UI certificate, syslog, SNMP, etc.
#
# The Common Name is extracted automatically from the certificate and used
# for discovery unless Argument 3 provides an explicit certificate name.
# If a certificate with the same CN already exists it is updated in place
# (preserving any bindings such as SSL/TLS profiles, GP portals, etc.)
#
# IMPORTANT: The cert file delivered by TLM must contain only the leaf
#            certificate (single PEM block). If the file contains a full
#            chain, only the first certificate (leaf) is used for CN
#            extraction, but upload may fail. Configure TLM to deliver
#            the leaf certificate separately.
#
# Requires: PowerShell 7.0 or later (for -Form and -SkipCertificateCheck
#           support on Invoke-WebRequest).
#
# DC1_POST_SCRIPT_DATA Arguments (configured in TLM AWR):
#   Argument 1 : Panorama IP address or FQDN
#   Argument 2 : Panorama credentials in the format username:password
#                (password may contain colons)
#   Argument 3 : Certificate name override (optional)
#                If provided, the script targets this exact certificate name
#                in Panorama and skips CN-based discovery entirely.
#                If omitted, CN-based discovery is used. Discovery will fail
#                with an error if multiple certificates share the same CN --
#                in which case set this argument to resolve the ambiguity.
#   Argument 4 : Panorama Template Name  (used in 'template' mode)
#   Argument 5 : Panorama Template Stack Name (used in 'template' mode)
#
# =============================================================================

# =============================================================================
# CONFIGURATION -- edit these variables as needed
# =============================================================================

# Legal notice gate -- set to $true to accept the DigiCert legal notice above.
# The script will not run until this is set.
$LegalNoticeAccept = $false

# Mode: 'template' or 'system'
#   template -- Upload cert to a Panorama device template, commit to Panorama,
#              then push the template stack to all managed firewalls. Use this
#              when the certificate is consumed by firewalls (GlobalProtect,
#              SSL Decryption, LDAP, Captive Portal, IPSec, etc.)
#   system   -- Upload cert directly to Panorama's own certificate store and
#              commit. No push to firewalls. Use this when the certificate is
#              for Panorama itself (management UI, syslog, SNMP, etc.)
$Mode = 'system'

# Key passphrase -- The PAN-OS import API requires a passphrase parameter even
# when the private key is not encrypted. This value is used as a storage
# passphrase on the PAN-OS side. It is NOT the encryption passphrase of the
# key file delivered by TLM (which is unencrypted PEM). Set this to any
# non-empty string; it acts as a placeholder required by the API.
$KeyPassphrase = 'ChangeMe123!'

# Seconds to wait between job-status polling requests when monitoring
# Panorama commit and push operations.
$WaitSeconds = 10

# Log file location -- parent directories are created automatically if absent.
$Logfile = 'C:\DigiCert\panorama.log'

# =============================================================================
# END OF CONFIGURATION
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Ensure log directory exists ---------------------------------------------
$LogDir = Split-Path -Parent $Logfile
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# --- Logging helper ----------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] $Message"
    Add-Content -Path $Logfile -Value $line
}

# --- URL-encoding helper -----------------------------------------------------
# Use [uri]::EscapeDataString -- built into .NET Core, no System.Web required,
# and percent-encodes everything that needs escaping in a query-string value
# (including reserved chars like &, =, +, /, ?, #, space, [, ], ', etc.)
function ConvertTo-UrlEncoded {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return [uri]::EscapeDataString($Value)
}

# --- Start logging -----------------------------------------------------------
Write-Log '=========================================='
Write-Log 'Panorama Certificate Upload -- AWR Post-Enrollment Script'
Write-Log '=========================================='

# --- Legal notice gate -------------------------------------------------------
Write-Log 'Checking legal notice acceptance...'
if (-not $LegalNoticeAccept) {
    Write-Log 'ERROR: Legal notice not accepted. Set $LegalNoticeAccept = $true to proceed.'
    Write-Log 'Script execution terminated.'
    Write-Log '=========================================='
    exit 1
}
Write-Log 'Legal notice accepted, proceeding.'

# --- Log configuration -------------------------------------------------------
Write-Log 'Configuration:'
Write-Log "  MODE: $Mode"
Write-Log '  KEY_PASSPHRASE: ********'
Write-Log "  WAIT_SECONDS: $WaitSeconds"
Write-Log "  LOGFILE: $Logfile"

# --- Validate mode -----------------------------------------------------------
if ($Mode -ne 'template' -and $Mode -ne 'system') {
    Write-Log "ERROR: Invalid Mode '$Mode'. Must be 'template' or 'system'."
    exit 1
}
Write-Log "Mode validated: $Mode"

# =============================================================================
# DC1_POST_SCRIPT_DATA extraction
# =============================================================================
Write-Log 'Checking DC1_POST_SCRIPT_DATA environment variable...'
$EnvData = [System.Environment]::GetEnvironmentVariable('DC1_POST_SCRIPT_DATA')
if ([string]::IsNullOrEmpty($EnvData)) {
    Write-Log 'ERROR: DC1_POST_SCRIPT_DATA environment variable is not set.'
    exit 1
}
Write-Log "DC1_POST_SCRIPT_DATA is set (length: $($EnvData.Length) characters)"

# Decode the base64-encoded JSON payload
$JsonBytes  = [System.Convert]::FromBase64String($EnvData)
$JsonString = [System.Text.Encoding]::UTF8.GetString($JsonBytes)
Write-Log 'JSON decoded successfully.'
Write-Log 'Raw JSON content:'
Write-Log $JsonString

$JsonObj = $JsonString | ConvertFrom-Json
Write-Log 'JSON parsed successfully.'

# --- Extract arguments from JSON ---------------------------------------------
Write-Log 'Extracting arguments from JSON...'

$ArgsArray = $JsonObj.args

# Argument 1 -- Panorama IP / FQDN
$PanoramaIP = if ($ArgsArray.Count -ge 1) { $ArgsArray[0].Trim() } else { '' }
Write-Log "PANORAMA_IP (Arg1): '$PanoramaIP'"

# Argument 2 -- Combined credentials in the format username:password
# Split on first colon only so passwords containing colons are handled safely.
$Arg2Credential = if ($ArgsArray.Count -ge 2) { $ArgsArray[1].Trim() } else { '' }
$ColonIndex     = $Arg2Credential.IndexOf(':')
if ($ColonIndex -lt 1) {
    Write-Log 'ERROR: Argument 2 (credentials) is not in the expected username:password format.'
    exit 1
}
$PanoramaUser = $Arg2Credential.Substring(0, $ColonIndex)
$PanoramaPass = $Arg2Credential.Substring($ColonIndex + 1)
Write-Log "PANORAMA_USER (Arg2, from credential): '$PanoramaUser'"
Write-Log 'PANORAMA_PASS (Arg2, from credential): ********'

# Argument 3 -- Certificate name override (optional)
$CertNameOverride = if ($ArgsArray.Count -ge 3) { $ArgsArray[2].Trim() } else { '' }
if (-not [string]::IsNullOrEmpty($CertNameOverride)) {
    Write-Log "CERT_NAME_OVERRIDE (Arg3): '$CertNameOverride'"
} else {
    Write-Log 'CERT_NAME_OVERRIDE (Arg3): <not set -- CN discovery will be used>'
}

# Argument 4 -- Panorama Template Name (template mode)
$TemplateName = if ($ArgsArray.Count -ge 4) { $ArgsArray[3].Trim() } else { '' }
Write-Log "TEMPLATE_NAME (Arg4): '$TemplateName'"

# Argument 5 -- Panorama Template Stack Name (template mode)
$TemplateStackName = if ($ArgsArray.Count -ge 5) { $ArgsArray[4].Trim() } else { '' }
Write-Log "TEMPLATE_STACK_NAME (Arg5): '$TemplateStackName'"

# --- Validate required arguments ---------------------------------------------
if ([string]::IsNullOrEmpty($PanoramaIP)) {
    Write-Log 'ERROR: Argument 1 (Panorama IP/FQDN) is empty.'
    exit 1
}
if ([string]::IsNullOrEmpty($PanoramaUser)) {
    Write-Log 'ERROR: Argument 2 (credentials) did not yield a username. Expected format: username:password'
    exit 1
}
if ([string]::IsNullOrEmpty($PanoramaPass)) {
    Write-Log 'ERROR: Argument 2 (credentials) did not yield a password. Expected format: username:password'
    exit 1
}
if ($Mode -eq 'template') {
    if ([string]::IsNullOrEmpty($TemplateName)) {
        Write-Log 'ERROR: Argument 4 (Template Name) is required in template mode.'
        exit 1
    }
    if ([string]::IsNullOrEmpty($TemplateStackName)) {
        Write-Log 'ERROR: Argument 5 (Template Stack Name) is required in template mode.'
        exit 1
    }
}
Write-Log 'All required arguments validated.'

# --- Extract certificate and key file paths ----------------------------------
Write-Log 'Extracting certificate file paths from JSON...'

$CertFolder  = $JsonObj.certfolder
$FilesArray  = $JsonObj.files
Write-Log "CERT_FOLDER: $CertFolder"
Write-Log "All files in array: $($FilesArray -join ', ')"

$CrtFile = $FilesArray | Where-Object { $_ -match '\.crt$' } | Select-Object -First 1
$KeyFile = $FilesArray | Where-Object { $_ -match '\.key$' } | Select-Object -First 1
Write-Log "CRT_FILE: $CrtFile"
Write-Log "KEY_FILE: $KeyFile"

$CrtFilePath = Join-Path $CertFolder $CrtFile
$KeyFilePath = Join-Path $CertFolder $KeyFile
Write-Log "Certificate path: $CrtFilePath"
Write-Log "Private key path: $KeyFilePath"

# --- Validate certificate and key files exist --------------------------------
if (-not (Test-Path $CrtFilePath)) {
    Write-Log "ERROR: Certificate file not found: $CrtFilePath"
    exit 1
}
$CrtSize = (Get-Item $CrtFilePath).Length
Write-Log "Certificate file exists: $CrtFilePath ($CrtSize bytes)"

$CrtContent  = Get-Content $CrtFilePath -Raw
$CertCount   = ([regex]::Matches($CrtContent, 'BEGIN CERTIFICATE')).Count
Write-Log "Certificates in file: $CertCount"

if (-not (Test-Path $KeyFilePath)) {
    Write-Log "ERROR: Private key file not found: $KeyFilePath"
    exit 1
}
$KeySize = (Get-Item $KeyFilePath).Length
Write-Log "Private key file exists: $KeyFilePath ($KeySize bytes)"

# Determine key type for logging
$KeyContent = Get-Content $KeyFilePath -Raw
if ($KeyContent -match 'BEGIN RSA PRIVATE KEY')    { $KeyType = 'RSA' }
elseif ($KeyContent -match 'BEGIN EC PRIVATE KEY') { $KeyType = 'ECC' }
elseif ($KeyContent -match 'BEGIN PRIVATE KEY')    { $KeyType = 'PKCS#8' }
else                                               { $KeyType = 'Unknown' }
Write-Log "Key type: $KeyType"

# =============================================================================
# Panorama Certificate Upload
# =============================================================================

# --- Extract Common Name from the certificate via .NET X509 ------------------
Write-Log '=========================================='
Write-Log 'Extracting Common Name from certificate...'

# Load only the first PEM block (leaf certificate)
$PemMatch = [regex]::Match($CrtContent, '-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----')
if (-not $PemMatch.Success) {
    Write-Log "ERROR: Could not locate a PEM certificate block in: $CrtFilePath"
    exit 1
}
$B64Payload = $PemMatch.Value -replace '-----BEGIN CERTIFICATE-----|-----END CERTIFICATE-----|\s', ''
$CertBytes  = [System.Convert]::FromBase64String($B64Payload)
$X509       = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertBytes)

# Parse CN from the Subject (e.g. "CN=example.com, O=Acme, C=US")
$SubjectParts = $X509.Subject -split ',\s*'
$CnPart       = $SubjectParts | Where-Object { $_ -match '^CN=' } | Select-Object -First 1
if ([string]::IsNullOrEmpty($CnPart)) {
    Write-Log "ERROR: Could not extract Common Name from certificate subject: $($X509.Subject)"
    exit 1
}
$CommonName = $CnPart -replace '^CN=', ''
Write-Log "Common Name: $CommonName"

# --- Display banner (to log) -------------------------------------------------
Write-Log '============================================'
Write-Log 'Panorama Certificate Upload'
Write-Log '============================================'
Write-Log "Mode:           $Mode"
Write-Log "Common Name:    $CommonName"
Write-Log "Cert File:      $CrtFilePath"
Write-Log "Key File:       $KeyFilePath"
Write-Log "Panorama:       $PanoramaIP"
Write-Log "User:           $PanoramaUser"
if (-not [string]::IsNullOrEmpty($CertNameOverride)) {
    Write-Log "Cert Name:      $CertNameOverride (explicit override -- discovery skipped)"
} else {
    Write-Log 'Cert Name:      <will be determined by CN discovery>'
}
if ($Mode -eq 'template') {
    Write-Log "Template:       $TemplateName"
    Write-Log "Template Stack: $TemplateStackName"
}
Write-Log '============================================'

# --- Helper: wait for a PAN-OS job to complete --------------------------------
function Wait-PanoramaJob {
    param(
        [string]$JobId,
        [string]$JobLabel,
        [string]$ApiKey,
        [string]$PanoramaHost,
        [int]$WaitSec
    )

    while ($true) {
        Start-Sleep -Seconds $WaitSec

        $JobCmd        = "<show><jobs><id>$JobId</id></jobs></show>"
        $JobCmdEncoded = ConvertTo-UrlEncoded $JobCmd
        $ApiKeyEncoded = ConvertTo-UrlEncoded $ApiKey

        $JobXml = Invoke-WebRequest `
            -Uri "https://$PanoramaHost/api/?type=op&cmd=$JobCmdEncoded&key=$ApiKeyEncoded" `
            -Method Get `
            -SkipCertificateCheck `
            -UseBasicParsing

        $JobXmlStr = $JobXml.Content -replace "`n", ''

        $StatusMatch   = [regex]::Match($JobXmlStr, '<status>([^<]*)</status>')
        $ProgressMatch = [regex]::Match($JobXmlStr, '<progress>([^<]*)</progress>')
        $Status        = if ($StatusMatch.Success)   { $StatusMatch.Groups[1].Value }   else { '' }
        $Progress      = if ($ProgressMatch.Success) { $ProgressMatch.Groups[1].Value } else { '' }

        $JobResult = ''
        if ($JobXmlStr -match '<result>OK</result>')       { $JobResult = 'OK' }
        elseif ($JobXmlStr -match '<result>FAIL</result>') { $JobResult = 'FAIL' }

        if ($Status -eq 'FIN') {
            if ($JobResult -eq 'OK') {
                Write-Log "  $JobLabel completed successfully."
                return
            } else {
                Write-Log "ERROR: $JobLabel failed."
                Write-Log $JobXml.Content
                throw "$JobLabel failed."
            }
        } else {
            Write-Log "  $JobLabel... $Progress%"
        }
    }
}

# --- Step 1: Authenticate to Panorama (get API key) --------------------------
# Credentials go in the POST body, not the query string, so the password
# doesn't leak into Panorama's web access logs.
Write-Log "[1] Authenticating to Panorama ($PanoramaIP)..."

$AuthBody = @{
    type     = 'keygen'
    user     = $PanoramaUser
    password = $PanoramaPass
}

$AuthResponse = Invoke-WebRequest `
    -Uri "https://$PanoramaIP/api/" `
    -Method Post `
    -Body $AuthBody `
    -SkipCertificateCheck `
    -UseBasicParsing

$ApiKeyMatch = [regex]::Match($AuthResponse.Content, '<key>([^<]*)</key>')
if (-not $ApiKeyMatch.Success) {
    Write-Log 'ERROR: Failed to get API key. Response:'
    Write-Log $AuthResponse.Content
    exit 1
}
$ApiKey        = $ApiKeyMatch.Groups[1].Value
$ApiKeyEncoded = ConvertTo-UrlEncoded $ApiKey
Write-Log '  Authenticated successfully.'

# --- Step 2: Resolve certificate name ----------------------------------------
Write-Log '[2] Resolving target certificate name...'

$CertXpath = if ($Mode -eq 'template') {
    "/config/devices/entry[@name='localhost.localdomain']/template/entry[@name='$TemplateName']/config/shared/certificate"
} else {
    '/config/shared/certificate'
}

if (-not [string]::IsNullOrEmpty($CertNameOverride)) {
    # --- Explicit override: trust the provided name, no discovery needed -----
    $CertName = $CertNameOverride
    Write-Log "  Using explicit certificate name override: '$CertName'"
    Write-Log '  CN-based discovery skipped.'
} else {
    # --- CN-based discovery --------------------------------------------------
    Write-Log "  No override provided -- performing CN-based discovery for CN='$CommonName'..."

    $CertXpathEncoded = ConvertTo-UrlEncoded $CertXpath

    $CertXmlResponse = Invoke-WebRequest `
        -Uri "https://$PanoramaIP/api/?type=config&action=get&xpath=$CertXpathEncoded&key=$ApiKeyEncoded" `
        -Method Get `
        -SkipCertificateCheck `
        -UseBasicParsing

    $CertXmlFlat = $CertXmlResponse.Content -replace "`n", '' -replace '\s{2,}', ' '

    # Collect all certificate entry names whose <common-name> matches
    $EntryMatches  = [regex]::Matches($CertXmlFlat, '<entry name="[^"]*"[^>]*>.*?</entry>')
    $MatchingNames = @()
    foreach ($Entry in $EntryMatches) {
        if ($Entry.Value -match "<common-name>$([regex]::Escape($CommonName))</common-name>") {
            $NameMatch = [regex]::Match($Entry.Value, '<entry name="([^"]*)"')
            if ($NameMatch.Success) {
                $MatchingNames += $NameMatch.Groups[1].Value
            }
        }
    }

    $MatchCount = $MatchingNames.Count

    if ($MatchCount -eq 0) {
        Write-Log "  No existing certificate found with CN='$CommonName'."
        Write-Log '  A new certificate entry will be created.'
        $CertName = $CommonName -replace '\.', '-'
        Write-Log "  Derived certificate name: '$CertName'"

    } elseif ($MatchCount -eq 1) {
        $CertName = $MatchingNames[0]
        Write-Log "  Found exactly one certificate with CN='$CommonName': '$CertName'"
        Write-Log '  Will update in place (bindings will be preserved).'

    } else {
        # Multiple certificates share the same CN -- fail loudly
        Write-Log "ERROR: CN-based discovery found $MatchCount certificates sharing CN='$CommonName'."
        Write-Log '  Panorama cannot reliably determine which entry to update.'
        Write-Log '  Conflicting certificate names:'
        foreach ($Name in $MatchingNames) {
            Write-Log "    - $Name"
        }
        Write-Log '  ACTION REQUIRED: Set Argument 3 (certificate name override) to the exact'
        Write-Log '  Panorama certificate entry name you want to update, then re-run.'
        exit 1
    }
}

# --- Step 3: Upload certificate (PEM) ----------------------------------------
# Multipart form-data -- Invoke-WebRequest handles encoding of field values
# automatically when -Form is used, so no manual URL-encoding is needed here.
Write-Log "[3] Uploading certificate '$CertName'..."

$CertForm = @{
    file               = Get-Item $CrtFilePath
    type               = 'import'
    category           = 'certificate'
    'certificate-name' = $CertName
    format             = 'pem'
    key                = $ApiKey
}
if ($Mode -eq 'template') {
    $CertForm['target-tpl'] = $TemplateName
}

$UploadCertResponse = Invoke-WebRequest `
    -Uri "https://$PanoramaIP/api/" `
    -Method Post `
    -Form $CertForm `
    -SkipCertificateCheck `
    -UseBasicParsing

if ($UploadCertResponse.Content -match 'status="success"') {
    Write-Log '  Certificate uploaded successfully.'
} else {
    Write-Log 'ERROR: Certificate upload failed:'
    Write-Log $UploadCertResponse.Content
    exit 1
}

# --- Step 4: Upload private key (PEM) ----------------------------------------
Write-Log "[4] Uploading private key for '$CertName'..."

$KeyForm = @{
    file               = Get-Item $KeyFilePath
    type               = 'import'
    category           = 'private-key'
    'certificate-name' = $CertName
    format             = 'pem'
    passphrase         = $KeyPassphrase
    key                = $ApiKey
}
if ($Mode -eq 'template') {
    $KeyForm['target-tpl'] = $TemplateName
}

$UploadKeyResponse = Invoke-WebRequest `
    -Uri "https://$PanoramaIP/api/" `
    -Method Post `
    -Form $KeyForm `
    -SkipCertificateCheck `
    -UseBasicParsing

if ($UploadKeyResponse.Content -match 'status="success"') {
    Write-Log '  Private key uploaded successfully.'
} else {
    Write-Log 'ERROR: Private key upload failed:'
    Write-Log $UploadKeyResponse.Content
    exit 1
}

# --- Step 5: Commit to Panorama ----------------------------------------------
Write-Log '[5] Committing to Panorama...'

$CommitCmd        = '<commit></commit>'
$CommitCmdEncoded = ConvertTo-UrlEncoded $CommitCmd

$CommitResponse = Invoke-WebRequest `
    -Uri "https://$PanoramaIP/api/?type=commit&cmd=$CommitCmdEncoded&key=$ApiKeyEncoded" `
    -Method Get `
    -SkipCertificateCheck `
    -UseBasicParsing

$CommitJobMatch = [regex]::Match($CommitResponse.Content, '<job>([^<]*)</job>')
if (-not $CommitJobMatch.Success) {
    Write-Log '  No commit job created (may be nothing to commit or already committed).'
    Write-Log "  Response: $($CommitResponse.Content)"
} else {
    $CommitJobId = $CommitJobMatch.Groups[1].Value
    Write-Log "  Commit job ID: $CommitJobId"
    Wait-PanoramaJob -JobId $CommitJobId -JobLabel 'Commit' -ApiKey $ApiKey `
        -PanoramaHost $PanoramaIP -WaitSec $WaitSeconds
}

# --- Step 6: Push to devices (template mode only) ----------------------------
if ($Mode -eq 'template') {
    Write-Log "[6] Pushing template stack '$TemplateStackName' to all devices..."

    $PushCmd        = "<commit-all><template-stack><name>$TemplateStackName</name></template-stack></commit-all>"
    $PushCmdEncoded = ConvertTo-UrlEncoded $PushCmd

    $PushResponse = Invoke-WebRequest `
        -Uri "https://$PanoramaIP/api/?type=commit&action=all&key=$ApiKeyEncoded&cmd=$PushCmdEncoded" `
        -Method Get `
        -SkipCertificateCheck `
        -UseBasicParsing

    $PushJobMatch = [regex]::Match($PushResponse.Content, '<job>([^<]*)</job>')
    if (-not $PushJobMatch.Success) {
        Write-Log '  WARNING: No push job created. Response:'
        Write-Log "  $($PushResponse.Content)"
    } else {
        $PushJobId = $PushJobMatch.Groups[1].Value
        Write-Log "  Push job ID: $PushJobId"
        Wait-PanoramaJob -JobId $PushJobId -JobLabel 'Push to devices' -ApiKey $ApiKey `
            -PanoramaHost $PanoramaIP -WaitSec $WaitSeconds
    }
} else {
    Write-Log '[6] Skipping push (system mode -- cert is on Panorama itself).'
}

# --- Summary -----------------------------------------------------------------
Write-Log '=========================================='
Write-Log 'COMPLETED SUCCESSFULLY'
Write-Log '=========================================='
Write-Log "Certificate '$CertName' (CN=$CommonName)"
Write-Log "  Mode: $Mode"
if ($Mode -eq 'template') {
    Write-Log "  Uploaded to template: $TemplateName"
    Write-Log '  Committed to Panorama'
    Write-Log "  Pushed to devices via stack: $TemplateStackName"
} else {
    Write-Log '  Uploaded to Panorama (system)'
    Write-Log '  Committed to Panorama'
    Write-Log '  NOTE: To use this cert for the management UI, create an'
    Write-Log '    SSL/TLS Service Profile referencing this cert, then assign'
    Write-Log '    it in Panorama > Setup > Management > General Settings.'
}
Write-Log '=========================================='

exit 0