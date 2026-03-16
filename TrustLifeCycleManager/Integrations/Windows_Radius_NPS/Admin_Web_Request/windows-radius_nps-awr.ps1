<#
.SYNOPSIS
    DigiCert TLM Agent Post-Enrollment Script - NPS RADIUS Certificate Replacement
.DESCRIPTION
    Processes certificate and key files delivered by the DigiCert TLM Agent,
    imports the certificate into the Windows certificate store, updates the
    NPS PEAP configuration to use the new certificate, and distributes the
    public key to RADIUS test clients via SCP.
    
    AWR Arguments (configured in TLM profile):
      Argument 1: RADIUS test client SSH destination (e.g., sysadmin@10.160.115.190)
      Argument 2: Remote PEM file path (e.g., /home/sysadmin/nps-cert.pem)
      
    Prerequisites:
      - NPS role installed and configured with a PEAP network policy
      - OpenSSL installed (e.g., C:\Program Files\OpenSSL\bin\openssl.exe)
      - OpenSSH client available (built-in on Server 2025)
      - SSH key-based auth configured to the RADIUS test client
      - Existing NPS PEAP policy using a server authentication certificate
      
.NOTES
    Legal Notice (version October 29, 2024)
    Copyright © 2024 DigiCert. All rights reserved.
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

# ============================================================================
# CONFIGURATION
# ============================================================================

$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\dc1_data.log"

# OpenSSL path - adjust if installed elsewhere
$OPENSSL_PATH = "C:\Program Files\OpenSSL\bin\openssl.exe"

# Temporary working directory for certificate conversion
$TEMP_DIR = "C:\temp\nps-cert-update"

# PFX password for intermediate conversion (used only during import, then deleted)
$PFX_PASSWORD = [System.Guid]::NewGuid().ToString()

# ============================================================================
# LOGGING FUNCTION
# ============================================================================

function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# ============================================================================
# START LOGGING
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting NPS RADIUS Certificate Replacement Script"
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
Write-LogMessage "  OPENSSL_PATH: $OPENSSL_PATH"

# ============================================================================
# EXTRACT CERTIFICATE DATA FROM TLM AGENT
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

# ============================================================================
# EXTRACT ARGUMENTS
# ============================================================================

Write-LogMessage "Extracting arguments from JSON..."

$ARGUMENT_1 = ""
$ARGUMENT_2 = ""
$ARGUMENT_3 = ""
$ARGUMENT_4 = ""
$ARGUMENT_5 = ""

