<#
===============================================================================
Legal Notice (version January 1, 2026)
===============================================================================
Copyright (c) 2026 DigiCert. All rights reserved.
DigiCert and its logo are registered trademarks of DigiCert, Inc.
Other names may be trademarks of their respective owners.
For the purposes of this Legal Notice, "DigiCert" refers to:
  DigiCert, Inc., if you are located in the United States;
  DigiCert Ireland Limited, if you are located outside of the United States or Japan;
  DigiCert Japan G.K., if you are located in Japan.
The software described in this notice is provided by DigiCert and distributed under
licenses restricting its use, copying, distribution, and decompilation or reverse
engineering. No part of the software may be reproduced in any form by any means
without prior written authorization of DigiCert and its licensors, if any.
Use of the software is subject to the terms and conditions of your agreement with
DigiCert. THE SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND.
Export Regulation: Subject to U.S. Export Administration Regulations (EAR).
The contractor/manufacturer is DIGICERT, INC.
===============================================================================
#>

$LEGAL_NOTICE_ACCEPT = $false  # Set to $true to accept the legal notice and proceed

# =====================================================
# CONFIGURATION
# =====================================================

# Log file path
$LogFile = "C:\Program Files\DigiCert\TLM Agent\log\WebLogicCertUpdate.log"

# Java Keystore Configuration
$JKS_PATH      = "C:\Oracle\Middleware\Oracle_Home\user_projects\domains\base_domain\security\DemoIdentity.jks"
$JKS_PASSWORD  = "DemoIdentityKeyStorePassPhrase"
$JKS_BACKUP_DIR = "C:\backups\weblogic"
$JKS_ALIAS     = "demoidentity"   # Must match exactly what WebLogic SSL config uses (case-sensitive)
                                   # NOTE: PKCS12 always lowercases aliases - use lowercase here
$USE_CN_AS_ALIAS = $false         # Set to $true to use cert CN as alias instead of JKS_ALIAS

# Explicit keytool path - bypasses PATH so TLM agent always uses the correct JDK
# FIX: TLM agent may have a different PATH/JAVA_HOME than the interactive user
$KEYTOOL = "C:\Program Files\Java\jdk-11\bin\keytool.exe"

# WebLogic Restart Configuration
$WL_DOMAIN_BIN      = "C:\Oracle\Middleware\Oracle_Home\user_projects\domains\base_domain\bin"
$WL_HTTP_PORT       = 7001   # HTTP port to probe after restart (confirm WebLogic is up)
$WL_HTTPS_PORT      = 7002   # HTTPS/SSL port to probe after restart
$WL_RESTART_TIMEOUT = 120    # Seconds to wait for WebLogic to respond after start

# =====================================================
# FUNCTIONS
# =====================================================

