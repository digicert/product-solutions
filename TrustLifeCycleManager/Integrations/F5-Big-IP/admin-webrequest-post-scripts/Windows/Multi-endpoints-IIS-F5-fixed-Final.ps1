#!/usr/bin/env pwsh

<#
.SYNOPSIS
    DigiCert Certificate Deployment Script for F5 BIG-IP & Windows IIS
.DESCRIPTION
    Dual-target automated deployment script for DigiCert TLM Agent AWR post-script:
    Target 1 (F5 BIG-IP):
      - 100% Native iControl REST API
      - Expiration-stamped object naming: <cert-name>_expYYYYMMDD
      - Updates Client SSL and Server SSL profiles
      - Auto-prunes older retired certificates from F5
    Target 2 (Windows IIS):
      - Accepts IIS Site Name via Argument 4 (defaults to "Default Web Site")
      - Accepts IIS HTTPS Port via Argument 5 or "Site:Port" (defaults to 443)
      - Automatically configures SNI (Require Server Name Indication) using Argument 3
      - Imports into Cert:\LocalMachine\My with proper machine key permissions
.NOTES
    Legal Notice (version January 1, 2026)
    Copyright © 2026 DigiCert. All rights reserved.
#>

# ============================================================================
# CONFIGURATION
# ============================================================================
$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\f5IIS_data.log"

# --- F5 BIG-IP CONFIGURATION ---
$UPDATE_BIGIP              = "true"                      # Set to "true" to deploy to F5
$UPDATE_SERVER_SSL_PROFILE = "true"                      # Update Server SSL profile
$SERVER_SSL_PROFILE_NAME   = "digicer-server-profile"    # F5 Server SSL Profile name
$UPDATE_CLIENT_SSL_PROFILE = "true"                      # Update Client SSL profile
$CLIENT_SSL_PROFILE_NAME   = "digicer-client-profile"    # F5 Client SSL Profile name
$SAVE_SYS_CONFIG           = "true"                      # Run 'tmsh save sys config' on F5
$AUTO_PRUNE_OLD_CERTS      = "true"                      # Prune retired <cert>_exp* on F5

# --- WINDOWS IIS CONFIGURATION ---
$UPDATE_IIS                = "true"                      # Set to "true" to deploy to local IIS
$IIS_DEFAULT_SITE          = "Default Web Site"          # Fallback site if Arg 4 is omitted
$IIS_DEFAULT_PORT          = 443                         # Fallback port if Arg 5 is omitted

# ============================================================================
# LOGGING SETUP
# ============================================================================
$script:HAS_ERROR = $false

function Write-LogMessage {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] $Message"
    Add-Content -Path $LOGFILE -Value $logEntry -Encoding UTF8
    Write-Host $logEntry
}

function Write-LogError {
    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Message
    )
    $script:HAS_ERROR = $true
    Write-LogMessage $Message
}

$logDir = Split-Path -Path $LOGFILE -Parent
if (-not (Test-Path -Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

Write-LogMessage "=========================================================="
Write-LogMessage "Starting DigiCert Multi-Target Deployment (F5 & IIS)"
Write-LogMessage "=========================================================="

if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-LogError "ERROR: Legal notice not accepted. Set `$LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
    exit 1
}

# ============================================================================
# EXTRACT DATA FROM TLM AGENT
# ============================================================================
$DC1_POST_SCRIPT_DATA = $env:DC1_POST_SCRIPT_DATA
if ([string]::IsNullOrEmpty($DC1_POST_SCRIPT_DATA)) {
    Write-LogError "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
}

try {
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($DC1_POST_SCRIPT_DATA))
    $jsonObject = $JSON_STRING | ConvertFrom-Json
    Write-LogMessage "JSON decoded and parsed successfully"
}
catch {
    Write-LogError "ERROR: Failed to decode/parse DC1_POST_SCRIPT_DATA JSON: $_"
    exit 1
}

# --- Arguments 1, 2, 3 (F5 & Cert Info) ---
$rawCreds   = $jsonObject.args[0]
$BIGIP_HOST = $jsonObject.args[1]
$CERT_NAME  = $jsonObject.args[2]

