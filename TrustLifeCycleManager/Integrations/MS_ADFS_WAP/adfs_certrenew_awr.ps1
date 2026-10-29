<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (PFX Format) - Microsoft AD FS / Web Application Proxy
.DESCRIPTION
    Admin Web Request (AWR) post-enrollment script for the DigiCert Trust Lifecycle Manager Agent.
    It decodes the DC1_POST_SCRIPT_DATA payload, locates the issued PFX/P12 certificate file,
    imports it into Cert:\LocalMachine\My, grants the AD FS service read access to the private key,
    and then configures AD FS (primary or secondary) or Web Application Proxy (WAP) to use it.

    AWR arguments (args array):
      ARGUMENT_1 = Role                  ADFS_PRIMARY / ADFS_SECONDARY / WAP
      ARGUMENT_2 = FederationServiceName Example: wap.aiauat.com
      ARGUMENT_3 = RestartServices       true / false
      ARGUMENT_4 = ReEstablishWapTrust   true / false (only used for the WAP role)

    Expected AWR payload example:
      {
        "args":["ADFS_PRIMARY","wap.aiauat.com","true","false"],
        "certfolder":"D:\\2026Renew\\20260604\\wap.aiauat.com_pfx_2026_06_04_14_44_10",
        "files":["wap.aiauat.com.pfx","wap.aiauat.com_legacy.pfx"],
        "password":"12345678"
      }

    Run context must have local administrator rights.
    For ADFS_PRIMARY, the account must have permission to update the AD FS configuration.
    For WAP trust re-establishment, domain admin / delegated credentials may be required.
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
$LEGAL_NOTICE_ACCEPT = "false"   # Set to "true" to accept the legal notice and allow execution.
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\adfs-wap-awr.log"

$ErrorActionPreference = "Stop"

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logDir = Split-Path -Parent $LOGFILE
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# Log an error and abort the current step (caught by the main try/catch in the custom section)
function Fail {
    param([string]$Message)
    Write-LogMessage "ERROR: $Message"
    throw $Message
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format) - AD FS / WAP"
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

# Parse JSON
try {
    $JSON_OBJECT = $JSON_STRING | ConvertFrom-Json
    Write-LogMessage "JSON parsed successfully"
} catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Log the JSON for debugging (PFX password masked)
$JSON_FOR_LOG = $JSON_STRING | ConvertFrom-Json
foreach ($pwdField in @("password", "pfx_password", "keystore_password", "passphrase")) {
    if ($null -ne $JSON_FOR_LOG.$pwdField) { $JSON_FOR_LOG.$pwdField = "********" }
}
Write-LogMessage "=========================================="
Write-LogMessage "Raw JSON content (password masked):"
Write-LogMessage ($JSON_FOR_LOG | ConvertTo-Json -Compress)
Write-LogMessage "=========================================="

# Extract arguments from JSON
Write-LogMessage "Extracting arguments from JSON..."

# Initialize argument variables (this script uses 4)
$ARGUMENT_1 = ""
$ARGUMENT_2 = ""
$ARGUMENT_3 = ""
$ARGUMENT_4 = ""