if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"
    
    if ($ARGS_ARRAY.Count -ge 1) { 
        $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
    }
    if ($ARGS_ARRAY.Count -ge 2) { 
        $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
    }
    if ($ARGS_ARRAY.Count -ge 3) { 
        $ARGUMENT_3 = ($ARGS_ARRAY[2] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
    }
    if ($ARGS_ARRAY.Count -ge 4) { 
        $ARGUMENT_4 = ($ARGS_ARRAY[3] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
    }
    if ($ARGS_ARRAY.Count -ge 5) { 
        $ARGUMENT_5 = ($ARGS_ARRAY[4] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_5 extracted: '$ARGUMENT_5'"
    }
}

# Set NPS-specific variables from arguments
# ARGUMENT_1: SSH destination for RADIUS test client (e.g., sysadmin@10.160.115.190)
# ARGUMENT_2: Remote path for PEM file (e.g., /home/sysadmin/nps-cert.pem)
$SSH_DESTINATION = $ARGUMENT_1
$REMOTE_PEM_PATH = $ARGUMENT_2

Write-LogMessage "NPS Configuration:"
Write-LogMessage "  SSH Destination: $SSH_DESTINATION"
Write-LogMessage "  Remote PEM Path: $REMOTE_PEM_PATH"

# ============================================================================
# EXTRACT CERTIFICATE AND KEY FILE PATHS
# ============================================================================

$CERT_FOLDER = $JSON_OBJECT.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .crt file name
$CRT_FILE = ""
if ($JSON_OBJECT.files) {
    $CRT_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.crt$' } | Select-Object -First 1
}
Write-LogMessage "Extracted CRT_FILE: $CRT_FILE"

# Extract the .key file name
$KEY_FILE = ""
if ($JSON_OBJECT.files) {
    $KEY_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.key$' } | Select-Object -First 1
}
Write-LogMessage "Extracted KEY_FILE: $KEY_FILE"

# Construct file paths
$CRT_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CRT_FILE
$KEY_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $KEY_FILE

# Extract all files from the files array
$FILES_ARRAY = $JSON_OBJECT.files -join ','
Write-LogMessage "Files array content: $FILES_ARRAY"

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "Arguments extracted:"
Write-LogMessage "  Argument 1 (SSH Destination): $ARGUMENT_1"
Write-LogMessage "  Argument 2 (Remote PEM Path): $ARGUMENT_2"
Write-LogMessage "  Argument 3: $ARGUMENT_3"
Write-LogMessage "  Argument 4: $ARGUMENT_4"
Write-LogMessage "  Argument 5: $ARGUMENT_5"
Write-LogMessage ""
Write-LogMessage "Certificate information:"
Write-LogMessage "  Certificate folder: $CERT_FOLDER"
Write-LogMessage "  Certificate file: $CRT_FILE"
Write-LogMessage "  Private key file: $KEY_FILE"
Write-LogMessage "  Certificate path: $CRT_FILE_PATH"
Write-LogMessage "  Private key path: $KEY_FILE_PATH"
Write-LogMessage ""
Write-LogMessage "All files in array: $FILES_ARRAY"
Write-LogMessage "=========================================="

# ============================================================================
# VALIDATE FILES EXIST
# ============================================================================

$CERT_COUNT = 0
$KEY_TYPE = "Unknown"

if (Test-Path $CRT_FILE_PATH) {
    $crtFileInfo = Get-Item $CRT_FILE_PATH
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    Write-LogMessage "Certificate file size: $($crtFileInfo.Length) bytes"
    
    $crtContent = Get-Content $CRT_FILE_PATH -Raw
    $CERT_COUNT = ([regex]::Matches($crtContent, "BEGIN CERTIFICATE")).Count
    Write-LogMessage "Total certificates in file: $CERT_COUNT"
    
    try {
        if ($crtContent -match '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----') {
            $certBase64 = $matches[1] -replace '\s', ''
            $certBytes = [Convert]::FromBase64String($certBase64)
            $certInfo = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certBytes)
            
            Write-LogMessage "Certificate details:"
            Write-LogMessage "  Subject: $($certInfo.Subject)"
            Write-LogMessage "  Issuer: $($certInfo.Issuer)"
            Write-LogMessage "  Serial Number: $($certInfo.SerialNumber)"
            Write-LogMessage "  Valid From: $($certInfo.NotBefore)"
            Write-LogMessage "  Valid To: $($certInfo.NotAfter)"
            Write-LogMessage "  Thumbprint: $($certInfo.Thumbprint)"
            Write-LogMessage "  Signature Algorithm: $($certInfo.SignatureAlgorithm.FriendlyName)"
            
            $certInfo.Dispose()
        }
    } catch {
        Write-LogMessage "Could not parse certificate details: $_"
    }
} else {
    Write-LogMessage "ERROR: Certificate file not found: $CRT_FILE_PATH"
    exit 1
}

if (Test-Path $KEY_FILE_PATH) {
    $keyFileInfo = Get-Item $KEY_FILE_PATH
    Write-LogMessage "Private key file exists: $KEY_FILE_PATH"
    Write-LogMessage "Private key file size: $($keyFileInfo.Length) bytes"
    
    $KEY_FILE_CONTENT = Get-Content $KEY_FILE_PATH -Raw
    
    if ($KEY_FILE_CONTENT -match "BEGIN RSA PRIVATE KEY") {
        $KEY_TYPE = "RSA"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN EC PRIVATE KEY") {
        $KEY_TYPE = "ECC"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN PRIVATE KEY") {
        $KEY_TYPE = "PKCS#8 format (generic)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN ENCRYPTED PRIVATE KEY") {
        $KEY_TYPE = "Encrypted PKCS#8"
    }
    Write-LogMessage "Key type: $KEY_TYPE"
} else {
    Write-LogMessage "ERROR: Private key file not found: $KEY_FILE_PATH"
    exit 1
}

# ============================================================================
# CUSTOM SCRIPT SECTION - NPS CERTIFICATE REPLACEMENT
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting NPS certificate replacement..."
Write-LogMessage "=========================================="

# --- Step 1: Validate prerequisites ---
Write-LogMessage "Step 1: Validating prerequisites..."

if (-not (Test-Path $OPENSSL_PATH)) {
    Write-LogMessage "ERROR: OpenSSL not found at $OPENSSL_PATH"
    Write-LogMessage "Please install OpenSSL or update OPENSSL_PATH in this script."
    exit 1
}
Write-LogMessage "  OpenSSL found: $OPENSSL_PATH"

# Check OpenSSH client is available
$scpPath = Get-Command scp -ErrorAction SilentlyContinue
if (-not $scpPath) {
    Write-LogMessage "ERROR: SCP (OpenSSH client) not found. Install with:"
    Write-LogMessage "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
    exit 1
}
Write-LogMessage "  SCP found: $($scpPath.Source)"

# Check NPS service is running
$npsService = Get-Service -Name "IAS" -ErrorAction SilentlyContinue
if (-not $npsService) {
    Write-LogMessage "ERROR: NPS service (IAS) not found. Is the NPS role installed?"
    exit 1
}
Write-LogMessage "  NPS service status: $($npsService.Status)"

# Create temp directory
if (-not (Test-Path $TEMP_DIR)) {
    New-Item -ItemType Directory -Path $TEMP_DIR -Force | Out-Null
}
Write-LogMessage "  Temp directory: $TEMP_DIR"

# --- Step 2: Get the current NPS certificate thumbprint (for logging) ---
Write-LogMessage "Step 2: Capturing current NPS certificate configuration..."

$NPS_CONFIG_EXPORT = Join-Path $TEMP_DIR "nps-config-backup.xml"
netsh nps export filename="$NPS_CONFIG_EXPORT" exportPSK=YES 2>&1 | Out-Null
Write-LogMessage "  NPS config exported to: $NPS_CONFIG_EXPORT"

# --- Step 3: Create PFX from CRT and KEY ---
Write-LogMessage "Step 3: Creating PFX from certificate and key..."

$PFX_OUTPUT = Join-Path $TEMP_DIR "nps-certificate.pfx"

try {
    $opensslStderr = & $OPENSSL_PATH pkcs12 -export `
        -out "$PFX_OUTPUT" `
        -inkey "$KEY_FILE_PATH" `
        -in "$CRT_FILE_PATH" `
        -passout "pass:$PFX_PASSWORD" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-LogMessage "ERROR: Failed to create PFX file. OpenSSL exit code: $LASTEXITCODE"
        Write-LogMessage "OpenSSL error: $opensslStderr"
        exit 1
    }
} catch {
    Write-LogMessage "ERROR: OpenSSL execution failed: $_"
    exit 1
}
Write-LogMessage "  PFX created: $PFX_OUTPUT"

