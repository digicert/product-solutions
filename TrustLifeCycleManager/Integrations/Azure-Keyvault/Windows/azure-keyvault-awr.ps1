<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (PFX Format) - PowerShell Version
.DESCRIPTION
    PowerShell conversion of the original Bash script for processing certificate data from DigiCert TLM Agent
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

# Configuration
$LEGAL_NOTICE_ACCEPT = "false" # Set to "true" to accept the legal notice and proceed with execution
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\keyvault.log"

# ============================================================================
# AZURE KEY VAULT CONFIGURATION
# ============================================================================
$AKV_TENANT_ID     = "Tenant_ID from Azure AD app registration"
$AKV_CLIENT_ID     = "Client_ID from Azure AD app registration"
$AKV_CLIENT_SECRET  = "Client_Secret from Azure AD app registration"
$AKV_VAULT_NAME    = "kv-demo-DLauMZ"
# ============================================================================

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

# Extract arguments from JSON
Write-LogMessage "Extracting arguments from JSON..."

# Initialize argument variables
$ARGUMENT_1 = ""
$ARGUMENT_2 = ""
$ARGUMENT_3 = ""
$ARGUMENT_4 = ""
$ARGUMENT_5 = ""

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
        Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
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
    Write-LogMessage "WARNING: No PFX password found in JSON. Checking if password is in arguments..."
    if (-not [string]::IsNullOrEmpty($ARGUMENT_4)) {
        Write-LogMessage "Checking if Argument 4 could be the password..."
    }
    if (-not [string]::IsNullOrEmpty($ARGUMENT_5)) {
        Write-LogMessage "Checking if Argument 5 could be the password..."
    }
} else {
    Write-LogMessage "PFX password extracted from JSON"
    Write-LogMessage "PFX password length: $($PFX_PASSWORD.Length) characters"
    # Log first 3 chars of password for verification (masked for security)
    if ($PFX_PASSWORD.Length -ge 3) {
        $PFX_PASSWORD_MASKED = $PFX_PASSWORD.Substring(0, 3) + "***"
        Write-LogMessage "PFX password (masked): $PFX_PASSWORD_MASKED"
    } else {
        Write-LogMessage "PFX password (masked): ***"
    }
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
Write-LogMessage "  Argument 1: $ARGUMENT_1"
Write-LogMessage "  Argument 2: $ARGUMENT_2"
Write-LogMessage "  Argument 3: $ARGUMENT_3"
Write-LogMessage "  Argument 4: $ARGUMENT_4"
Write-LogMessage "  Argument 5: $ARGUMENT_5"
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
# AZURE KEY VAULT - CERTIFICATE IMPORT
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting Azure Key Vault certificate import..."
Write-LogMessage "=========================================="

# Validate Azure Key Vault configuration
$akvConfigValid = $true
if ($AKV_TENANT_ID -eq "your-tenant-id" -or [string]::IsNullOrEmpty($AKV_TENANT_ID)) {
    Write-LogMessage "ERROR: AKV_TENANT_ID is not configured"
    $akvConfigValid = $false
}
if ($AKV_CLIENT_ID -eq "your-client-id" -or [string]::IsNullOrEmpty($AKV_CLIENT_ID)) {
    Write-LogMessage "ERROR: AKV_CLIENT_ID is not configured"
    $akvConfigValid = $false
}
if ($AKV_CLIENT_SECRET -eq "your-client-secret" -or [string]::IsNullOrEmpty($AKV_CLIENT_SECRET)) {
    Write-LogMessage "ERROR: AKV_CLIENT_SECRET is not configured"
    $akvConfigValid = $false
}
if ($AKV_VAULT_NAME -eq "your-vault-name" -or [string]::IsNullOrEmpty($AKV_VAULT_NAME)) {
    Write-LogMessage "ERROR: AKV_VAULT_NAME is not configured"
    $akvConfigValid = $false
}

if (-not $akvConfigValid) {
    Write-LogMessage "Azure Key Vault import skipped due to missing configuration"
    exit 1
}

Write-LogMessage "Azure Key Vault configuration validated"
Write-LogMessage "  Tenant ID: $($AKV_TENANT_ID.Substring(0,8))..."
Write-LogMessage "  Client ID: $($AKV_CLIENT_ID.Substring(0,8))..."
Write-LogMessage "  Vault Name: $AKV_VAULT_NAME"

# Find the correct PFX file (exclude _legacy)
$AKV_PFX_FILE = $null
if (Test-Path $CERT_FOLDER) {
    $AKV_PFX_FILE = Get-ChildItem -Path $CERT_FOLDER -Filter "*.pfx" -File |
        Where-Object { $_.Name -notmatch "_legacy" } |
        Select-Object -First 1
}

if ($null -eq $AKV_PFX_FILE) {
    Write-LogMessage "ERROR: No non-legacy PFX file found in $CERT_FOLDER"
    Write-LogMessage "Azure Key Vault import aborted"
    exit 1
}

$AKV_PFX_PATH = $AKV_PFX_FILE.FullName
Write-LogMessage "PFX file selected for import: $AKV_PFX_PATH"

# Derive certificate name for Key Vault from the PFX filename
# e.g. patrick.whatever.pfx -> patrick-whatever
$AKV_CERT_NAME = [System.IO.Path]::GetFileNameWithoutExtension($AKV_PFX_FILE.Name) -replace '[^a-zA-Z0-9-]', '-'
Write-LogMessage "Key Vault certificate name: $AKV_CERT_NAME"

# Base64 encode the PFX file
try {
    $PFX_BYTES = [System.IO.File]::ReadAllBytes($AKV_PFX_PATH)
    $PFX_BASE64 = [System.Convert]::ToBase64String($PFX_BYTES)
    Write-LogMessage "PFX file base64 encoded successfully (length: $($PFX_BASE64.Length) characters)"
} catch {
    Write-LogMessage "ERROR: Failed to base64 encode PFX file: $_"
    Write-LogMessage "Azure Key Vault import aborted"
    exit 1
}

# Get Azure AD access token
Write-LogMessage "Requesting Azure AD access token..."
try {
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $AKV_CLIENT_ID
        client_secret = $AKV_CLIENT_SECRET
        scope         = "https://vault.azure.net/.default"
    }

    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$AKV_TENANT_ID/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $tokenBody

    $ACCESS_TOKEN = $tokenResponse.access_token

    if ([string]::IsNullOrEmpty($ACCESS_TOKEN)) {
        Write-LogMessage "ERROR: Access token is empty in response"
        Write-LogMessage "Azure Key Vault import aborted"
        exit 1
    }

    Write-LogMessage "Azure AD access token obtained successfully"
} catch {
    Write-LogMessage "ERROR: Failed to obtain Azure AD access token: $_"
    Write-LogMessage "Azure Key Vault import aborted"
    exit 1
}