# Extract arguments if they exist
if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = @($JSON_OBJECT.args)
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"

    if ($ARGS_ARRAY.Count -ge 1) {
        $ARGUMENT_1 = ([string]$ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) {
        $ARGUMENT_2 = ([string]$ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 3) {
        $ARGUMENT_3 = ([string]$ARGS_ARRAY[2] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
        Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 4) {
        $ARGUMENT_4 = ([string]$ARGS_ARRAY[3] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
        Write-LogMessage "ARGUMENT_4 length: $($ARGUMENT_4.Length)"
    }
}

# Extract cert folder
$CERT_FOLDER = [string]$JSON_OBJECT.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .pfx file name (prefer the non-legacy PFX/P12 when more than one is delivered)
$PFX_FILE = ""
if ($JSON_OBJECT.files) {
    $pfxCandidates = @($JSON_OBJECT.files | Where-Object { $_ -match '\.pfx$|\.p12$' })
    $PFX_FILE = $pfxCandidates | Where-Object { $_ -notmatch '_legacy\.(pfx|p12)$' } | Select-Object -First 1
    if ([string]::IsNullOrEmpty($PFX_FILE)) {
        $PFX_FILE = $pfxCandidates | Select-Object -First 1
    }
    if ($pfxCandidates.Count -gt 1) {
        Write-LogMessage "Multiple PFX/P12 files listed in payload: $($pfxCandidates -join ',')"
    }
}
Write-LogMessage "Extracted PFX_FILE: $PFX_FILE"

# Extract the PFX password from JSON
# Check common field names for password, then fall back to the DC1_PFX_PASSWORD environment variable
$PFX_PASSWORD = ""
if ($JSON_OBJECT.password) { $PFX_PASSWORD = $JSON_OBJECT.password }
elseif ($JSON_OBJECT.pfx_password) { $PFX_PASSWORD = $JSON_OBJECT.pfx_password }
elseif ($JSON_OBJECT.keystore_password) { $PFX_PASSWORD = $JSON_OBJECT.keystore_password }
elseif ($JSON_OBJECT.passphrase) { $PFX_PASSWORD = $JSON_OBJECT.passphrase }

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "WARNING: No PFX password found in JSON. Checking DC1_PFX_PASSWORD environment variable..."
    if (-not [string]::IsNullOrEmpty($env:DC1_PFX_PASSWORD)) {
        $PFX_PASSWORD = $env:DC1_PFX_PASSWORD
        Write-LogMessage "PFX password taken from DC1_PFX_PASSWORD environment variable"
    }
} else {
    Write-LogMessage "PFX password extracted from JSON"
}
if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "PFX password length: $($PFX_PASSWORD.Length) characters"
    Write-LogMessage "PFX password (masked): ********"
}

# Construct file path
$PFX_FILE_PATH = ""
if (-not [string]::IsNullOrEmpty($CERT_FOLDER) -and -not [string]::IsNullOrEmpty($PFX_FILE)) {
    $PFX_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $PFX_FILE
}

# Extract all files from the files array
$FILES_ARRAY = $JSON_OBJECT.files -join ','
Write-LogMessage "Files array content: $FILES_ARRAY"

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "Arguments extracted:"
Write-LogMessage "  Argument 1 (Role): $ARGUMENT_1"
Write-LogMessage "  Argument 2 (FederationServiceName): $ARGUMENT_2"
Write-LogMessage "  Argument 3 (RestartServices): $ARGUMENT_3"
Write-LogMessage "  Argument 4 (ReEstablishWapTrust): $ARGUMENT_4"
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
if (-not [string]::IsNullOrEmpty($PFX_FILE_PATH) -and (Test-Path $PFX_FILE_PATH)) {
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
            Write-LogMessage "Certificate serial number: $($pfxCert.SerialNumber)"
            Write-LogMessage "Certificate valid from: $($pfxCert.NotBefore)"
            Write-LogMessage "Certificate valid to: $($pfxCert.NotAfter)"

            # Check key algorithm
            $keyAlgorithm = $pfxCert.SignatureAlgorithm.FriendlyName
            Write-LogMessage "Signature algorithm: $keyAlgorithm"

            # Check if it has private key
            if ($pfxCert.HasPrivateKey) {
                Write-LogMessage "Certificate has private key: Yes"
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
if (-not [string]::IsNullOrEmpty($CERT_FOLDER) -and (Test-Path $CERT_FOLDER)) {
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
# CUSTOM SCRIPT SECTION - AD FS / WAP CERTIFICATE DEPLOYMENT
# ============================================================================
#
# Variables available from the extraction section above:
#
# Certificate-related variables:
#   $CERT_FOLDER      - The folder path where certificates are stored
#   $PFX_FILE         - The filename of the PFX/P12 certificate (filename only)
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file (folder + filename)
#   $PFX_PASSWORD     - Password for the PFX/P12 file (if available)
#   $FILES_ARRAY      - All files listed in the JSON files array
#
# Argument variables (from JSON args array):
#   $ARGUMENT_1       - Role: ADFS_PRIMARY / ADFS_SECONDARY / WAP (AWR Parameter 1)
#   $ARGUMENT_2       - FederationServiceName (AWR Parameter 2)
#   $ARGUMENT_3       - RestartServices: true / false (AWR Parameter 3)
#   $ARGUMENT_4       - ReEstablishWapTrust: true / false (AWR Parameter 4)
#
# Utility functions:
#   Write-LogMessage "text" - Function to write timestamped messages to log file
#   Fail "text"             - Logs an ERROR line and throws (handled by the main try/catch)
#
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section..."
Write-LogMessage "=========================================="

# -----------------------------
# Locate PFX/P12 file
# -----------------------------
function Find-PfxFile {
    if ([string]::IsNullOrWhiteSpace($CERT_FOLDER)) {
        Fail "Payload does not contain certfolder."
    }
    if (-not (Test-Path $CERT_FOLDER)) {
        Fail "Certificate folder does not exist: $CERT_FOLDER"
    }

    # Preferred: the file selected from the payload files array above.
    if (-not [string]::IsNullOrWhiteSpace($PFX_FILE_PATH) -and (Test-Path $PFX_FILE_PATH)) {
        Write-LogMessage "Selected PFX/P12 file: $PFX_FILE_PATH"
        return [string]$PFX_FILE_PATH
    }

    # Fallback: scan the certificate folder for any PFX/P12 file.
    Write-LogMessage "WARNING: PFX/P12 from payload files array not usable. Scanning certificate folder..."
    $candidateFiles = @(
        Get-ChildItem -Path $CERT_FOLDER -Recurse -File |
        Where-Object { $_.Extension -match "^\.(pfx|p12)$" } |
        ForEach-Object { [string]$_.FullName }
    )
    if ($candidateFiles.Count -eq 0) {
        Fail "No PFX/P12 file found in certificate folder: $CERT_FOLDER. ADFS/WAP requires a certificate with private key."
    }

    # Prefer non-legacy PFX/P12 file.
    $preferredFiles = @($candidateFiles | Where-Object { $_ -notmatch "_legacy\.(pfx|p12)$" })
    if ($preferredFiles.Count -gt 0) {
        $selectedFile = [string]$preferredFiles[0]
    } else {
        $selectedFile = [string]$candidateFiles[0]
    }
    if ($candidateFiles.Count -gt 1) {
        Write-LogMessage "Multiple PFX/P12 files found. Selected: $selectedFile"
    } else {
        Write-LogMessage "Selected PFX/P12 file: $selectedFile"
    }
    return $selectedFile
}

# -----------------------------
# PFX password handling
# -----------------------------
function Get-PfxPassword {
    if ([string]::IsNullOrWhiteSpace($PFX_PASSWORD)) {
        Fail "No PFX password found. AWR payload does not contain a password and DC1_PFX_PASSWORD is not set."
    }
    return ConvertTo-SecureString -String $PFX_PASSWORD -AsPlainText -Force
}

# -----------------------------
# Import PFX
# -----------------------------
function Import-CertificatePfx {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PfxPath,
        [Parameter(Mandatory = $true)]
        [securestring]$Password
    )
    if (-not (Test-Path $PfxPath)) {
        Fail "PFX file does not exist before import: $PfxPath"
    }
    Write-LogMessage "Importing PFX into Cert:\LocalMachine\My: $PfxPath"
    $importParams = @{
        FilePath          = $PfxPath
        CertStoreLocation = "Cert:\LocalMachine\My"
        Password          = $Password
        Exportable        = $true
    }
    $importedCerts = Import-PfxCertificate @importParams
    if ($null -eq $importedCerts) {
        Fail "Import-PfxCertificate returned null."
    }

    # Import-PfxCertificate may return chain certificates as well.
    # Select the leaf certificate that has a private key.
    $leafCert = @($importedCerts) |
        Where-Object { $_.HasPrivateKey } |
        Select-Object -First 1
    if ($null -eq $leafCert) {
        Fail "No certificate with private key was returned after PFX import. ADFS/WAP requires a private key."
    }

    $thumbprint = ($leafCert.Thumbprint -replace "\s", "").ToUpperInvariant()
    Write-LogMessage "Imported certificate subject: $($leafCert.Subject)"
    Write-LogMessage "Imported certificate thumbprint: $thumbprint"
    Write-LogMessage "Imported certificate serial number: $($leafCert.SerialNumber)"
    Write-LogMessage "Imported certificate expires: $($leafCert.NotAfter)"
    return $thumbprint
}

# -----------------------------
# Grant private key read access
# -----------------------------
function Grant-PrivateKeyReadAccess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint,
        [string[]]$Accounts
    )
    $cert = Get-ChildItem -Path "Cert:\LocalMachine\My" |
        Where-Object { ($_.Thumbprint -replace "\s", "").ToUpperInvariant() -eq $Thumbprint } |
        Select-Object -First 1
    if ($null -eq $cert) {
        Fail "Cannot find certificate in LocalMachine\My for thumbprint $Thumbprint"
    }
    if (-not $cert.HasPrivateKey) {
        Fail "Certificate $Thumbprint does not have a private key."
    }
    try {
        $rsaKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        if ($null -eq $rsaKey) {
            Write-LogMessage "WARNING: Could not resolve RSA private key object. Skipping ACL update."
            return
        }
        $keyName = $rsaKey.Key.UniqueName
        $keyPath = Join-Path $env:ProgramData "Microsoft\Crypto\RSA\MachineKeys\$keyName"
        if (-not (Test-Path $keyPath)) {
            Write-LogMessage "WARNING: Private key file not found at expected path: $keyPath. Skipping ACL update."
            return
        }
        foreach ($account in $Accounts) {
            try {
                Write-LogMessage "Granting read permission on private key to $account"
                $acl = Get-Acl $keyPath
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($account, "Read", "Allow")
                $acl.AddAccessRule($rule)
                Set-Acl -Path $keyPath -AclObject $acl
            } catch {
                Write-LogMessage "WARNING: Failed to grant private key access to $account. Error: $($_.Exception.Message)"
            }
        }
    } catch {
        Write-LogMessage "WARNING: Private key ACL update failed. Error: $($_.Exception.Message)"
    }
}

# -----------------------------
# Configure AD FS Primary
# -----------------------------
function Configure-AdfsPrimary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )
    Import-Module ADFS -ErrorAction Stop
    Write-LogMessage "Setting AD FS Service Communications certificate."
    Set-AdfsCertificate -CertificateType Service-Communications -Thumbprint $Thumbprint
    Write-LogMessage "Setting AD FS SSL certificate."
    Set-AdfsSslCertificate -Thumbprint $Thumbprint
    Write-LogMessage "AD FS certificate list after update:"
    Get-AdfsCertificate |
        Format-Table CertificateType, Thumbprint, IsPrimary, NotAfter -AutoSize |
        Out-String |
        ForEach-Object { Write-LogMessage $_ }
    Write-LogMessage "AD FS SSL certificate after update:"
    Get-AdfsSslCertificate |
        Format-List |
        Out-String |
        ForEach-Object { Write-LogMessage $_ }
}