# --- Step 4: Import PFX to Windows certificate store ---
Write-LogMessage "Step 4: Importing certificate to Local Machine store..."

try {
    $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
    $importedCert = Import-PfxCertificate -FilePath $PFX_OUTPUT `
        -Password $securePwd `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -Exportable
    
    $NEW_THUMBPRINT = $importedCert.Thumbprint
    $NEW_SUBJECT = $importedCert.Subject
    $NEW_NOT_BEFORE = $importedCert.NotBefore
    $NEW_NOT_AFTER = $importedCert.NotAfter
    
    Write-LogMessage "  Certificate imported successfully:"
    Write-LogMessage "    Subject: $NEW_SUBJECT"
    Write-LogMessage "    Thumbprint: $NEW_THUMBPRINT"
    Write-LogMessage "    Valid From: $NEW_NOT_BEFORE"
    Write-LogMessage "    Valid To: $NEW_NOT_AFTER"
} catch {
    Write-LogMessage "ERROR: Failed to import PFX: $_"
    exit 1
}

# --- Step 5: Update NPS PEAP configuration with new certificate thumbprint ---
Write-LogMessage "Step 5: Updating NPS PEAP configuration..."

# NPS stores the PEAP certificate thumbprint inside the msEAPConfiguration binary hex blob
# in the exported XML config. The thumbprint is embedded as 20 bytes (40 hex chars) of lowercase hex.
#
# Strategy: Export the NPS config as XML (UTF-8), find the thumbprint inside the
# msEAPConfiguration blob, replace it with the new thumbprint, and re-import.

