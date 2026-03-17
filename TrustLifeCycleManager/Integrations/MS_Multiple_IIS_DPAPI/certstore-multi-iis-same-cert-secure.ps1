<#
===============================================================================
Legal Notice (version January 1, 2026)
===============================================================================
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
===============================================================================
#>

# Legal notice acceptance variable (user must set to $true to accept and allow script execution)
$LEGAL_NOTICE_ACCEPT = $false  # Change this to $true to accept the legal notice and run the script

# DigiCert TLM Agent Post-Script: IIS Certificate Binding (Local + Remote)
# Drop into: C:\Program Files\DigiCert\TLM Agent\user-scripts\
# Logs to:   C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log
#
# ==============================================================================
#  SECURITY: HOW CREDENTIALS ARE PROTECTED
# ==============================================================================
#
#  This script uses Windows DPAPI (Data Protection API) to secure the remote
#  account password. DPAPI encrypts using AES-256, with the encryption key
#  derived from three factors combined:
#
#    1. The identity of the SYSTEM account on this machine
#    2. This machine's unique LSA (Local Security Authority) secret
#       - stored in the registry and protected by the OS (TPM-backed if
#         a TPM chip is present)
#    3. A random entropy value generated at the time of encryption
#
#  This means the encrypted blob in tlm-creds.txt:
#    - Cannot be decrypted on any other machine (wrong LSA secret)
#    - Cannot be decrypted under any other account (wrong identity)
#    - Cannot be brute-forced without the machine's LSA secret
#    - Never contains the plaintext password at any point on disk
#
#  Encryption flow:
#    Password (in memory only, never written)
#        |
#        v  ConvertFrom-SecureString - DPAPI AES-256 encrypt
#    Encrypted blob ---> tlm-creds.txt  (safe to exist on disk)
#
#  Decryption flow at runtime:
#    tlm-creds.txt (encrypted blob)
#        |
#        v  ConvertTo-SecureString - DPAPI AES-256 decrypt
#    SecureString in memory ---> PSCredential ---> New-PSSession
#        (never written to disk or log)
#
# ==============================================================================
#  ONE-TIME CREDENTIAL FILE SETUP  (run once as Administrator, then never again)
# ==============================================================================
#
#  Step 1 - Create the encrypted credential file as SYSTEM via Task Scheduler.
#            Update $domain, $username, and $password before running:
#
#       $domain   = "LAB"
#       $username = "PKIAdmin"
#       $password = "YourPasswordHere"
#
#       $cmd = @"
#       `$securePass = ConvertTo-SecureString -String '$password' -Force -AsPlainText
#       `$encrypted  = ConvertFrom-SecureString -SecureString `$securePass
#       `$outPath    = 'C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt'
#       Set-Content -Path `$outPath -Value '${domain}\${username}|' -NoNewline
#       Add-Content -Path `$outPath -Value `$encrypted
#       "@
#
#       $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command `"$cmd`""
#       $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(10)
#       $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
#       $settings  = New-ScheduledTaskSettingsSet
#       Register-ScheduledTask -TaskName "CreateTLMCreds" -Action $action -Trigger $trigger `
#           -Settings $settings -Principal $principal -Force
#       Start-Sleep -Seconds 20
#       Unregister-ScheduledTask -TaskName "CreateTLMCreds" -Confirm:$false
#
#  Step 2 - Verify the file contains an encrypted blob, NOT your plaintext password:
#
#       Get-Content "C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt"
#       # Should look like: LAB\PKIAdmin|01000000d08c9ddf0115d1118c7a00c04...
#       # If you see your actual password here, something went wrong - redo Step 1.
#
#  Step 3 - Lock the file to SYSTEM and Administrators only:
#
#       $credsPath = "C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt"
#       $acl = Get-Acl $credsPath
#       $acl.SetAccessRuleProtection($true, $false)
#       $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
#       $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","Allow")))
#       $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators","FullControl","Allow")))
#       Set-Acl -Path $credsPath -AclObject $acl
#
#  Step 4 - To rotate the password, simply re-run Step 1 with the new password.
#           The new encrypted blob will overwrite the old one. No script changes needed.
#
# ==============================================================================
$ErrorActionPreference = "Stop"

# -- Config --------------------------------------------------------------------
$LogFilePath = "C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log"
$SecretsDir  = "C:\Program Files\DigiCert\TLM Agent\.secrets"
$CredsFile   = "C:\Program Files\DigiCert\TLM Agent\user-scripts\tlm-creds.txt"

# Local IIS site bindings on THIS server (where TLM Agent runs).
# Format: "Site Name" = Port
# Use "Default Web Site" for the default, or any custom IIS site name.
$LocalSiteBindings = @{
    "Default Web Site" = 443
}