# -----------------------------
# Configure AD FS Secondary
# -----------------------------
function Configure-AdfsSecondary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )
    Import-Module ADFS -ErrorAction Stop
    Write-LogMessage "Setting AD FS SSL certificate on secondary AD FS server."
    Set-AdfsSslCertificate -Thumbprint $Thumbprint
    Write-LogMessage "AD FS SSL certificate after update:"
    Get-AdfsSslCertificate |
        Format-List |
        Out-String |
        ForEach-Object { Write-LogMessage $_ }
}

# -----------------------------
# Configure WAP
# -----------------------------
function Configure-Wap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint,
        [string]$FederationServiceName,
        [bool]$ReEstablishTrust
    )
    Import-Module WebApplicationProxy -ErrorAction Stop
    Write-LogMessage "Setting Web Application Proxy SSL certificate."
    Set-WebApplicationProxySslCertificate -Thumbprint $Thumbprint
    if ($ReEstablishTrust) {
        if ([string]::IsNullOrWhiteSpace($FederationServiceName)) {
            Fail "FederationServiceName is required when ReEstablishWapTrust is true."
        }
        Write-LogMessage "Re-establishing WAP trust for federation service: $FederationServiceName"
        Write-LogMessage "Install-WebApplicationProxy may prompt for credentials if not running in a suitable context."
        $installWapParams = @{
            CertificateThumbprint = $Thumbprint
            FederationServiceName = $FederationServiceName
        }
        Install-WebApplicationProxy @installWapParams
    } else {
        Write-LogMessage "Skipping Install-WebApplicationProxy because ReEstablishWapTrust is false."
    }
}