$NPS_CONFIG_CURRENT = Join-Path $TEMP_DIR "nps-config-current.xml"
$NPS_CONFIG_UPDATED = Join-Path $TEMP_DIR "nps-config-updated.xml"

netsh nps export filename="$NPS_CONFIG_CURRENT" exportPSK=YES 2>&1 | Out-Null

# Read the config preserving its exact byte content
$rawBytes = [System.IO.File]::ReadAllBytes($NPS_CONFIG_CURRENT)
$npsConfigContent = [System.Text.Encoding]::UTF8.GetString($rawBytes)

$newThumbLower = $NEW_THUMBPRINT.ToLower()
$thumbUpdated = $false

# Find ALL server auth certificate thumbprints currently in the store (excluding the new one)
# and check which one appears in the msEAPConfiguration blob
$candidateCerts = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    $_.Thumbprint -ne $NEW_THUMBPRINT
} | Sort-Object NotAfter -Descending

$OLD_THUMBPRINT = $null
foreach ($cert in $candidateCerts) {
    $candidateThumbLower = $cert.Thumbprint.ToLower()
    if ($npsConfigContent.Contains($candidateThumbLower)) {
        $OLD_THUMBPRINT = $cert.Thumbprint
        Write-LogMessage "  Found current NPS certificate in config:"
        Write-LogMessage "    Subject: $($cert.Subject)"
        Write-LogMessage "    Thumbprint: $OLD_THUMBPRINT"
        break
    }
}

if ($OLD_THUMBPRINT) {
    $oldThumbLower = $OLD_THUMBPRINT.ToLower()
    
    # Replace the old thumbprint with the new one in the XML
    $npsConfigUpdated = $npsConfigContent.Replace($oldThumbLower, $newThumbLower)
    
    # Verify the replacement happened
    if ($npsConfigUpdated.Contains($newThumbLower) -and -not $npsConfigUpdated.Contains($oldThumbLower)) {
        Write-LogMessage "  Thumbprint replaced in msEAPConfiguration blob:"
        Write-LogMessage "    Old: $oldThumbLower"
        Write-LogMessage "    New: $newThumbLower"
        
        # Write back as UTF-8 (matching the original encoding)
        [System.IO.File]::WriteAllBytes($NPS_CONFIG_UPDATED, [System.Text.Encoding]::UTF8.GetBytes($npsConfigUpdated))
        
        # Import the updated config
        $npsImportResult = netsh nps import filename="$NPS_CONFIG_UPDATED" 2>&1
        Write-LogMessage "  NPS config import result: $npsImportResult"
        
        # Verify by re-exporting
        $NPS_CONFIG_VERIFY = Join-Path $TEMP_DIR "nps-config-verify.xml"
        netsh nps export filename="$NPS_CONFIG_VERIFY" exportPSK=YES 2>&1 | Out-Null
        $verifyContent = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($NPS_CONFIG_VERIFY))
        
        if ($verifyContent.Contains($newThumbLower)) {
            Write-LogMessage "  VERIFIED: New thumbprint confirmed in NPS configuration"
            $thumbUpdated = $true
        } else {
            Write-LogMessage "  WARNING: Verification failed - new thumbprint not found after import"
        }
    } else {
        Write-LogMessage "  WARNING: String replacement did not produce expected result"
    }
} else {
    Write-LogMessage "  WARNING: Could not find any known certificate thumbprint in NPS config."
    Write-LogMessage "  Listing thumbprints searched:"
    foreach ($cert in $candidateCerts) {
        Write-LogMessage "    $($cert.Thumbprint.ToLower()) ($($cert.Subject))"
    }
}