# Import certificate into Azure Key Vault
Write-LogMessage "Importing certificate into Azure Key Vault..."
Write-LogMessage "  Vault: $AKV_VAULT_NAME"
Write-LogMessage "  Certificate name: $AKV_CERT_NAME"

try {
    $importBody = @{
        value  = $PFX_BASE64
        pwd    = $PFX_PASSWORD
        policy = @{
            key_props = @{
                exportable = $true
                key_type   = "RSA"
                reuse_key  = $false
            }
            secret_props = @{
                contentType = "application/x-pkcs12"
            }
        }
    } | ConvertTo-Json -Depth 5

    $importHeaders = @{
        "Authorization" = "Bearer $ACCESS_TOKEN"
        "Content-Type"  = "application/json"
    }

    $importResponse = Invoke-RestMethod -Method Post `
        -Uri "https://$AKV_VAULT_NAME.vault.azure.net/certificates/$AKV_CERT_NAME/import?api-version=7.4" `
        -Headers $importHeaders `
        -Body $importBody

    Write-LogMessage "SUCCESS: Certificate imported into Azure Key Vault"
    Write-LogMessage "  Certificate ID: $($importResponse.id)"
    Write-LogMessage "  Thumbprint: $($importResponse.x509_thumbprint)"

} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody = ""
    if ($_.Exception.Response) {
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd()
            $reader.Close()
            $errorJson = $errorBody | ConvertFrom-Json
            Write-LogMessage "ERROR: Failed to import certificate into Azure Key Vault (HTTP $statusCode)"
            Write-LogMessage "  Error code: $($errorJson.error.code)"
            Write-LogMessage "  Error message: $($errorJson.error.message)"
        } catch {
            Write-LogMessage "ERROR: Failed to import certificate into Azure Key Vault (HTTP $statusCode)"
            Write-LogMessage "  Response: $errorBody"
        }
    } else {
        Write-LogMessage "ERROR: Failed to import certificate into Azure Key Vault: $_"
    }
    exit 1
}

Write-LogMessage "=========================================="
Write-LogMessage "Azure Key Vault import completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF AZURE KEY VAULT SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

exit 0