# --- Argument 4: IIS Site Name (Optional) ---
$rawSiteArg = if ($jsonObject.args.Count -ge 4 -and -not [string]::IsNullOrWhiteSpace($jsonObject.args[3])) {
    $jsonObject.args[3].Trim()
} else {
    $IIS_DEFAULT_SITE
}

# --- Argument 5: IIS Port (Optional, default 443) ---
$IIS_PORT = $IIS_DEFAULT_PORT
if ($jsonObject.args.Count -ge 5 -and -not [string]::IsNullOrWhiteSpace($jsonObject.args[4])) {
    $parsedPort = 0
    if ([int]::TryParse($jsonObject.args[4].Trim(), [ref]$parsedPort) -and $parsedPort -gt 0) {
        $IIS_PORT = $parsedPort
    }
}
elseif ($rawSiteArg -match "^(.+):(\d+)$") {
    $rawSiteArg = $Matches[1]
    $IIS_PORT   = [int]$Matches[2]
}

$IIS_SITE_NAME   = $rawSiteArg
$SNI_HOST_HEADER = $CERT_NAME

Write-LogMessage "Parsed Parameters:"
Write-LogMessage "  BIG-IP Host:      $BIGIP_HOST"
Write-LogMessage "  Certificate Name: $CERT_NAME"
Write-LogMessage "  IIS Target Site:  $IIS_SITE_NAME"
Write-LogMessage "  IIS Target Port:  $IIS_PORT"
Write-LogMessage "  IIS SNI Header:   $SNI_HOST_HEADER"

$credParts  = $rawCreds -split ":", 2
$BIGIP_USER = $credParts[0]
$BIGIP_PASS = $credParts[1]

$secPassword = ConvertTo-SecureString $BIGIP_PASS -AsPlainText -Force
$credential  = New-Object System.Management.Automation.PSCredential($BIGIP_USER, $secPassword)

$skipCertCheck = @{}
if ($PSVersionTable.PSEdition -eq "Core") {
    $skipCertCheck = @{ SkipCertificateCheck = $true }
} else {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

$CERT_FOLDER   = $jsonObject.certfolder
$CRT_FILE_PATH = Join-Path $CERT_FOLDER "$CERT_NAME.crt"
$KEY_FILE_PATH = Join-Path $CERT_FOLDER "$CERT_NAME.key"

if (-not (Test-Path $CRT_FILE_PATH) -or -not (Test-Path $KEY_FILE_PATH)) {
    Write-LogError "ERROR: Certificate or Key file not found in $CERT_FOLDER"
    exit 1
}

# ============================================================================
# PARSE CERTIFICATE FOR EXPIRATION & THUMBPRINT
# ============================================================================
$certExpDate = ""
$certThumbprint = ""
try {
    $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CRT_FILE_PATH)
    $certSerial     = $certObj.SerialNumber.ToLower()
    $certThumbprint = $certObj.Thumbprint
    $certExpDate    = $certObj.NotAfter.ToString("yyyyMMdd")

    Write-LogMessage "Parsed new certificate details:"
    Write-LogMessage "  Subject:     $($certObj.Subject)"
    Write-LogMessage "  Serial:      $certSerial"
    Write-LogMessage "  Thumbprint:  $certThumbprint"
    Write-LogMessage "  Expires:     $($certObj.NotAfter)"
}
catch {
    Write-LogError "ERROR: Failed to inspect certificate: $_"
    exit 1
}

$OBJECT_NAME = "${CERT_NAME}_exp${certExpDate}"