# Remote servers to push the cert to via WinRM.
# Each entry defines the server and which IIS sites to bind on that server.
# Add, remove, or change site names and ports per server as needed.
$RemoteServers = @(
    @{
        Server       = "web01.lab.com"
        SiteBindings = @{
            "Default Web Site" = 443
            # "My Custom Site" = 8443   # <- uncomment and edit for a custom site
        }
    },
    @{
        Server       = "exchange1.lab.com"
        SiteBindings = @{
            "Default Web Site" = 443
            # "My Custom Site" = 8443
        }
    }
)

# -- Logging -------------------------------------------------------------------
function Log-Message {
    param (
        [string]$message,
        [string]$logFilePath = "C:\Program Files\DigiCert\TLM Agent\user-scripts\debug.log"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "$timestamp : $message"
    Add-Content -Path $logFilePath -Value $logEntry
    Write-Host $message
}

# -- Base64 decode -------------------------------------------------------------
function Decode-Base64 {
    param ([string]$base64String)
    $bytes = [System.Convert]::FromBase64String($base64String)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# -- Legal notice check --------------------------------------------------------
Log-Message "DigiCert TLM Post-Script starting..."

if ($LEGAL_NOTICE_ACCEPT -ne $true) {
    Log-Message "ERROR: Script execution halted - Legal notice not accepted"
    Log-Message "User must set `$LEGAL_NOTICE_ACCEPT = `$true to proceed"
    Log-Message "Script terminated due to legal notice non-acceptance"
    exit 1
}

Log-Message "Legal notice accepted - proceeding with script execution"

# -- STEP 1: Load and decrypt remote credentials -------------------------------

if (-not (Test-Path $CredsFile)) {
    Log-Message "ERROR: Credentials file not found: $CredsFile"
    Log-Message "ERROR: See the setup instructions at the top of this script."
    exit 1
}

try {
    # Use ReadAllText to read the entire file as one string regardless of line breaks,
    # then strip all whitespace/newlines from the blob so DPAPI gets a clean input.
    $credsRaw   = [System.IO.File]::ReadAllText($CredsFile).Trim()
    $splitIndex = $credsRaw.IndexOf('|')

    if ($splitIndex -le 0) {
        throw "Credentials file must be in the format: DOMAIN\Username|<encrypted blob>"
    }

    $remoteUsername = $credsRaw.Substring(0, $splitIndex).Trim()
    $encryptedBlob  = ($credsRaw.Substring($splitIndex + 1)) -replace '[\s\r\n]', ''

    if ([string]::IsNullOrEmpty($remoteUsername) -or [string]::IsNullOrEmpty($encryptedBlob)) {
        throw "Credentials file must be in the format: DOMAIN\Username|<encrypted blob>"
    }

    # ConvertTo-SecureString with no -AsPlainText decrypts a DPAPI-encrypted blob.
    # This only works when running as the same account (SYSTEM) on the same machine
    # that originally encrypted it - anyone else gets a decryption failure.
    $remotePassword = ConvertTo-SecureString -String $encryptedBlob -ErrorAction Stop
    $remoteCred     = New-Object System.Management.Automation.PSCredential($remoteUsername, $remotePassword)

    Log-Message "Remote credentials loaded and decrypted for account: $remoteUsername"
} catch {
    Log-Message "ERROR: Failed to load or decrypt credentials from $CredsFile. $_"
    Log-Message "ERROR: Ensure the credential file was created as SYSTEM on this machine."
    exit 1
}

# -- STEP 2: Decode DC1_POST_SCRIPT_DATA ---------------------------------------
$base64Json = [System.Environment]::GetEnvironmentVariable("DC1_POST_SCRIPT_DATA")

if ([string]::IsNullOrEmpty($base64Json)) {
    Log-Message "ERROR: DC1_POST_SCRIPT_DATA is empty. Ensure this is configured as a Post-Script in TLM Agent."
    exit 1
}

try {
    $jsonString = Decode-Base64 -base64String $base64Json
    Log-Message "Decoded JSON: $jsonString"
    $jsonObject = $jsonString | ConvertFrom-Json
} catch {
    Log-Message "ERROR: Failed to decode DC1_POST_SCRIPT_DATA. $_"
    exit 1
}

$pfxFileName = $jsonObject.files[0]
$pfxPassword = $jsonObject.password

Log-Message "Searching for PFX '$pfxFileName' under: $SecretsDir"

# TLM Agent delivers the PFX inside a timestamped subfolder, e.g.:
#   .secrets\iis4servers.lab.com_pfx_2026_03_13_14_40_56\iis4servers.lab.com.pfx
$pfxMatches = Get-ChildItem -Path $SecretsDir -Recurse -Filter $pfxFileName -File -ErrorAction SilentlyContinue |
              Sort-Object CreationTime -Descending

if (-not $pfxMatches) {
    Log-Message "ERROR: PFX file '$pfxFileName' not found anywhere under $SecretsDir"
    exit 1
}

$pfxFilePath = $pfxMatches[0].FullName
$archiveDir  = $pfxMatches[0].DirectoryName

Log-Message "PFX found   : $pfxFilePath"
Log-Message "Archive dir : $archiveDir"
Log-Message "PFX size    : $((Get-Item $pfxFilePath).Length) bytes"

# -- STEP 3: Read CN from PFX --------------------------------------------------
try {
    $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
        $pfxFilePath,
        $pfxPassword,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::DefaultKeySet
    )
    $commonName = ($x509.Subject -replace "^CN=([^,]+).*", '$1').Trim()
    Log-Message "Certificate CN      : $commonName"
    Log-Message "Certificate Expires : $($x509.NotAfter)"
} catch {
    Log-Message "WARNING: Could not read CN from PFX, using filename. $_"
    $commonName = [System.IO.Path]::GetFileNameWithoutExtension($pfxFileName)
}

# -- STEP 4: Import PFX into LOCAL LocalMachine\My ----------------------------
try {
    $pfxSecure = ConvertTo-SecureString -String $pfxPassword -Force -AsPlainText

    $cert = Import-PfxCertificate `
        -FilePath          $pfxFilePath `
        -CertStoreLocation Cert:\LocalMachine\My `
        -Password          $pfxSecure `
        -Exportable

    if ($null -eq $cert) { throw "Import-PfxCertificate returned null." }

    $thumbprint = $cert.Thumbprint
    Log-Message "Certificate imported locally. Thumbprint: $thumbprint"
} catch {
    Log-Message "ERROR: Failed to import certificate locally. $_"
    exit 1
}

# -- STEP 5: Bind cert on LOCAL IIS --------------------------------------------
Log-Message "Binding certificate on local server..."
try {
    Import-Module WebAdministration -ErrorAction Stop

    foreach ($siteName in $LocalSiteBindings.Keys) {
        $port = $LocalSiteBindings[$siteName]
        Log-Message "Processing local IIS site '$siteName' on port $port..."

        $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
        if (-not $site) {
            Log-Message "WARNING [LOCAL]: IIS site '$siteName' not found, skipping."
            continue
        }

        $binding = Get-WebBinding -Name $siteName -Protocol https |
                   Where-Object { $_.bindingInformation -like "*:${port}:*" }

        if (-not $binding) {
            Log-Message "No HTTPS binding on port $port for '$siteName'. Creating binding."
            New-WebBinding -Name $siteName -Protocol https -Port $port -IPAddress "*" -SslFlags 0
            $binding = Get-WebBinding -Name $siteName -Protocol https |
                       Where-Object { $_.bindingInformation -like "*:${port}:*" }
        }

        $binding.AddSslCertificate($thumbprint, "My")
        Log-Message "LOCAL: '$siteName':$port bound to thumbprint $thumbprint"
    }
} catch {
    Log-Message "ERROR: Local IIS binding failed. $_"
    exit 1
}

Log-Message "Restarting local IIS..."
try {
    & iisreset /restart /noforce | Out-Null
    Log-Message "Local IIS restarted successfully."
} catch {
    Log-Message "WARNING: Local IIS restart failed. $_"
}

foreach ($siteName in $LocalSiteBindings.Keys) {
    $port = $LocalSiteBindings[$siteName]
    try {
        $netshOut = (& netsh http show sslcert ipport="0.0.0.0:$port" 2>&1) | Out-String
        if ($netshOut -match $thumbprint.ToLower()) {
            Log-Message "VERIFIED [LOCAL]: '$siteName':$port is using the correct certificate."
        } else {
            Log-Message "WARNING [LOCAL]: '$siteName':$port thumbprint mismatch. Check IIS bindings manually."
        }
    } catch {
        Log-Message "WARNING [LOCAL]: Could not verify '$siteName':$port. $_"
    }
}

# -- STEP 6: Push cert to REMOTE servers and bind ------------------------------
foreach ($entry in $RemoteServers) {
    $server        = $entry.Server
    $siteBindings  = $entry.SiteBindings
    $remotePfxPath = "C:\Windows\Temp\$pfxFileName"

    Log-Message "--- Connecting to remote server: $server ---"

    try {
        $session = New-PSSession -ComputerName $server -Credential $remoteCred -ErrorAction Stop
        Log-Message "[$server] WinRM session established."
    } catch {
        Log-Message "ERROR [$server]: Could not connect via WinRM. $_"
        continue
    }

    try {
        # -- Copy PFX using Copy-Item over the PSSession (reliable for binary files) --
        Log-Message "[$server] Copying PFX to $remotePfxPath ..."
        Copy-Item -Path $pfxFilePath -Destination $remotePfxPath -ToSession $session -Force -ErrorAction Stop
        Log-Message "[$server] PFX copy complete."

        # -- Confirm the file arrived and is the right size ------------------------
        $remoteSize = Invoke-Command -Session $session -ScriptBlock {
            param($path)
            if (Test-Path $path) { (Get-Item $path).Length } else { -1 }
        } -ArgumentList $remotePfxPath

        $localSize = (Get-Item $pfxFilePath).Length
        $sizeLog = "[$server] PFX size check - local=" + $localSize + " bytes, remote=" + $remoteSize + " bytes."
        Log-Message $sizeLog

        if ($remoteSize -ne $localSize) {
            $sizeMsg = "PFX file size mismatch after copy (local=" + $localSize + ", remote=" + $remoteSize + "). Aborting."
            throw $sizeMsg
        }

        Log-Message "[$server] PFX verified on remote. Proceeding with import and binding..."

        # -- Import cert, bind IIS, restart, verify on the remote server -----------
        $remoteOutput = Invoke-Command -Session $session -ScriptBlock {
            param($pfxPath, $pfxPassword, $thumbprint, $siteBindings, $server)

            $pfxSecure = ConvertTo-SecureString -String $pfxPassword -Force -AsPlainText

            Write-Output "[$server] Importing certificate from $pfxPath ..."
            $cert = Import-PfxCertificate `
                -FilePath          $pfxPath `
                -CertStoreLocation Cert:\LocalMachine\My `
                -Password          $pfxSecure `
                -Exportable

            if ($null -eq $cert) { throw "Import-PfxCertificate returned null on $server." }
            Write-Output "[$server] Certificate imported. Thumbprint: $($cert.Thumbprint)"

            Import-Module WebAdministration -ErrorAction Stop
            Write-Output "[$server] WebAdministration module loaded."

            foreach ($siteName in $siteBindings.Keys) {
                $port = $siteBindings[$siteName]
                Write-Output "[$server] Processing IIS site '$siteName' on port $port..."

                $site = Get-Website -Name $siteName -ErrorAction SilentlyContinue
                if (-not $site) {
                    Write-Output "[$server] WARNING: IIS site '$siteName' not found, skipping."
                    continue
                }

                $binding = Get-WebBinding -Name $siteName -Protocol https |
                           Where-Object { $_.bindingInformation -like "*:${port}:*" }

                if (-not $binding) {
                    Write-Output "[$server] No HTTPS binding on port $port for '$siteName'. Creating binding."
                    New-WebBinding -Name $siteName -Protocol https -Port $port -IPAddress "*" -SslFlags 0
                    $binding = Get-WebBinding -Name $siteName -Protocol https |
                               Where-Object { $_.bindingInformation -like "*:${port}:*" }
                }

                $binding.AddSslCertificate($thumbprint, "My")
                Write-Output "[$server] '$siteName':$port bound to thumbprint $thumbprint"
            }

            Write-Output "[$server] Restarting IIS..."
            & iisreset /restart /noforce | Out-Null
            Write-Output "[$server] IIS restarted."

            foreach ($siteName in $siteBindings.Keys) {
                $port = $siteBindings[$siteName]
                $netshOut = (& netsh http show sslcert ipport="0.0.0.0:$port" 2>&1) | Out-String
                if ($netshOut -match $thumbprint.ToLower()) {
                    Write-Output "VERIFIED [$server]: '$siteName':$port is using the correct certificate."
                } else {
                    Write-Output "WARNING [$server]: '$siteName':$port thumbprint mismatch. Check IIS bindings manually."
                }
            }

            Remove-Item -Path $pfxPath -Force -ErrorAction SilentlyContinue
            Write-Output "[$server] Temp PFX removed."

        } -ArgumentList $remotePfxPath, $pfxPassword, $thumbprint, $siteBindings, $server

        $remoteOutput | ForEach-Object { Log-Message $_ }

    } catch {
        Log-Message "ERROR [$server]: Remote operation failed. $_"
    } finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        Log-Message "[$server] WinRM session closed."
    }
}

# -- Done ----------------------------------------------------------------------
Log-Message "COMPLETE: Certificate replacement finished. CN=$($commonName) Thumbprint=$($thumbprint) Archive=$($archiveDir)"
exit 0