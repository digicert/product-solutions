<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (PFX Format) - PowerShell Version
.DESCRIPTION
    PowerShell conversion of the original Bash script for processing certificate data from DigiCert TLM Agent
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
$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\Certs\agw-logfile.log"

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format)"
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

# Raw JSON logging disabled — JSON contains PFX password in clear text

# Parse JSON
try {
    $JSON_OBJECT = $JSON_STRING | ConvertFrom-Json
    Write-LogMessage "JSON parsed successfully"
} catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Extract arguments from JSON
Write-LogMessage "Extracting arguments from JSON..."

# Initialize argument variables
$ARGUMENT_1 = ""
$ARGUMENT_2 = ""
$ARGUMENT_3 = ""
$ARGUMENT_4 = ""
$ARGUMENT_5 = ""
$ARGUMENT_6 = ""
$ARGUMENT_7 = ""

# Extract arguments if they exist
if ($JSON_OBJECT.args) {
    $ARGS_ARRAY = $JSON_OBJECT.args
    Write-LogMessage "Raw args array: $($ARGS_ARRAY -join ',')"

    if ($ARGS_ARRAY.Count -ge 1) {
        $ARGUMENT_1 = ($ARGS_ARRAY[0] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) {
        $ARGUMENT_2 = ($ARGS_ARRAY[1] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 3) {
        $ARGUMENT_3 = ($ARGS_ARRAY[2] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_3 extracted: [redacted]"
        Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 4) {
        $ARGUMENT_4 = ($ARGS_ARRAY[3] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
        Write-LogMessage "ARGUMENT_4 length: $($ARGUMENT_4.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 5) {
        $ARGUMENT_5 = ($ARGS_ARRAY[4] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_5 extracted: '$ARGUMENT_5'"
        Write-LogMessage "ARGUMENT_5 length: $($ARGUMENT_5.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 6) {
        $ARGUMENT_6 = ($ARGS_ARRAY[5] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_6 extracted: '$ARGUMENT_6'"
        Write-LogMessage "ARGUMENT_6 length: $($ARGUMENT_6.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 7) {
        $ARGUMENT_7 = ($ARGS_ARRAY[6] -replace '\s', '').Trim()
        Write-LogMessage "ARGUMENT_7 extracted: '$ARGUMENT_7'"
        Write-LogMessage "ARGUMENT_7 length: $($ARGUMENT_7.Length)"
    }
}

# Extract cert folder
$CERT_FOLDER = $JSON_OBJECT.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the .pfx file name
$PFX_FILE = ""
if ($JSON_OBJECT.files) {
    $PFX_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.pfx$|\.p12$' } | Select-Object -First 1
}
Write-LogMessage "Extracted PFX_FILE: $PFX_FILE"

# Extract the PFX password from JSON
# Check common field names for password
$PFX_PASSWORD = ""
if ($JSON_OBJECT.password) { $PFX_PASSWORD = $JSON_OBJECT.password }
elseif ($JSON_OBJECT.pfx_password) { $PFX_PASSWORD = $JSON_OBJECT.pfx_password }
elseif ($JSON_OBJECT.keystore_password) { $PFX_PASSWORD = $JSON_OBJECT.keystore_password }
elseif ($JSON_OBJECT.passphrase) { $PFX_PASSWORD = $JSON_OBJECT.passphrase }

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "WARNING: No PFX password found in JSON"
} else {
    Write-LogMessage "PFX password extracted from JSON"
    Write-LogMessage "PFX password length: $($PFX_PASSWORD.Length) characters"
}

# Construct file path
$PFX_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $PFX_FILE

# Extract all files from the files array
$FILES_ARRAY = $JSON_OBJECT.files -join ','
Write-LogMessage "Files array content: $FILES_ARRAY"

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "Arguments extracted:"
Write-LogMessage "  Argument 1 (Tenant ID)        : $ARGUMENT_1"
Write-LogMessage "  Argument 2 (Client ID)        : $ARGUMENT_2"
Write-LogMessage "  Argument 3 (Client Secret)    : $(if ($ARGUMENT_3) { '***' } else { 'Not set' })"
Write-LogMessage "  Argument 4 (Subscription ID)  : $ARGUMENT_4"
Write-LogMessage "  Argument 5 (Resource Group)   : $ARGUMENT_5"
Write-LogMessage "  Argument 6 (App Gateway Name) : $ARGUMENT_6"
Write-LogMessage "  Argument 7 (Cert Name in AGW) : $ARGUMENT_7"
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
if (Test-Path $PFX_FILE_PATH) {
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
            Write-LogMessage "Certificate valid from: $($pfxCert.NotBefore)"
            Write-LogMessage "Certificate valid to: $($pfxCert.NotAfter)"
            
            # Check key algorithm
            $keyAlgorithm = $pfxCert.SignatureAlgorithm.FriendlyName
            Write-LogMessage "Signature algorithm: $keyAlgorithm"
            
            # Check if it has private key
            if ($pfxCert.HasPrivateKey) {
                Write-LogMessage "Certificate has private key: Yes"
                $keyType = $pfxCert.PrivateKey.GetType().Name
                Write-LogMessage "Private key type: $keyType"
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
if (Test-Path $CERT_FOLDER) {
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
# CUSTOM SCRIPT SECTION
# ============================================================================
#
# Available variables:
#   $CERT_FOLDER      - Folder path where certificates are stored
#   $PFX_FILE         - PFX/P12 filename (filename only)
#   $PFX_FILE_PATH    - Full path to the PFX/P12 file
#   $PFX_PASSWORD     - Password for the PFX/P12 file
#   $ARGUMENT_1..7    - AWR Parameters 1–7 (mapped to Azure connection details below)
#   $JSON_OBJECT      - The full parsed JSON object from DC1_POST_SCRIPT_DATA
#   Write-LogMessage  - Writes a timestamped line to the log file
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section..."
Write-LogMessage "=========================================="

# ============================================================================
# AZURE APPLICATION GATEWAY - CERTIFICATE UPLOAD (No Key Vault)
# ============================================================================
# Map AWR Parameters to descriptive variables.
# Configure these in the TLM AWR Post Script parameter fields:
#
#   Parameter 1 (ARGUMENT_1) : Azure Tenant ID
#   Parameter 2 (ARGUMENT_2) : Service Principal Client ID (App ID)
#   Parameter 3 (ARGUMENT_3) : Service Principal Client Secret
#                              (leave 1-3 empty to use Managed Identity instead)
#   Parameter 4 (ARGUMENT_4) : Azure Subscription ID
#   Parameter 5 (ARGUMENT_5) : Resource Group Name
#   Parameter 6 (ARGUMENT_6) : Application Gateway Name
#   Parameter 7 (ARGUMENT_7) : SSL Certificate Name (label used inside AGW)

Write-LogMessage "Starting Azure Application Gateway certificate upload..."

$AzTenantId       = $ARGUMENT_1
$AzClientId       = $ARGUMENT_2
$AzClientSecret   = $ARGUMENT_3
$AzSubscriptionId = $ARGUMENT_4
$ResourceGroup    = $ARGUMENT_5
$AppGatewayName   = $ARGUMENT_6
$AgwCertName      = $ARGUMENT_7

# --- Validate required parameters ---
$missing = @()
if ([string]::IsNullOrEmpty($AzSubscriptionId)) { $missing += "ARGUMENT_4 (Subscription ID)" }
if ([string]::IsNullOrEmpty($ResourceGroup))    { $missing += "ARGUMENT_5 (Resource Group)" }
if ([string]::IsNullOrEmpty($AppGatewayName))   { $missing += "ARGUMENT_6 (App Gateway Name)" }
if ([string]::IsNullOrEmpty($AgwCertName))      { $missing += "ARGUMENT_7 (Certificate Name)" }

if ($missing.Count -gt 0) {
    Write-LogMessage "ERROR: Missing required AWR parameters: $($missing -join ', ')"
    exit 1
}

if (-not (Test-Path $PFX_FILE_PATH)) {
    Write-LogMessage "ERROR: PFX file not found at: $PFX_FILE_PATH"
    exit 1
}

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "ERROR: PFX password is required for Application Gateway upload"
    exit 1
}

# --- Verify Az modules are available ---
Write-LogMessage "Checking Az PowerShell modules..."
foreach ($mod in @('Az.Accounts', 'Az.Network')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-LogMessage "ERROR: Required module '$mod' not found. Install with: Install-Module $mod -Force"
        exit 1
    }
    Import-Module $mod -ErrorAction Stop
    Write-LogMessage "  Loaded: $mod"
}

# --- Authenticate to Azure ---
try {
    $useServicePrincipal = (-not [string]::IsNullOrEmpty($AzTenantId)) -and
                           (-not [string]::IsNullOrEmpty($AzClientId)) -and
                           (-not [string]::IsNullOrEmpty($AzClientSecret))

    if ($useServicePrincipal) {
        Write-LogMessage "Authenticating with Service Principal (Client ID: $AzClientId)..."
        $secureSecret = ConvertTo-SecureString $AzClientSecret -AsPlainText -Force
        $spCredential = New-Object System.Management.Automation.PSCredential($AzClientId, $secureSecret)
        Connect-AzAccount -ServicePrincipal -Tenant $AzTenantId -Credential $spCredential -ErrorAction Stop | Out-Null
        Write-LogMessage "Service Principal authentication successful"
    } else {
        Write-LogMessage "No Service Principal credentials provided — attempting Managed Identity..."
        Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
        Write-LogMessage "Managed Identity authentication successful"
    }

    Set-AzContext -SubscriptionId $AzSubscriptionId -ErrorAction Stop | Out-Null
    Write-LogMessage "Subscription context set: $AzSubscriptionId"
} catch {
    Write-LogMessage "ERROR: Azure authentication failed: $_"
    exit 1
}

# --- Retrieve the Application Gateway ---
try {
    Write-LogMessage "Retrieving Application Gateway '$AppGatewayName' in resource group '$ResourceGroup'..."
    $appGw = Get-AzApplicationGateway -Name $AppGatewayName -ResourceGroupName $ResourceGroup -ErrorAction Stop
    Write-LogMessage "Application Gateway retrieved — State: $($appGw.OperationalState), Provisioning: $($appGw.ProvisioningState)"
} catch {
    Write-LogMessage "ERROR: Failed to retrieve Application Gateway: $_"
    exit 1
}

# --- Add or update the SSL certificate in the gateway object ---
$securePfxPwd  = ConvertTo-SecureString $PFX_PASSWORD -AsPlainText -Force
$existingCert  = $appGw.SslCertificates | Where-Object { $_.Name -eq $AgwCertName }

try {
    if ($existingCert) {
        Write-LogMessage "Certificate '$AgwCertName' already exists — updating..."
        Set-AzApplicationGatewaySslCertificate `
            -ApplicationGateway $appGw `
            -Name $AgwCertName `
            -CertificateFile $PFX_FILE_PATH `
            -Password $securePfxPwd | Out-Null
        Write-LogMessage "SSL certificate object updated in gateway"
    } else {
        Write-LogMessage "Certificate '$AgwCertName' not found — adding new..."
        Add-AzApplicationGatewaySslCertificate `
            -ApplicationGateway $appGw `
            -Name $AgwCertName `
            -CertificateFile $PFX_FILE_PATH `
            -Password $securePfxPwd | Out-Null
        Write-LogMessage "SSL certificate object added to gateway"
    }
} catch {
    Write-LogMessage "ERROR: Failed to stage SSL certificate on gateway object: $_"
    exit 1
}

# --- Commit changes to Azure (this triggers a gateway update — may take several minutes) ---
try {
    Write-LogMessage "Committing Application Gateway changes to Azure (may take several minutes)..."
    $updatedGw = Set-AzApplicationGateway -ApplicationGateway $appGw -ErrorAction Stop
    Write-LogMessage "Application Gateway update committed successfully"
    Write-LogMessage "  Provisioning state : $($updatedGw.ProvisioningState)"
    Write-LogMessage "  Operational state  : $($updatedGw.OperationalState)"
} catch {
    Write-LogMessage "ERROR: Failed to commit Application Gateway update: $_"
    exit 1
}

Write-LogMessage "=========================================="
Write-LogMessage "Certificate upload to Application Gateway completed successfully"
Write-LogMessage "  AGW Certificate Name : $AgwCertName"
Write-LogMessage "  Application Gateway  : $AppGatewayName"
Write-LogMessage "  Resource Group       : $ResourceGroup"
Write-LogMessage "  Subscription         : $AzSubscriptionId"
Write-LogMessage "=========================================="

Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

exit 0