# ============================================================================
# PART 1: DEPLOYMENT TO F5 BIG-IP
# ============================================================================
if ($UPDATE_BIGIP -eq "true") {
    Write-LogMessage "----------------------------------------------------------"
    Write-LogMessage "Beginning F5 BIG-IP Deployment -> Target: '$OBJECT_NAME'"
    Write-LogMessage "----------------------------------------------------------"

    # Step 1: Upload CRT
    Write-LogMessage "[F5] Step 1: Uploading certificate file..."
    $crtBytes = [System.IO.File]::ReadAllBytes($CRT_FILE_PATH)
    try {
        $headers = @{ "Content-Range" = "0-$($crtBytes.Length - 1)/$($crtBytes.Length)"; "Content-Type" = "application/octet-stream" }
        Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/shared/file-transfer/uploads/$OBJECT_NAME.crt" `
            -Method Post -Headers $headers -Body $crtBytes -Credential $credential @skipCertCheck | Out-Null
        Write-LogMessage "[F5] SUCCESS: Certificate file uploaded"
    } catch { Write-LogError "[F5] ERROR: Uploading cert failed: $_"; exit 1 }

    # Step 2: Upload KEY
    Write-LogMessage "[F5] Step 2: Uploading key file..."
    $keyBytes = [System.IO.File]::ReadAllBytes($KEY_FILE_PATH)
    try {
        $headers = @{ "Content-Range" = "0-$($keyBytes.Length - 1)/$($keyBytes.Length)"; "Content-Type" = "application/octet-stream" }
        Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/shared/file-transfer/uploads/$OBJECT_NAME.key" `
            -Method Post -Headers $headers -Body $keyBytes -Credential $credential @skipCertCheck | Out-Null
        Write-LogMessage "[F5] SUCCESS: Key file uploaded"
    } catch { Write-LogError "[F5] ERROR: Uploading key failed: $_"; exit 1 }

    # Step 3: Install CRT via Native REST
    Write-LogMessage "[F5] Step 3: Installing certificate '$OBJECT_NAME' via REST..."
    try {
        $body = @{ command = "install"; name = $OBJECT_NAME; "from-local-file" = "/var/config/rest/downloads/$OBJECT_NAME.crt" } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/sys/crypto/cert" -Method Post -Body $body `
            -ContentType "application/json" -Credential $credential @skipCertCheck | Out-Null
        Write-LogMessage "[F5] SUCCESS: Certificate installed"
    } catch { Write-LogError "[F5] ERROR: Installing cert failed: $_"; exit 1 }

    # Step 4: Install KEY via Native REST
    Write-LogMessage "[F5] Step 4: Installing key '$OBJECT_NAME' via REST..."
    try {
        $body = @{ command = "install"; name = $OBJECT_NAME; "from-local-file" = "/var/config/rest/downloads/$OBJECT_NAME.key" } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/sys/crypto/key" -Method Post -Body $body `
            -ContentType "application/json" -Credential $credential @skipCertCheck | Out-Null
        Write-LogMessage "[F5] SUCCESS: Key installed"
    } catch { Write-LogError "[F5] ERROR: Installing key failed: $_"; exit 1 }

    # Step 4b: Extract & install the CA chain (intermediates) bundled in the issued
    # certificate file, if any. DigiCert's issued .crt often contains the leaf cert
    # plus intermediates concatenated together; the leaf is installed above as
    # $OBJECT_NAME, so here we pull out everything after it and install it as its
    # own BIG-IP object so it can be referenced as the Client SSL profile's chain.
    $chainObjectName = $null
    try {
        $pemText = Get-Content -Path $CRT_FILE_PATH -Raw
        $certMatches = [System.Text.RegularExpressions.Regex]::Matches(
            $pemText, "-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
            [System.Text.RegularExpressions.RegexOptions]::Singleline)

        if ($certMatches.Count -gt 1) {
            $chainPem = ($certMatches | Select-Object -Skip 1 | ForEach-Object { $_.Value }) -join "`n"
            $chainFileName = "$OBJECT_NAME-chain"
            $tempChainPath = Join-Path $CERT_FOLDER "$chainFileName.crt"
            Set-Content -Path $tempChainPath -Value $chainPem -Encoding ASCII -NoNewline

            Write-LogMessage "[F5] Step 4b: Uploading & installing CA chain bundle '$chainFileName' ($($certMatches.Count - 1) intermediate cert(s))..."
            $chainBytes = [System.IO.File]::ReadAllBytes($tempChainPath)
            $chainHeaders = @{ "Content-Range" = "0-$($chainBytes.Length - 1)/$($chainBytes.Length)"; "Content-Type" = "application/octet-stream" }
            Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/shared/file-transfer/uploads/$chainFileName.crt" `
                -Method Post -Headers $chainHeaders -Body $chainBytes -Credential $credential @skipCertCheck | Out-Null

            $chainInstallBody = @{ command = "install"; name = $chainFileName; "from-local-file" = "/var/config/rest/downloads/$chainFileName.crt" } | ConvertTo-Json
            Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/sys/crypto/cert" -Method Post -Body $chainInstallBody `
                -ContentType "application/json" -Credential $credential @skipCertCheck | Out-Null

            $chainObjectName = $chainFileName
            Write-LogMessage "[F5] SUCCESS: CA chain bundle installed as '$chainObjectName'"
            Remove-Item $tempChainPath -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-LogMessage "[F5] Step 4b: Issued certificate file contains no intermediates - nothing to extract"
        }
    }
    catch {
        Write-LogMessage "[F5] Notice: CA chain extraction/install failed, continuing without it: $_"
    }

    # Step 5: Update Client SSL Profile
    if ($UPDATE_CLIENT_SSL_PROFILE -eq "true") {
        Write-LogMessage "[F5] Step 5: Updating Client SSL profile '$CLIENT_SSL_PROFILE_NAME'..."
        $clientUri = "https://$BIGIP_HOST/mgmt/tm/ltm/profile/client-ssl/~Common~$CLIENT_SSL_PROFILE_NAME"
        $chainName = "default"
        $existingChainRef = $null
        try {
            $cur = Invoke-RestMethod -Uri $clientUri -Method Get -Credential $credential @skipCertCheck
            if ($cur.certKeyChain -and $cur.certKeyChain.Count -gt 0) {
                $chainName = $cur.certKeyChain[0].name
                $existingChainRef = $cur.certKeyChain[0].chain
            }
        } catch {}

        # If the profile already has a CA chain bundle bound, leave it alone. Only bind
        # the newly imported bundle when the profile currently has none configured.
        $chainToUse = $null
        if ($existingChainRef -and $existingChainRef -ne "none") {
            $chainToUse = $existingChainRef
            Write-LogMessage "[F5]   CA chain bundle already configured ('$existingChainRef') - leaving it unchanged"
        }
        elseif ($chainObjectName) {
            $chainToUse = "/Common/$chainObjectName"
            Write-LogMessage "[F5]   No CA chain bundle currently configured - binding newly imported bundle '$chainToUse'"
        }
        else {
            Write-LogMessage "[F5]   No CA chain bundle currently configured and none found in the issued certificate - leaving chain unset"
        }

        $chainKeyEntry = @{ name = $chainName; cert = "/Common/$OBJECT_NAME"; key = "/Common/$OBJECT_NAME" }
        if ($chainToUse) { $chainKeyEntry["chain"] = $chainToUse }

        $patchBody = @{ certKeyChain = @($chainKeyEntry) } | ConvertTo-Json -Depth 5
        try {
            Invoke-RestMethod -Uri $clientUri -Method Patch -Body $patchBody `
                -ContentType "application/json" -Credential $credential @skipCertCheck | Out-Null
            Write-LogMessage "[F5] SUCCESS: Client SSL profile updated"
        } catch { Write-LogError "[F5] ERROR: Updating Client SSL profile failed: $_"; exit 1 }
    }

    # Step 6: Update Server SSL Profile
    if ($UPDATE_SERVER_SSL_PROFILE -eq "true") {
        Write-LogMessage "[F5] Step 6: Updating Server SSL profile '$SERVER_SSL_PROFILE_NAME'..."
        $serverUri = "https://$BIGIP_HOST/mgmt/tm/ltm/profile/server-ssl/~Common~$SERVER_SSL_PROFILE_NAME"
        $serverBody = @{ cert = "/Common/$OBJECT_NAME"; key = "/Common/$OBJECT_NAME" } | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri $serverUri -Method Patch -Body $serverBody `
                -ContentType "application/json" -Credential $credential @skipCertCheck | Out-Null
            Write-LogMessage "[F5] SUCCESS: Server SSL profile updated"
        } catch { Write-LogError "[F5] ERROR: Updating Server SSL profile failed: $_"; exit 1 }
    }

    # Step 7: Auto-Prune Old Expired Objects
    if ($AUTO_PRUNE_OLD_CERTS -eq "true") {
        Write-LogMessage "[F5] Step 7: Auto-pruning older '$CERT_NAME' certificates..."
        try {
            $allCerts = Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/sys/crypto/cert" -Method Get -Credential $credential @skipCertCheck
            if ($allCerts.items) {
                $prefix = "${CERT_NAME}_exp"
                foreach ($item in $allCerts.items) {
                    if ($item.name -like "$prefix*" -and $item.name -ne $OBJECT_NAME -and $item.name -ne $chainObjectName) {
                        $oldName = $item.name
                        try {
                            Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/sys/crypto/cert/~Common~$oldName" -Method Delete -Credential $credential @skipCertCheck | Out-Null
                            Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/sys/crypto/key/~Common~$oldName" -Method Delete -Credential $credential @skipCertCheck | Out-Null
                            Write-LogMessage "[F5]   SUCCESS: Pruned retired object '$oldName'"
                        } catch {}
                    }
                }
            }
        } catch {}
    }

    # Step 8: Save Configuration
    if ($SAVE_SYS_CONFIG -eq "true") {
        try {
            Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/sys/config" -Method Post -Body (@{ command = "save" } | ConvertTo-Json) `
                -ContentType "application/json" -Credential $credential @skipCertCheck | Out-Null
            Write-LogMessage "[F5] SUCCESS: System configuration saved"
        } catch {}
    }

    # Step 9: Cleanup F5 Uploads
    try {
        $cleanTargets = "/var/config/rest/downloads/$OBJECT_NAME.crt /var/config/rest/downloads/$OBJECT_NAME.key"
        if ($chainObjectName) { $cleanTargets += " /var/config/rest/downloads/$chainObjectName.crt" }
        $cleanBody = @{ command = "run"; utilCmdArgs = "-c 'rm -f $cleanTargets'" } | ConvertTo-Json
        Invoke-RestMethod -Uri "https://$BIGIP_HOST/mgmt/tm/util/bash" -Method Post -Body $cleanBody `
            -ContentType "application/json" -Credential $credential @skipCertCheck | Out-Null
    } catch {}
}

# ============================================================================
# PART 2: DEPLOYMENT TO WINDOWS IIS
# ============================================================================
if ($UPDATE_IIS -eq "true") {
    Write-LogMessage "----------------------------------------------------------"
    Write-LogMessage "Beginning Windows IIS Deployment"
    Write-LogMessage "Site: '$IIS_SITE_NAME' | Port: $IIS_PORT | SNI: '$SNI_HOST_HEADER'"
    Write-LogMessage "----------------------------------------------------------"

    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-LogMessage "[IIS] WebAdministration module loaded"
    }
    catch {
        Write-LogError "[IIS] ERROR: WebAdministration module not available. Install IIS Management Tools."
        exit 1
    }

    # Step 1: Ingest Certificate & Key into Windows Certificate Store
    Write-LogMessage "[IIS] Step 1: Ingesting Certificate & Key into LocalMachine\My..."
    $installedIntoStore = $false

    # Method A: .NET CreateFromPemFile (requires PowerShell 7+ / .NET 5+)
    # Both branches below now log WHY they were skipped instead of failing silently -
    # that silence (no log line either way) was the actual bug: with Method A unavailable
    # (Windows PowerShell 5.1 has no CreateFromPemFile) and OpenSSL not on PATH, the script
    # fell straight through to a generic "Unable to import" error with nothing explaining why.
    $hasCreateFromPemFile = [bool]([System.Security.Cryptography.X509Certificates.X509Certificate2].GetMethod("CreateFromPemFile", [type[]]@([string], [string])))
    Write-LogMessage "[IIS]   PowerShell edition: $($PSVersionTable.PSEdition), version: $($PSVersionTable.PSVersion)"
    Write-LogMessage "[IIS]   .NET CreateFromPemFile available: $hasCreateFromPemFile"

    if ($hasCreateFromPemFile) {
        try {
            $pemCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($CRT_FILE_PATH, $KEY_FILE_PATH)

            $tempPass = [System.Guid]::NewGuid().ToString()
            $pfxBytes = $pemCert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $tempPass)

            $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor `
                     [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::PersistKeySet -bor `
                     [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable

            $storeCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($pfxBytes, $tempPass, $flags)
            $storeCert.FriendlyName = "$CERT_NAME-$certExpDate"

            $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("My", "LocalMachine")
            $store.Open("ReadWrite")
            $store.Add($storeCert)
            $store.Close()

            $installedIntoStore = $true
            Write-LogMessage "[IIS] SUCCESS: Certificate imported via .NET"
        }
        catch {
            Write-LogMessage "[IIS] Notice: .NET PEM import failed ($($_)). Trying OpenSSL fallback..."
        }
    }
    else {
        Write-LogMessage "[IIS]   Skipping .NET method: CreateFromPemFile requires PowerShell 7+ (this session is $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)). Falling back to OpenSSL..."
    }

    # Method B: OpenSSL Fallback (works on both PowerShell 5.1 and 7+)
    if (-not $installedIntoStore) {
        $tempPfxPath = Join-Path $CERT_FOLDER "$CERT_NAME.pfx"
        $tempPfxPass = [System.Guid]::NewGuid().ToString("N")

        # Search PATH first (as before), then fall back to common install locations where
        # openssl.exe may exist without ever having been added to PATH - this is what the
        # original PATH-only Get-Command check was missing, and why it fell through silently.
        $opensslCmd = Get-Command "openssl" -ErrorAction SilentlyContinue
        $opensslPath = if ($opensslCmd) { $opensslCmd.Source } else { $null }

        if (-not $opensslPath) {
            $candidatePaths = @(
                "$env:ProgramFiles\Git\usr\bin\openssl.exe",
                "$env:ProgramFiles\Git\mingw64\bin\openssl.exe",
                "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe",
                "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.exe",
                "$env:ProgramFiles\OpenSSL-Win32\bin\openssl.exe",
                "$env:ProgramData\chocolatey\bin\openssl.exe"
            )
            foreach ($candidate in $candidatePaths) {
                if ($candidate -and (Test-Path $candidate)) {
                    $opensslPath = $candidate
                    Write-LogMessage "[IIS]   Found OpenSSL outside PATH at: $opensslPath"
                    break
                }
            }
        }

        if ($opensslPath) {
            Write-LogMessage "[IIS] Generating PFX via OpenSSL ($opensslPath)..."
            & $opensslPath pkcs12 -export -out $tempPfxPath -inkey $KEY_FILE_PATH -in $CRT_FILE_PATH -passout "pass:$tempPfxPass"

            if (Test-Path $tempPfxPath) {
                $pfxCert = Import-PfxCertificate -FilePath $tempPfxPath -CertStoreLocation "Cert:\LocalMachine\My" `
                    -Password ($tempPfxPass | ConvertTo-SecureString -AsPlainText -Force) -Exportable
                Remove-Item $tempPfxPath -Force -ErrorAction SilentlyContinue
                $installedIntoStore = $true
                Write-LogMessage "[IIS] SUCCESS: Certificate imported via OpenSSL PFX"
            }
            else {
                Write-LogMessage "[IIS]   OpenSSL ran but did not produce a PFX file at $tempPfxPath - check for an OpenSSL error above this line"
            }
        }
        else {
            Write-LogMessage "[IIS]   OpenSSL not found in PATH or any common install location"
        }
    }

    if (-not $installedIntoStore) {
        Write-LogError "[IIS] ERROR: Unable to import certificate into Windows Store."
        Write-LogError "[IIS]   Neither import method is available on this machine:"
        Write-LogError "[IIS]     - .NET CreateFromPemFile needs PowerShell 7+ (this session: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion))"
        Write-LogError "[IIS]     - OpenSSL for Windows was not found in PATH or common install locations"
        Write-LogError "[IIS]   Fix: install OpenSSL for Windows (e.g. https://slproweb.com/products/Win32OpenSSL.html) and ensure openssl.exe is on PATH, or run this script under PowerShell 7+ (pwsh.exe) instead of Windows PowerShell 5.1."
        exit 1
    }

    # Step 2: Configure IIS HTTPS Binding with SNI
    Write-LogMessage "[IIS] Step 2: Configuring HTTPS binding on site '$IIS_SITE_NAME' (Port: $IIS_PORT)..."
    try {
        $site = Get-Website -Name $IIS_SITE_NAME
        if (-not $site) {
            Write-LogError "[IIS] ERROR: IIS Website '$IIS_SITE_NAME' not found."
            exit 1
        }

        # Check for existing HTTPS binding on this port matching the host header (SAFE VARIABLE INTERPOLATION)
        $existingBinding = Get-WebBinding -Name $IIS_SITE_NAME -Protocol "https" | Where-Object {
            $_.bindingInformation -match ":$($IIS_PORT):" -and ($_.hostHeader -eq $SNI_HOST_HEADER -or [string]::IsNullOrEmpty($_.hostHeader))
        }

        if ($existingBinding) {
            Write-LogMessage "[IIS] Updating existing binding (Host: '$($existingBinding.hostHeader)', Port: $IIS_PORT)..."
            if (-not [string]::IsNullOrEmpty($SNI_HOST_HEADER)) {
                $existingBinding.sslFlags = 1  # Require SNI
            }
            $existingBinding.AddSslCertificate($certThumbprint, "My")
            Write-LogMessage "[IIS] SUCCESS: Existing binding updated with Thumbprint: $certThumbprint"
        }
        else {
            Write-LogMessage "[IIS] Creating new SNI HTTPS binding on port $IIS_PORT..."
            $newBindingArgs = @{
                Name        = $IIS_SITE_NAME
                Protocol    = "https"
                Port        = $IIS_PORT
                IPAddress   = "*"
                HostHeader  = $SNI_HOST_HEADER
                SslFlags    = 1 # 1 = Require SNI
            }
            New-WebBinding @newBindingArgs

            $newBinding = Get-WebBinding -Name $IIS_SITE_NAME -Protocol "https" | Where-Object {
                $_.bindingInformation -match ":$($IIS_PORT):$($SNI_HOST_HEADER)"
            }
            $newBinding.AddSslCertificate($certThumbprint, "My")
            Write-LogMessage "[IIS] SUCCESS: New SNI HTTPS binding created (Port: $IIS_PORT, Host: $SNI_HOST_HEADER)"
        }
    }
    catch {
        Write-LogError "[IIS] ERROR: Failed configuring IIS binding: $_"
        exit 1
    }

    # Step 3: Verification
    Write-LogMessage "[IIS] Step 3: Verifying active IIS SSL binding..."
    try {
        $verified = Get-WebBinding -Name $IIS_SITE_NAME -Protocol "https" | Where-Object {
            $_.bindingInformation -match ":$($IIS_PORT):"
        }
        Write-LogMessage "[IIS]   [Verified Binding] Info:     $($verified.bindingInformation)"
        Write-LogMessage "[IIS]   [Verified Binding] SNI:      $(if ($verified.sslFlags -eq 1) {'Enabled'} else {'Disabled'})"
        Write-LogMessage "[IIS]   [Verified Binding] CertHash: $($verified.certificateHash)"
    }
    catch {
        Write-LogMessage "[IIS] WARNING: Verification query encountered: $_"
    }
}

Write-LogMessage "=========================================================="
if ($script:HAS_ERROR) {
    Write-LogError "Multi-Target Deployment completed WITH ERRORS."
    exit 1
} else {
    Write-LogMessage "Multi-Target Deployment completed SUCCESSFULLY."
    exit 0
}
Write-LogMessage "=========================================================="