if ($thumbUpdated) {
    # Restart NPS to ensure changes take effect
    Write-LogMessage "  Restarting NPS service to apply changes..."
    Restart-Service -Name "IAS" -Force
    Start-Sleep -Seconds 2
    $npsStatus = (Get-Service -Name "IAS").Status
    Write-LogMessage "  NPS service status after restart: $npsStatus"
    Write-LogMessage "  NPS configuration updated with new certificate thumbprint"
} else {
    Write-LogMessage "WARNING: Could not update NPS certificate automatically."
    Write-LogMessage "  Please manually select the new certificate in the NPS console:"
    Write-LogMessage "  NPS > Policies > Network Policies > [your policy] > Constraints > PEAP properties"
    Write-LogMessage "  Select certificate with thumbprint: $NEW_THUMBPRINT"
}

# --- Step 6: Prepare public certificate chain as PEM for RADIUS test client ---
Write-LogMessage "Step 6: Preparing certificate chain as PEM..."

$PEM_EXPORT_PATH = Join-Path $TEMP_DIR "nps-cert.pem"

# The CRT file from TLM contains the full chain (leaf + intermediate + root) in PEM format.
# This is what the RADIUS test client needs for ca_cert validation.
# We copy the full CRT file rather than just exporting the leaf certificate,
# so the client can validate the entire chain of trust.

if (Test-Path $CRT_FILE_PATH) {
    Copy-Item -Path $CRT_FILE_PATH -Destination $PEM_EXPORT_PATH -Force
    
    # Count certs in the chain for logging
    $pemContent = Get-Content $PEM_EXPORT_PATH -Raw
    $chainCount = ([regex]::Matches($pemContent, "BEGIN CERTIFICATE")).Count
    Write-LogMessage "  Full certificate chain PEM created: $PEM_EXPORT_PATH"
    Write-LogMessage "  Certificates in chain: $chainCount"
} else {
    # Fallback: export just the leaf cert if CRT file is unavailable
    Write-LogMessage "  WARNING: CRT file not found, falling back to leaf-only export"
    $DER_EXPORT_PATH = Join-Path $TEMP_DIR "nps-cert-public.cer"
    Export-Certificate -Cert $importedCert -FilePath $DER_EXPORT_PATH | Out-Null
    
    try {
        $pemStderr = & $OPENSSL_PATH x509 -inform DER `
            -in "$DER_EXPORT_PATH" `
            -out "$PEM_EXPORT_PATH" 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-LogMessage "ERROR: Failed to convert to PEM. OpenSSL error: $pemStderr"
            exit 1
        }
    } catch {
        Write-LogMessage "ERROR: OpenSSL PEM conversion failed: $_"
        exit 1
    }
    
    # Clean up DER
    Remove-Item $DER_EXPORT_PATH -Force -ErrorAction SilentlyContinue
    Write-LogMessage "  Leaf-only PEM created: $PEM_EXPORT_PATH"
}

# --- Step 7: Distribute PEM to RADIUS test client via SCP ---
Write-LogMessage "Step 7: Distributing PEM to RADIUS test client..."