function Write-Log {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Mask-Password {
    param([string]$Password)
    if ([string]::IsNullOrEmpty($Password)) { return "(empty)" }
    if ($Password.Length -le 3) { return "***" }
    return $Password.Substring(0, 3) + "***"
}

# Invoke keytool using the & call operator with an array of arguments.
# FIX: Start-Process re-parses ArgumentList through cmd.exe which splits on
# spaces and commas inside values. The & operator passes each array element
# as a discrete token - no re-parsing, no space/comma splitting issues.
function Invoke-Keytool {
    param([string[]]$Arguments)
    $output = & $KEYTOOL @Arguments 2>&1
    $stdoutLines = $output | Where-Object { $_ -is [string] }
    $stderrLines = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                             ForEach-Object { $_.Exception.Message }
    return @{
        ExitCode = $LASTEXITCODE
        StdOut   = ($stdoutLines -join "`n")
        StdErr   = ($stderrLines -join "`n")
    }
}

# Detect the actual storetype of a keystore file (JKS or PKCS12).
# FIX: File extension is unreliable - TLM often delivers PKCS12 files with
# a .jks extension. Using wrong -deststoretype causes "Invalid keystore format".
function Get-KeystoreType {
    param([string]$KeystoreFile, [string]$KeystorePassword)
    $result = Invoke-Keytool @("-list", "-keystore", $KeystoreFile, "-storepass", $KeystorePassword)
    $allOutput = $result.StdOut + $result.StdErr
    foreach ($line in ($allOutput -split "`n")) {
        if ($line -match "Keystore type:\s*(\S+)") {
            $detected = $Matches[1].Trim().ToUpper()
            Write-Log "Detected keystore type: $detected ($KeystoreFile)"
            return $detected
        }
    }
    Write-Log "WARNING: Could not detect keystore type for $KeystoreFile - defaulting to JKS"
    return "JKS"
}

# Probe a TCP port - returns $true if the port accepts a connection
function Test-TcpPort {
    param([string]$Hostname = "localhost", [int]$Port, [int]$TimeoutMs = 3000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connect = $tcp.BeginConnect($Hostname, $Port, $null, $null)
        $wait = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($wait) {
            $tcp.EndConnect($connect)
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

# =====================================================
# MAIN
# =====================================================

Write-Log "=========================================="
Write-Log "Starting WebLogic PFX to JKS import script"
Write-Log "=========================================="

# Legal notice check
if (-not $LEGAL_NOTICE_ACCEPT) {
    Write-Log "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT = true to proceed."
    exit 1
}
Write-Log "Legal notice accepted."

# Log configuration
Write-Log "Configuration:"
Write-Log "  JKS_PATH:       $JKS_PATH"
Write-Log "  JKS_ALIAS:      $JKS_ALIAS"
Write-Log "  JKS_BACKUP_DIR: $JKS_BACKUP_DIR"
Write-Log "  KEYTOOL:        $KEYTOOL"
Write-Log "  WL_DOMAIN_BIN:  $WL_DOMAIN_BIN"

# Verify keytool exists
if (-not (Test-Path -Path $KEYTOOL)) {
    Write-Log "ERROR: keytool not found at: $KEYTOOL"
    Write-Log "Update the KEYTOOL variable in the script config section."
    exit 1
}
Write-Log "keytool found: $KEYTOOL"

try {

    # =====================================================
    # Step 1: Decode TLM payload
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 1: Decoding TLM payload"
    Write-Log "=========================================="

    $base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")
    if ([string]::IsNullOrEmpty($base64Json)) {
        Write-Log "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
        exit 1
    }
    Write-Log "DC1_POST_SCRIPT_DATA length: $($base64Json.Length) characters"

    # FIX: Decode base64 then strip \r (carriage return) from the JSON string.
    # TLM encodes the payload with Windows-style CRLF line endings. After base64
    # decode every extracted value would have a silent \r appended, corrupting
    # passwords when passed to keytool (e.g. "P@ssword12\r" fails authentication).
    $jsonBytes  = [System.Convert]::FromBase64String($base64Json)
    $jsonString = [System.Text.Encoding]::UTF8.GetString($jsonBytes) -replace "`r", ""
    Write-Log "JSON decoded successfully"
    Write-Log "--- Raw JSON ---"
    Write-Log $jsonString
    Write-Log "----------------"

    $jsonObject = $jsonString | ConvertFrom-Json

    # Extract fields
    $certFolder = $jsonObject.certfolder
    $filesArray = @($jsonObject.files)

    # FIX: Strip \r\n from password separately for extra safety
    $pfxPassword = ($jsonObject.password -replace "[\r\n]", "")

    Write-Log "Cert folder:   $certFolder"
    Write-Log "Files:         $($filesArray -join ', ')"
    Write-Log "PFX password:  $(Mask-Password $pfxPassword) ($($pfxPassword.Length) chars)"

    if ([string]::IsNullOrEmpty($pfxPassword)) {
        # Try alternate field names
        foreach ($field in @("pfx_password","keystore_password","passphrase")) {
            $val = $jsonObject.$field -replace "[\r\n]", ""
            if (-not [string]::IsNullOrEmpty($val)) {
                $pfxPassword = $val
                Write-Log "PFX password found in alternate field '$field'"
                break
            }
        }
        if ([string]::IsNullOrEmpty($pfxPassword)) {
            Write-Log "WARNING: No PFX password found in JSON payload"
        }
    }

    # =====================================================
    # Step 2: Identify PFX file
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 2: Identifying PFX file"
    Write-Log "=========================================="

    $nonLegacyPfx = ""
    $legacyPfx    = ""

    foreach ($file in $filesArray) {
        if ($file -match "_legacy") {
            $legacyPfx = $file
            Write-Log "Legacy PFX: $legacyPfx"
        } elseif ($file -match "\.(pfx|p12)$") {
            $nonLegacyPfx = $file
            Write-Log "Non-legacy PFX: $nonLegacyPfx"
        }
    }

    if ([string]::IsNullOrEmpty($nonLegacyPfx) -and $filesArray.Count -gt 0) {
        $nonLegacyPfx = $filesArray[0]
        Write-Log "No explicit non-legacy PFX found, using first file: $nonLegacyPfx"
    }

    $pfxFilePath = Join-Path -Path $certFolder -ChildPath $nonLegacyPfx

    if (-not (Test-Path -Path $pfxFilePath)) {
        Write-Log "ERROR: PFX file not found: $pfxFilePath"
        exit 1
    }

    $pfxSize = (Get-Item $pfxFilePath).Length
    Write-Log "PFX file: $pfxFilePath ($pfxSize bytes)"

    # =====================================================
    # Step 3: Inspect PFX via openssl or keytool
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 3: Inspecting PFX contents"
    Write-Log "=========================================="

    # Try to get CN from the cert using keytool -printcert
    $certSubject = ""
    $printArgs = @("-printcert", "-file", $pfxFilePath)
    # keytool -printcert on a PFX won't work directly; use -list on the PFX as a keystore
    $listPfxResult = Invoke-Keytool @(
        "-list", "-v",
        "-keystore", $pfxFilePath,
        "-storetype", "pkcs12",
        "-storepass", $pfxPassword
    )
    $pfxOutput = $listPfxResult.StdOut + $listPfxResult.StdErr
    foreach ($line in ($pfxOutput -split "`n")) {
        if ($line -match "Owner:\s*CN=([^,]+)") {
            $certSubject = $Matches[1].Trim()
            Write-Log "Certificate CN: $certSubject"
            break
        }
    }

    # Determine alias to use
    $effectiveAlias = $JKS_ALIAS
    if ($USE_CN_AS_ALIAS -and -not [string]::IsNullOrEmpty($certSubject)) {
        $effectiveAlias = $certSubject
        Write-Log "Using CN as alias: $effectiveAlias"
    } else {
        Write-Log "Using configured alias: $effectiveAlias"
    }

    # =====================================================
    # Step 4: Detect source alias in PFX
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 4: Detecting source alias in PFX"
    Write-Log "=========================================="

    # FIX: Detect source alias reliably from keytool -list output.
    # JDK 11 format: "1, Jun. 23, 2026, PrivateKeyEntry,"
    # The alias is the first comma-separated field on a non-header line.
    # Exclude error/header lines so a failed keytool call is never captured as the alias.
    $srcAlias = ""

    # Method A: look for PrivateKeyEntry line
    foreach ($line in ($pfxOutput -split "`n")) {
        if ($line -match "PrivateKeyEntry" -and $line -notmatch "^keytool" -and $line -notmatch "error") {
            $srcAlias = ($line -split ",")[0].Trim()
            if (-not [string]::IsNullOrEmpty($srcAlias)) {
                Write-Log "Source alias from PrivateKeyEntry line: '$srcAlias'"
                break
            }
        }
    }

    # Method B: first non-header line
    if ([string]::IsNullOrEmpty($srcAlias)) {
        $skipPatterns = @("^Keystore","^Your keystore","^$","^Warning","^Certificate","^keytool","error")
        foreach ($line in ($pfxOutput -split "`n")) {
            $skip = $false
            foreach ($pat in $skipPatterns) { if ($line -match $pat) { $skip = $true; break } }
            if (-not $skip -and -not [string]::IsNullOrEmpty($line.Trim())) {
                $srcAlias = ($line -split ",")[0].Trim()
                if (-not [string]::IsNullOrEmpty($srcAlias)) {
                    Write-Log "Source alias from first non-header line: '$srcAlias'"
                    break
                }
            }
        }
    }

    if ([string]::IsNullOrEmpty($srcAlias)) {
        Write-Log "WARNING: Could not determine source alias - will import all entries"
    } else {
        Write-Log "Source alias: '$srcAlias'"
    }

    # =====================================================
    # Step 5: Backup and detect destination keystore type
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 5: Backup and keystore type detection"
    Write-Log "=========================================="

    # Create backup directory
    if (-not (Test-Path -Path $JKS_BACKUP_DIR)) {
        New-Item -Path $JKS_BACKUP_DIR -ItemType Directory -Force | Out-Null
        Write-Log "Created backup directory: $JKS_BACKUP_DIR"
    }

    $destStoreType = "PKCS12"  # default for new files

    if (Test-Path -Path $JKS_PATH) {
        # Backup
        $backupFile = Join-Path -Path $JKS_BACKUP_DIR -ChildPath "weblogic_$(Get-Date -Format 'yyyyMMdd_HHmmss').jks"
        Copy-Item -Path $JKS_PATH -Destination $backupFile -Force
        Write-Log "Backup: $backupFile"

        # FIX: Detect actual storetype - do NOT trust the file extension.
        # A .jks file may actually be PKCS12. Using wrong -deststoretype causes
        # "Invalid keystore format". Read the real type from keytool output.
        $destStoreType = Get-KeystoreType -KeystoreFile $JKS_PATH -KeystorePassword $JKS_PASSWORD

        # FIX: Do NOT delete the existing alias before importing.
        # Deleting from a PKCS12 keystore breaks its internal MAC integrity,
        # causing "keystore password was incorrect" on the subsequent import
        # even when the password is correct. Instead, import into a fresh temp
        # file and atomically replace the destination (mv/Move-Item).
        Write-Log "Using temp-file import strategy (avoids PKCS12 MAC integrity issues)"
    } else {
        Write-Log "JKS does not exist yet - will create as PKCS12"
    }

    Write-Log "Destination storetype: $destStoreType"

    # =====================================================
    # Step 6: Import PFX into temp keystore
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 6: Importing PFX into keystore"
    Write-Log "=========================================="
    Write-Log "Source PFX:  $pfxFilePath"
    Write-Log "Target JKS:  $JKS_PATH"
    Write-Log "Alias:       $effectiveAlias"
    Write-Log "Storetype:   $destStoreType"

    $tempJks = "$JKS_PATH.tmp_$([System.Diagnostics.Process]::GetCurrentProcess().Id)"

    # FIX: Try 4 import combinations:
    # - With/without -J-Dkeystore.pkcs12.legacy flag
    #   (DigiCert PFX files use older OpenSSL PKCS12 encryption that JDK 11+
    #    rejects by default - the legacy flag makes JDK accept them)
    # - With/without -srcalias/-destalias
    #   (keytool throws error if -destalias is given without -srcalias)
    $importSuccess = $false

    foreach ($useLegacy in @($true, $false)) {
        if (Test-Path $tempJks) { Remove-Item $tempJks -Force }

        $legacyFlag = if ($useLegacy) { "-J-Dkeystore.pkcs12.legacy" } else { $null }

        if (-not [string]::IsNullOrEmpty($srcAlias)) {
            # Known alias: import single entry and rename to effectiveAlias
            $importArgs = @(
                "-importkeystore",
                "-srckeystore",   $pfxFilePath,
                "-srcstoretype",  "pkcs12",
                "-srcstorepass",  $pfxPassword,
                "-srcalias",      $srcAlias,
                "-destkeystore",  $tempJks,
                "-deststoretype", $destStoreType,
                "-deststorepass", $JKS_PASSWORD,
                "-destalias",     $effectiveAlias,
                "-noprompt"
            )
        } else {
            # Unknown alias: import all entries, rename afterward
            $importArgs = @(
                "-importkeystore",
                "-srckeystore",   $pfxFilePath,
                "-srcstoretype",  "pkcs12",
                "-srcstorepass",  $pfxPassword,
                "-destkeystore",  $tempJks,
                "-deststoretype", $destStoreType,
                "-deststorepass", $JKS_PASSWORD,
                "-noprompt"
            )
        }

        if ($legacyFlag) { $importArgs = @($legacyFlag) + $importArgs }

        Write-Log "Trying import (legacy=$useLegacy, srcAlias='$srcAlias')..."
        $result = Invoke-Keytool -Arguments $importArgs
        if ($result.StdOut) { Write-Log "keytool stdout: $($result.StdOut)" }
        if ($result.StdErr) { Write-Log "keytool stderr: $($result.StdErr)" }

        if ($result.ExitCode -eq 0) {
            Write-Log "Import succeeded (legacy=$useLegacy)"
            $importSuccess = $true
            break
        } else {
            Write-Log "Import failed (legacy=$useLegacy, exit=$($result.ExitCode)) - trying next method..."
        }
    }

    if (-not $importSuccess) {
        Write-Log "ERROR: All import methods failed"
        if (Test-Path $tempJks) { Remove-Item $tempJks -Force }
        exit 1
    }

    # If we imported all entries (no srcAlias), rename the PrivateKeyEntry to effectiveAlias
    if ([string]::IsNullOrEmpty($srcAlias)) {
        $listTempResult = Invoke-Keytool @(
            "-list",
            "-keystore", $tempJks,
            "-storepass", $JKS_PASSWORD,
            "-storetype", $destStoreType
        )
        $tempOutput = $listTempResult.StdOut + $listTempResult.StdErr
        $importedAlias = ""
        foreach ($line in ($tempOutput -split "`n")) {
            if ($line -match "PrivateKeyEntry") {
                $importedAlias = ($line -split ",")[0].Trim()
                break
            }
        }
        if (-not [string]::IsNullOrEmpty($importedAlias) -and $importedAlias -ne $effectiveAlias) {
            Write-Log "Renaming imported alias '$importedAlias' to '$effectiveAlias'..."
            $renameResult = Invoke-Keytool @(
                "-changealias",
                "-keystore",  $tempJks,
                "-storepass", $JKS_PASSWORD,
                "-alias",     $importedAlias,
                "-destalias", $effectiveAlias
            )
            if ($renameResult.StdErr) { Write-Log "changealias: $($renameResult.StdErr)" }
            Write-Log "Alias renamed to '$effectiveAlias'"
        }
    }

    # FIX: Atomically replace destination with temp file.
    # This avoids any window where the JKS is absent or corrupt.
    Move-Item -Path $tempJks -Destination $JKS_PATH -Force
    Write-Log "SUCCESS: JKS updated at $JKS_PATH"

    # =====================================================
    # Step 7: Verify import
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 7: Verifying import"
    Write-Log "=========================================="

    $verifyResult = Invoke-Keytool @(
        "-list", "-v",
        "-keystore", $JKS_PATH,
        "-storepass", $JKS_PASSWORD,
        "-alias", $effectiveAlias
    )
    $verifyOutput = $verifyResult.StdOut + $verifyResult.StdErr

    if ($verifyResult.ExitCode -eq 0) {
        Write-Log "SUCCESS: Alias '$effectiveAlias' verified in keystore"
        foreach ($line in ($verifyOutput -split "`n")) {
            if ($line -match "^(Alias name|Owner|Issuer|Valid from|Serial number|Keystore type)") {
                Write-Log "  VERIFY: $($line.Trim())"
            }
        }
    } else {
        Write-Log "WARNING: Could not verify alias '$effectiveAlias'. Checking what is in the keystore..."
        $listAll = Invoke-Keytool @("-list", "-keystore", $JKS_PATH, "-storepass", $JKS_PASSWORD)
        Write-Log $listAll.StdOut
    }

    Write-Log "Keystore:  $JKS_PATH"
    Write-Log "Source PFX: $nonLegacyPfx"
    if (-not [string]::IsNullOrEmpty($legacyPfx)) {
        Write-Log "Legacy PFX (not imported): $legacyPfx"
    }

    # =====================================================
    # Step 8: Restart WebLogic
    # =====================================================
    Write-Log "=========================================="
    Write-Log "Step 8: Restarting WebLogic"
    Write-Log "=========================================="

    $stopScript  = Join-Path -Path $WL_DOMAIN_BIN -ChildPath "stopWebLogic.cmd"
    $startScript = Join-Path -Path $WL_DOMAIN_BIN -ChildPath "startWebLogic.cmd"

    # Stop WebLogic
    if (Test-Path $stopScript) {
        Write-Log "Running: $stopScript"
        $stopProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$stopScript`"" `
            -Wait -PassThru -NoNewWindow
        Write-Log "stopWebLogic.cmd exited with code: $($stopProc.ExitCode)"
    } else {
        Write-Log "WARNING: stopWebLogic.cmd not found at $stopScript - attempting to kill java.exe"
        Get-Process -Name "java" -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -match "weblogic" -or $_.Path -match "jdk" } |
            Stop-Process -Force
    }

    # Wait for WebLogic JVM to fully exit
    Write-Log "Waiting for WebLogic JVM to stop..."
    $stopWait = 0
    while ($stopWait -lt 60) {
        $wlProc = Get-Process -Name "java" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -match "weblogic.Server" }
        if (-not $wlProc) { break }
        Start-Sleep -Seconds 2
        $stopWait += 2
    }
    if ($stopWait -ge 60) {
        Write-Log "WARNING: WebLogic JVM did not stop cleanly - force-killing java.exe..."
        Get-Process -Name "java" -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 3
    }
    Write-Log "WebLogic stopped."

    # Start WebLogic
    if (Test-Path $startScript) {
        Write-Log "Running: $startScript"
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$startScript`"" -WindowStyle Hidden
        Write-Log "startWebLogic.cmd launched in background."
    } else {
        Write-Log "ERROR: startWebLogic.cmd not found at $startScript"
        Write-Log "Please start WebLogic manually."
    }

    # Probe HTTP port until WebLogic responds
    Write-Log "Waiting for WebLogic HTTP port $WL_HTTP_PORT (max ${WL_RESTART_TIMEOUT}s)..."
    $elapsed = 0
    $wlUp    = $false
    while ($elapsed -lt $WL_RESTART_TIMEOUT) {
        if (Test-TcpPort -Port $WL_HTTP_PORT) {
            $wlUp = $true
            break
        }
        Start-Sleep -Seconds 3
        $elapsed += 3
    }

    if ($wlUp) {
        Write-Log "WebLogic HTTP port $WL_HTTP_PORT is responding after ${elapsed}s."
        Start-Sleep -Seconds 5
        if (Test-TcpPort -Port $WL_HTTPS_PORT) {
            Write-Log "SSL port $WL_HTTPS_PORT is responding - new certificate is live."
        } else {
            Write-Log "WARNING: SSL port $WL_HTTPS_PORT not yet responding - WebLogic may still be initialising."
        }
    } else {
        Write-Log "WARNING: WebLogic did not respond within ${WL_RESTART_TIMEOUT}s. Check logs manually."
    }

}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    Write-Log "Stack: $($_.ScriptStackTrace)"
    exit 1
}

Write-Log "=========================================="
Write-Log "Script execution completed"
Write-Log "=========================================="