# -----------------------------
# Restart services
# -----------------------------
function Restart-AdfsRelatedServices {
    param([string]$Role)
    if ($Role -like "ADFS*") {
        $svc = Get-Service -Name adfssrv -ErrorAction SilentlyContinue
        if ($null -ne $svc) {
            Write-LogMessage "Restarting adfssrv service."
            Restart-Service -Name adfssrv -Force
        } else {
            Write-LogMessage "WARNING: adfssrv service not found."
        }
    }
    if ($Role -eq "WAP") {
        $apphost = Get-Service -Name apphostsvc -ErrorAction SilentlyContinue
        if ($null -ne $apphost) {
            Write-LogMessage "Restarting apphostsvc service."
            Restart-Service -Name apphostsvc -Force
        } else {
            Write-LogMessage "WARNING: apphostsvc service not found."
        }
        $adfsSvc = Get-Service -Name adfssrv -ErrorAction SilentlyContinue
        if ($null -ne $adfsSvc) {
            Write-LogMessage "Restarting adfssrv service."
            Restart-Service -Name adfssrv -Force
        }
    }
}

# -----------------------------
# Final validation
# -----------------------------
function Validate-LocalCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )
    Write-LogMessage "Final local certificate check:"
    $cert = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { ($_.Thumbprint -replace "\s", "").ToUpperInvariant() -eq $Thumbprint } |
        Select-Object -First 1
    if ($null -eq $cert) {
        Fail "Final validation failed. Certificate $Thumbprint not found in LocalMachine\My."
    }
    $cert |
        Format-List Subject, Thumbprint, SerialNumber, NotAfter, HasPrivateKey |
        Out-String |
        ForEach-Object { Write-LogMessage $_ }
    if (-not $cert.HasPrivateKey) {
        Fail "Final validation failed. Certificate $Thumbprint does not have private key."
    }
}