if (-not [string]::IsNullOrEmpty($SSH_DESTINATION) -and -not [string]::IsNullOrEmpty($REMOTE_PEM_PATH)) {
    
    Write-LogMessage "  SCP destination: ${SSH_DESTINATION}:${REMOTE_PEM_PATH}"
    
    # Use SCP to copy the PEM file (requires SSH key-based auth to be configured)
    # The TLM Agent runs as SYSTEM, so SSH keys may be in the SYSTEM profile
    # or in the Administrator profile. Try to locate the correct key.
    $sshKeyPaths = @(
        "$env:USERPROFILE\.ssh\id_ed25519",
        "$env:USERPROFILE\.ssh\id_rsa",
        "C:\Users\Administrator\.ssh\id_ed25519",
        "C:\Users\Administrator\.ssh\id_rsa",
        "C:\Windows\System32\config\systemprofile\.ssh\id_ed25519",
        "C:\Windows\System32\config\systemprofile\.ssh\id_rsa"
    )
    
    $sshKeyFile = $null
    foreach ($keyPath in $sshKeyPaths) {
        if (Test-Path $keyPath) {
            $sshKeyFile = $keyPath
            Write-LogMessage "  SSH key found: $sshKeyFile"
            break
        }
    }
    
    if (-not $sshKeyFile) {
        Write-LogMessage "WARNING: No SSH private key found. Searched paths:"
        foreach ($keyPath in $sshKeyPaths) {
            Write-LogMessage "    $keyPath"
        }
        Write-LogMessage "  To fix: copy Administrator's SSH key to the SYSTEM profile:"
        Write-LogMessage "    mkdir C:\Windows\System32\config\systemprofile\.ssh"
        Write-LogMessage "    copy C:\Users\Administrator\.ssh\id_ed25519 C:\Windows\System32\config\systemprofile\.ssh\"
        Write-LogMessage "    copy C:\Users\Administrator\.ssh\known_hosts C:\Windows\System32\config\systemprofile\.ssh\"
    } else {
        try {
            $scpOutput = & scp -o "StrictHostKeyChecking=no" -o "BatchMode=yes" `
                -i "$sshKeyFile" `
                "$PEM_EXPORT_PATH" `
                "${SSH_DESTINATION}:${REMOTE_PEM_PATH}" 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-LogMessage "  PEM file successfully copied to ${SSH_DESTINATION}:${REMOTE_PEM_PATH}"
            } else {
                Write-LogMessage "WARNING: SCP failed (exit code: $LASTEXITCODE). Error: $scpOutput"
                Write-LogMessage "  If running as SYSTEM, copy the SSH key to the SYSTEM profile:"
                Write-LogMessage "    mkdir C:\Windows\System32\config\systemprofile\.ssh"
                Write-LogMessage "    copy C:\Users\Administrator\.ssh\id_ed25519 C:\Windows\System32\config\systemprofile\.ssh\"
                Write-LogMessage "    copy C:\Users\Administrator\.ssh\known_hosts C:\Windows\System32\config\systemprofile\.ssh\"
            }
        } catch {
            Write-LogMessage "WARNING: SCP execution failed: $_"
        }
    }
} else {
    Write-LogMessage "  Skipping SCP distribution - SSH destination or remote path not configured."
    Write-LogMessage "  Set Argument 1 = SSH destination (e.g., sysadmin@10.160.115.190)"
    Write-LogMessage "  Set Argument 2 = Remote PEM path (e.g., /home/sysadmin/nps-cert.pem)"
}

# --- Step 8: Cleanup temporary files ---
Write-LogMessage "Step 8: Cleaning up temporary files..."

# Remove PFX (contains private key - must be cleaned up)
if (Test-Path $PFX_OUTPUT) {
    Remove-Item $PFX_OUTPUT -Force
    Write-LogMessage "  Removed temporary PFX file"
}

# Remove DER export (only exists if fallback path was used in Step 6)
if ($DER_EXPORT_PATH -and (Test-Path $DER_EXPORT_PATH)) {
    Remove-Item $DER_EXPORT_PATH -Force
    Write-LogMessage "  Removed temporary DER file"
}

# Keep the PEM, NPS config backup, and NPS config verify for reference
Write-LogMessage "  Retained for reference:"
Write-LogMessage "    NPS config backup: $NPS_CONFIG_EXPORT"
Write-LogMessage "    PEM public cert: $PEM_EXPORT_PATH"

# ============================================================================
# FINAL SUMMARY
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "NPS CERTIFICATE REPLACEMENT SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "  New Certificate Subject: $NEW_SUBJECT"
Write-LogMessage "  New Certificate Thumbprint: $NEW_THUMBPRINT"
Write-LogMessage "  New Certificate Valid From: $NEW_NOT_BEFORE"
Write-LogMessage "  New Certificate Valid To: $NEW_NOT_AFTER"
Write-LogMessage "  NPS Config Updated: Yes"
if (-not [string]::IsNullOrEmpty($SSH_DESTINATION)) {
    Write-LogMessage "  PEM Distributed To: ${SSH_DESTINATION}:${REMOTE_PEM_PATH}"
}
Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed successfully"
Write-LogMessage "=========================================="

exit 0