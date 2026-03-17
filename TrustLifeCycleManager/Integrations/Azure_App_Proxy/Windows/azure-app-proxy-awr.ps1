<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script - Azure App Proxy Upload
.DESCRIPTION
    Processes certificate data from DigiCert TLM Agent and uploads to Azure App Proxy
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

# ============================================================================
# CONFIGURATION
# ============================================================================
$LEGAL_NOTICE_ACCEPT = "false" # Set to "true" to accept the legal notice and proceed with execution
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\azure-app-proxy_data.log"

# Azure App Proxy Configuration
$AZURE_TENANT_ID = "< Azure Tenant ID >"
$AZURE_CLIENT_ID = "< Azure Client ID >"
$AZURE_CERT_THUMBPRINT = "< Azure Certificate Thumbprint >"
$APP_PROXY_OBJECT_ID = "< Azure App Proxy Object ID >"

# ============================================================================
# FUNCTIONS
# ============================================================================
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting DigiCert TLM Agent - Azure App Proxy Upload Script"
Write-LogMessage "=========================================="

# Check legal notice acceptance
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-LogMessage "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT=`"true`" to proceed."
    exit 1
}
Write-LogMessage "Legal notice accepted, proceeding with script execution."

# Get certificate data from TLM Agent
Write-LogMessage "Checking DC1_POST_SCRIPT_DATA environment variable..."
$CERT_INFO = $env:DC1_POST_SCRIPT_DATA

if ([string]::IsNullOrEmpty($CERT_INFO)) {
    Write-LogMessage "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
}
Write-LogMessage "DC1_POST_SCRIPT_DATA is set (length: $($CERT_INFO.Length) characters)"

# Decode JSON from Base64
try {
    $JSON_BYTES = [System.Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString($JSON_BYTES)
    Write-LogMessage "JSON decoded successfully"
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

# Extract certificate folder
$CERT_FOLDER = $JSON_OBJECT.certfolder
Write-LogMessage "Certificate folder: $CERT_FOLDER"

# Extract the .pfx file name
$PFX_FILE = ""
if ($JSON_OBJECT.files) {
    $PFX_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.pfx$|\.p12$' } | Select-Object -First 1
}
Write-LogMessage "PFX file: $PFX_FILE"

# Construct full PFX path
$PFX_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $PFX_FILE
Write-LogMessage "PFX file path: $PFX_FILE_PATH"

# Extract PFX password
$PFX_PASSWORD = ""
if ($JSON_OBJECT.password) { $PFX_PASSWORD = $JSON_OBJECT.password }
elseif ($JSON_OBJECT.pfx_password) { $PFX_PASSWORD = $JSON_OBJECT.pfx_password }
elseif ($JSON_OBJECT.keystore_password) { $PFX_PASSWORD = $JSON_OBJECT.keystore_password }
elseif ($JSON_OBJECT.passphrase) { $PFX_PASSWORD = $JSON_OBJECT.passphrase }

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "ERROR: No PFX password found in JSON"
    exit 1
}
Write-LogMessage "PFX password extracted (length: $($PFX_PASSWORD.Length) characters)"

# Verify PFX file exists
if (-not (Test-Path $PFX_FILE_PATH)) {
    Write-LogMessage "ERROR: PFX file not found: $PFX_FILE_PATH"
    exit 1
}
Write-LogMessage "PFX file verified: $PFX_FILE_PATH"

# Validate the PFX file and extract certificate details
try {
    $securePwd = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
    $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PFX_FILE_PATH, $securePwd)
    
    Write-LogMessage "PFX file validated successfully"
    Write-LogMessage "=========================================="
    Write-LogMessage "Certificate Details:"
    Write-LogMessage "  Subject: $($pfxCert.Subject)"
    Write-LogMessage "  Issuer: $($pfxCert.Issuer)"
    Write-LogMessage "  Serial Number: $($pfxCert.SerialNumber)"
    Write-LogMessage "  Thumbprint: $($pfxCert.Thumbprint)"
    Write-LogMessage "  Valid From: $($pfxCert.NotBefore)"
    Write-LogMessage "  Valid To: $($pfxCert.NotAfter)"
    Write-LogMessage "  Signature Algorithm: $($pfxCert.SignatureAlgorithm.FriendlyName)"
    Write-LogMessage "  Has Private Key: $($pfxCert.HasPrivateKey)"
    Write-LogMessage "=========================================="
    
    # Store values for later verification
    $CERT_SERIAL = $pfxCert.SerialNumber
    $CERT_THUMBPRINT = $pfxCert.Thumbprint
    
    $pfxCert.Dispose()
} catch {
    Write-LogMessage "ERROR: Failed to validate PFX file: $_"
    exit 1
}

# ============================================================================
# AZURE APP PROXY UPLOAD
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting Azure App Proxy certificate upload..."
Write-LogMessage "=========================================="

try {
    # Import AzureAD module
    Write-LogMessage "Importing AzureAD module..."
    Import-Module AzureAD -ErrorAction Stop
    Write-LogMessage "AzureAD module imported successfully"

    # Connect to Azure AD using certificate authentication
    Write-LogMessage "Connecting to Azure AD..."
    Write-LogMessage "  Tenant ID: $AZURE_TENANT_ID"
    Write-LogMessage "  Client ID: $AZURE_CLIENT_ID"
    Write-LogMessage "  Auth Cert Thumbprint: $AZURE_CERT_THUMBPRINT"
    
    $azureConnection = Connect-AzureAD -TenantId $AZURE_TENANT_ID `
                                        -ApplicationId $AZURE_CLIENT_ID `
                                        -CertificateThumbprint $AZURE_CERT_THUMBPRINT `
                                        -ErrorAction Stop
    
    Write-LogMessage "Connected to Azure AD successfully"
    Write-LogMessage "  Account: $($azureConnection.Account)"
    Write-LogMessage "  Environment: $($azureConnection.Environment)"

    # Upload certificate to App Proxy
    Write-LogMessage "Uploading certificate to App Proxy..."
    Write-LogMessage "  App Object ID: $APP_PROXY_OBJECT_ID"
    Write-LogMessage "  PFX Path: $PFX_FILE_PATH"
    
    $pfxSecurePassword = ConvertTo-SecureString -String $PFX_PASSWORD -Force -AsPlainText
    
    Set-AzureADApplicationProxyApplicationCustomDomainCertificate `
        -ObjectId $APP_PROXY_OBJECT_ID `
        -PfxFilePath $PFX_FILE_PATH `
        -Password $pfxSecurePassword `
        -ErrorAction Stop

    Write-LogMessage "Certificate uploaded to Azure App Proxy successfully!"

    # Verify the upload
    Write-LogMessage "=========================================="
    Write-LogMessage "Verifying certificate upload..."
    Write-LogMessage "=========================================="
    
    $appProxy = Get-AzureADApplicationProxyApplication -ObjectId $APP_PROXY_OBJECT_ID -ErrorAction Stop
    $certMetadata = $appProxy.VerifiedCustomDomainCertificatesMetadata
    
    if ($certMetadata) {
        Write-LogMessage "Certificate verified on Azure App Proxy:"
        Write-LogMessage "  External URL: $($appProxy.ExternalUrl)"
        Write-LogMessage "  Subject: $($certMetadata.SubjectName)"
        Write-LogMessage "  Issuer: $($certMetadata.Issuer)"
        Write-LogMessage "  Thumbprint: $($certMetadata.Thumbprint)"
        Write-LogMessage "  Issue Date: $($certMetadata.IssueDate)"
        Write-LogMessage "  Expiry Date: $($certMetadata.ExpiryDate)"
        Write-LogMessage "  Serial Number: $CERT_SERIAL"
        
        # Verify thumbprint matches
        if ($certMetadata.Thumbprint -eq $CERT_THUMBPRINT) {
            Write-LogMessage "SUCCESS: Thumbprint verification passed - certificate matches!"
        } else {
            Write-LogMessage "WARNING: Thumbprint mismatch!"
            Write-LogMessage "  Expected: $CERT_THUMBPRINT"
            Write-LogMessage "  Found: $($certMetadata.Thumbprint)"
        }
        
        # Calculate days until expiry
        $expiryDate = [DateTime]::Parse($certMetadata.ExpiryDate)
        $daysUntilExpiry = ($expiryDate - (Get-Date)).Days
        Write-LogMessage "  Days until expiry: $daysUntilExpiry"
        
    } else {
        Write-LogMessage "WARNING: Could not retrieve certificate metadata for verification"
    }

} catch {
    Write-LogMessage "ERROR: Azure App Proxy upload failed: $_"
    Write-LogMessage "Error details: $($_.Exception.Message)"
    exit 1
}

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed successfully"
Write-LogMessage "=========================================="

exit 0