# -----------------------------
# Main
# -----------------------------
$EXIT_CODE = 0
try {
    Write-LogMessage "========== ADFS/WAP AWR deployment started =========="

    $role = $ARGUMENT_1
    if ([string]::IsNullOrWhiteSpace($role)) { $role = "ADFS_PRIMARY" }
    $role = $role.ToUpperInvariant()

    $federationServiceName = $ARGUMENT_2

    $restartServicesText = $ARGUMENT_3
    if ([string]::IsNullOrWhiteSpace($restartServicesText)) { $restartServicesText = "true" }

    $reEstablishTrustText = $ARGUMENT_4
    if ([string]::IsNullOrWhiteSpace($reEstablishTrustText)) { $reEstablishTrustText = "false" }

    try {
        $restartServices = [System.Convert]::ToBoolean($restartServicesText)
        $reEstablishTrust = [System.Convert]::ToBoolean($reEstablishTrustText)
    } catch {
        Fail "RestartServices / ReEstablishWapTrust must be 'true' or 'false'. Got: '$restartServicesText' / '$reEstablishTrustText'."
    }

    Write-LogMessage "Role: $role"
    Write-LogMessage "FederationServiceName: $federationServiceName"
    Write-LogMessage "RestartServices: $restartServices"
    Write-LogMessage "ReEstablishWapTrust: $reEstablishTrust"

    if ($role -notin @("ADFS_PRIMARY", "ADFS_SECONDARY", "WAP")) {
        Fail "Invalid role: $role. Valid values: ADFS_PRIMARY, ADFS_SECONDARY, WAP."
    }

    $pfxPath = Find-PfxFile
    Write-LogMessage "PFX path returned by Find-PfxFile: $pfxPath"

    $pfxPassword = Get-PfxPassword
    $thumbprint = Import-CertificatePfx -PfxPath $pfxPath -Password $pfxPassword

    # Common accounts. Adjust if your AD FS service runs under a gMSA or custom service account.
    Grant-PrivateKeyReadAccess -Thumbprint $thumbprint -Accounts @(
        "NT SERVICE\adfssrv",
        "NT AUTHORITY\NETWORK SERVICE"
    )

    switch ($role) {
        "ADFS_PRIMARY" {
            Configure-AdfsPrimary -Thumbprint $thumbprint
        }
        "ADFS_SECONDARY" {
            Configure-AdfsSecondary -Thumbprint $thumbprint
        }
        "WAP" {
            $wapParams = @{
                Thumbprint            = $thumbprint
                FederationServiceName = $federationServiceName
                ReEstablishTrust      = $reEstablishTrust
            }
            Configure-Wap @wapParams
        }
    }

    if ($restartServices) {
        Restart-AdfsRelatedServices -Role $role
    } else {
        Write-LogMessage "Service restart skipped by argument."
    }

    Validate-LocalCertificate -Thumbprint $thumbprint
    Write-LogMessage "========== ADFS/WAP AWR deployment completed successfully =========="
} catch {
    Write-LogMessage "ERROR: Deployment failed: $($_.Exception.Message)"
    Write-LogMessage "========== ADFS/WAP AWR deployment failed =========="
    $EXIT_CODE = 1
}

# ----------------------------------------
# END OF CUSTOM LOGIC

Write-LogMessage "Custom script section completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
if ($EXIT_CODE -eq 0) {
    Write-LogMessage "Script execution completed"
} else {
    Write-LogMessage "Script execution completed with errors (exit code $EXIT_CODE)"
}
Write-LogMessage "=========================================="

exit $EXIT_CODE
