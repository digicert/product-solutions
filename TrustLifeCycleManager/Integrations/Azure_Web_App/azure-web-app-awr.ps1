<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script with Azure Web App Upload
.DESCRIPTION
    PowerShell script for processing certificate data from DigiCert TLM Agent and automatically uploading to Azure Web Apps
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
$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\azure-webapp_data.log"

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
# CUSTOM SCRIPT SECTION - Azure Web App Certificate Upload
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting Azure Web App certificate upload automation"
Write-LogMessage "=========================================="

# ============================================================================
# Azure CLI Path Configuration
# ============================================================================

Write-LogMessage "Configuring Azure CLI..."

# Define Azure CLI full path - service runs as LocalSystem which may not have PATH configured
$AZ_CLI_PATH = "C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"

# Check 32-bit location first
if (-not (Test-Path $AZ_CLI_PATH)) {
    Write-LogMessage "Azure CLI not found at 32-bit location, checking 64-bit..."
    # Try 64-bit location
    $AZ_CLI_PATH = "C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
}

if (-not (Test-Path $AZ_CLI_PATH)) {
    Write-LogMessage "ERROR: Azure CLI not found at expected locations"
    Write-LogMessage "  Checked: C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
    Write-LogMessage "  Checked: C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
    Write-LogMessage "  Install from: https://aka.ms/installazurecliwindows"
    Write-LogMessage "  Note: Service runs as LocalSystem account"
    exit 1
}

Write-LogMessage "Azure CLI found at: $AZ_CLI_PATH"

# Test Azure CLI
try {
    $azVersion = & $AZ_CLI_PATH --version 2>&1 | Select-Object -First 1
    Write-LogMessage "Azure CLI version: $azVersion"
} catch {
    Write-LogMessage "WARNING: Could not get Azure CLI version: $_"
}

# ============================================================================
# Azure Service Principal Configuration
# ============================================================================

# IMPORTANT: Update these values with your Azure Service Principal details

$AZURE_TENANT_ID = "< TENANT ID HERE >"  # Replace with your actual tenant ID
$AZURE_CLIENT_ID = "< CLIENT ID HERE >"

# Option 1: Hardcode client secret (NOT recommended for production)
$AZURE_CLIENT_SECRET = "<CLIENT SECRET HERE>"  # Replace with your actual secret


# Option 2: Read from encrypted file (RECOMMENDED for production)
# Uncomment the lines below and comment out the hardcoded secret above
# $encryptedSecretPath = "C:\SecureCerts\sp-client-secret.enc"
# if (Test-Path $encryptedSecretPath) {
#     $encryptedSecret = Get-Content $encryptedSecretPath
#     $secureSecret = ConvertTo-SecureString -String $encryptedSecret
#     $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureSecret)
#     $AZURE_CLIENT_SECRET = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
#     [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
#     Write-LogMessage "Client secret loaded from encrypted file"
# } else {
#     Write-LogMessage "ERROR: Encrypted secret file not found: $encryptedSecretPath"
#     exit 1
# }

# ============================================================================
# Azure Web App Configuration from TLM AWR Parameters
# ============================================================================

# Configure these in your TLM Automated Workflow Request (AWR)
# Parameter 1: Azure Resource Group name
# Parameter 2: Azure Web App name
# Parameter 3: Custom domain (optional)

#$AZURE_RESOURCE_GROUP = $ARGUMENT_1  # e.g., "rg-webapp-cert-demo"
#$AZURE_WEBAPP_NAME = $ARGUMENT_2     # e.g., "webapp-cert-demo-1765793155"
#$AZURE_CUSTOM_DOMAIN = $ARGUMENT_3   # e.g., "azure-webapp.tlsguru.io" (optional)

$AZURE_RESOURCE_GROUP = "rg-webapp-cert-demo"  # e.g., "rg-webapp-cert-demo"
$AZURE_WEBAPP_NAME = "webapp-cert-demo-1765793155"     # e.g., "webapp-cert-demo-1765793155"
$AZURE_CUSTOM_DOMAIN = "azure-webapp.tlsguru.io"   # e.g., "azure-webapp.tlsguru.io" (optional)

Write-LogMessage "Azure Configuration:"
Write-LogMessage "  Tenant ID: $AZURE_TENANT_ID"
Write-LogMessage "  Client ID: $AZURE_CLIENT_ID"
Write-LogMessage "  Resource Group: $AZURE_RESOURCE_GROUP"
Write-LogMessage "  Web App Name: $AZURE_WEBAPP_NAME"
Write-LogMessage "  Custom Domain: $AZURE_CUSTOM_DOMAIN"

# ============================================================================
# Validation
# ============================================================================

Write-LogMessage "Validating configuration..."

# Validate Azure configuration
if ([string]::IsNullOrEmpty($AZURE_RESOURCE_GROUP) -or [string]::IsNullOrEmpty($AZURE_WEBAPP_NAME)) {
    Write-LogMessage "ERROR: Azure Resource Group and Web App Name are required"
    Write-LogMessage "  Configure these in your TLM AWR as Parameter 1 and Parameter 2"
    Write-LogMessage "  Example Parameter 1: rg-webapp-cert-demo"
    Write-LogMessage "  Example Parameter 2: webapp-cert-demo-1765793155"
    exit 1
}

if ([string]::IsNullOrEmpty($AZURE_CLIENT_SECRET) -or $AZURE_CLIENT_SECRET -eq "YOUR_CLIENT_SECRET_HERE") {
    Write-LogMessage "ERROR: Azure Client Secret not configured"
    Write-LogMessage "  Update the AZURE_CLIENT_SECRET variable in this script"
    exit 1
}

# Validate certificate file and password
if (-not (Test-Path $PFX_FILE_PATH)) {
    Write-LogMessage "ERROR: PFX file not found: $PFX_FILE_PATH"
    exit 1
}

if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "ERROR: PFX password not available"
    exit 1
}

Write-LogMessage "Certificate validation passed"
Write-LogMessage "  File: $PFX_FILE_PATH"
Write-LogMessage "  Size: $((Get-Item $PFX_FILE_PATH).Length) bytes"

Write-LogMessage "Validation completed successfully"

# ============================================================================
# Azure Authentication
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Authenticating to Azure using Service Principal..."
Write-LogMessage "=========================================="

try {
    # Login using Service Principal with client secret
    & $AZ_CLI_PATH login `
        --service-principal `
        --username $AZURE_CLIENT_ID `
        --password $AZURE_CLIENT_SECRET `
        --tenant $AZURE_TENANT_ID `
        --output none `
        2>$null | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-LogMessage "ERROR: Azure authentication failed"
        Write-LogMessage "  Check your Service Principal credentials"
        Write-LogMessage "  Tenant ID: $AZURE_TENANT_ID"
        Write-LogMessage "  Client ID: $AZURE_CLIENT_ID"
        exit 1
    }
    
    Write-LogMessage "Successfully authenticated to Azure"
    
    # Verify subscription and authentication
    $accountJson = & $AZ_CLI_PATH account show --output json 2>$null
    $accountInfo = $accountJson | ConvertFrom-Json
    
    Write-LogMessage "Azure Account Information:"
    Write-LogMessage "  Subscription Name: $($accountInfo.name)"
    Write-LogMessage "  Subscription ID: $($accountInfo.id)"
    Write-LogMessage "  Tenant ID: $($accountInfo.tenantId)"
    Write-LogMessage "  User Type: $($accountInfo.user.type)"
    Write-LogMessage "  User Name: $($accountInfo.user.name)"
    
    if ($accountInfo.user.type -ne "servicePrincipal") {
        Write-LogMessage "WARNING: Not authenticated as service principal!"
        Write-LogMessage "  Expected type: servicePrincipal, Got: $($accountInfo.user.type)"
    }
    
} catch {
    Write-LogMessage "ERROR: Exception during authentication: $_"
    exit 1
}

Write-LogMessage "Azure authentication completed successfully"

# ============================================================================
# Pre-Upload Verification
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Pre-upload verification..."
Write-LogMessage "=========================================="

# Verify we're still authenticated
Write-LogMessage "Verifying Azure authentication..."
& $AZ_CLI_PATH account show --output none 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-LogMessage "Authentication verified"
} else {
    Write-LogMessage "ERROR: Not authenticated to Azure"
    exit 1
}

# Verify resource group exists
Write-LogMessage "Verifying resource group exists..."
$rgExists = & $AZ_CLI_PATH group exists --name $AZURE_RESOURCE_GROUP 2>$null
if ($rgExists -eq "true") {
    Write-LogMessage "Resource group verified: $AZURE_RESOURCE_GROUP"
} else {
    Write-LogMessage "ERROR: Resource group not found: $AZURE_RESOURCE_GROUP"
    Write-LogMessage "  Available resource groups:"
    & $AZ_CLI_PATH group list --query "[].name" --output tsv 2>$null | ForEach-Object {
        Write-LogMessage "    - $_"
    }
    exit 1
}

# Verify web app exists
Write-LogMessage "Verifying web app exists..."
$webappJson = & $AZ_CLI_PATH webapp show `
    --name $AZURE_WEBAPP_NAME `
    --resource-group $AZURE_RESOURCE_GROUP `
    --query "{name:name,state:state,location:location}" `
    --output json `
    2>$null

if ($LASTEXITCODE -eq 0) {
    $webappInfo = $webappJson | ConvertFrom-Json
    Write-LogMessage "Web app verified: $AZURE_WEBAPP_NAME"
    Write-LogMessage "  Name: $($webappInfo.name)"
    Write-LogMessage "  State: $($webappInfo.state)"
    Write-LogMessage "  Location: $($webappInfo.location)"
} else {
    Write-LogMessage "ERROR: Web app not found: $AZURE_WEBAPP_NAME"
    Write-LogMessage "  Available web apps in resource group:"
    & $AZ_CLI_PATH webapp list --resource-group $AZURE_RESOURCE_GROUP --query "[].name" --output tsv 2>$null | ForEach-Object {
        Write-LogMessage "    - $_"
    }
    exit 1
}

# Verify certificate file
Write-LogMessage "Verifying certificate file..."
if (Test-Path $PFX_FILE_PATH) {
    $fileSize = (Get-Item $PFX_FILE_PATH).Length
    Write-LogMessage "Certificate file verified: $PFX_FILE_PATH ($fileSize bytes)"
} else {
    Write-LogMessage "ERROR: Certificate file not found: $PFX_FILE_PATH"
    exit 1
}

Write-LogMessage "Pre-upload verification completed successfully"

# ============================================================================
# Certificate Upload to Azure Web App
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Uploading certificate to Azure Web App..."
Write-LogMessage "=========================================="

Write-LogMessage "Upload parameters:"
Write-LogMessage "  Web App Name: $AZURE_WEBAPP_NAME"
Write-LogMessage "  Resource Group: $AZURE_RESOURCE_GROUP"
Write-LogMessage "  Certificate File: $PFX_FILE_PATH"
Write-LogMessage "  Certificate File Exists: $(Test-Path $PFX_FILE_PATH)"

try {
    # Execute the upload command and capture output
    Write-LogMessage "Executing certificate upload..."
    
    # Redirect stderr to null to avoid JSON parsing issues
    $uploadJson = & $AZ_CLI_PATH webapp config ssl upload `
        --name $AZURE_WEBAPP_NAME `
        --resource-group $AZURE_RESOURCE_GROUP `
        --certificate-file $PFX_FILE_PATH `
        --certificate-password $PFX_PASSWORD `
        --output json `
        2>$null
    
    $uploadExitCode = $LASTEXITCODE
    Write-LogMessage "Upload command exit code: $uploadExitCode"
    
    if ($uploadExitCode -ne 0) {
        Write-LogMessage "ERROR: Certificate upload failed"
        Write-LogMessage "  Exit Code: $uploadExitCode"
        
        # Try to verify the web app exists
        Write-LogMessage "Attempting to verify Web App exists..."
        & $AZ_CLI_PATH webapp show `
            --name $AZURE_WEBAPP_NAME `
            --resource-group $AZURE_RESOURCE_GROUP `
            --output none `
            2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage "Web App exists and is accessible"
            Write-LogMessage "ERROR: Upload failed despite Web App being accessible"
            Write-LogMessage "  Possible causes:"
            Write-LogMessage "    - Invalid certificate password"
            Write-LogMessage "    - Corrupted PFX file"
            Write-LogMessage "    - Service Principal lacks permission to upload certificates"
        } else {
            Write-LogMessage "ERROR: Cannot access Web App"
            Write-LogMessage "  Check if Web App name is correct: $AZURE_WEBAPP_NAME"
            Write-LogMessage "  Check if Resource Group is correct: $AZURE_RESOURCE_GROUP"
            Write-LogMessage "  Check if Service Principal has permissions"
        }
        
        exit 1
    }
    
    # Parse JSON response
    Write-LogMessage "Upload completed, parsing result..."
    
    try {
        $certInfo = $uploadJson | ConvertFrom-Json
        $thumbprint = $certInfo.thumbprint
        
        Write-LogMessage "Certificate uploaded successfully!"
        Write-LogMessage "  Thumbprint: $thumbprint"
        Write-LogMessage "  Subject Name: $($certInfo.subjectName)"
        Write-LogMessage "  Issuer: $($certInfo.issuer)"
        Write-LogMessage "  Issue Date: $($certInfo.issueDate)"
        Write-LogMessage "  Expiration Date: $($certInfo.expirationDate)"
        Write-LogMessage "  Location: $($certInfo.location)"
        
        if ($certInfo.hostNames) {
            Write-LogMessage "  Host Names: $($certInfo.hostNames -join ', ')"
        }
    } catch {
        Write-LogMessage "WARNING: Could not parse JSON response: $_"
        Write-LogMessage "  Certificate may have uploaded despite parsing error"
        
        # Try to extract thumbprint from raw output if possible
        if ($uploadJson -match '"thumbprint"\s*:\s*"([A-F0-9]{40})"') {
            $thumbprint = $matches[1]
            Write-LogMessage "  Extracted thumbprint from output: $thumbprint"
        } else {
            Write-LogMessage "  Could not extract thumbprint from output"
        }
    }
    
} catch {
    Write-LogMessage "ERROR: Exception during certificate upload: $_"
    Write-LogMessage "  Exception Type: $($_.Exception.GetType().FullName)"
    Write-LogMessage "  Exception Message: $($_.Exception.Message)"
    
    if ($_.Exception.InnerException) {
        Write-LogMessage "  Inner Exception: $($_.Exception.InnerException.Message)"
    }
    
    exit 1
}

# ============================================================================
# Custom Domain Configuration (Optional)
# ============================================================================

if (-not [string]::IsNullOrEmpty($AZURE_CUSTOM_DOMAIN)) {
    Write-LogMessage "=========================================="
    Write-LogMessage "Processing custom domain configuration..."
    Write-LogMessage "=========================================="
    Write-LogMessage "Custom domain: $AZURE_CUSTOM_DOMAIN"
    
    try {
        # Check if domain already exists on the Web App
        Write-LogMessage "Checking existing hostnames on Web App..."
        
        # Redirect stderr to null, only capture stdout
        $hostnameJson = & $AZ_CLI_PATH webapp config hostname list `
            --resource-group $AZURE_RESOURCE_GROUP `
            --webapp-name $AZURE_WEBAPP_NAME `
            --output json `
            2>$null
        
        if ([string]::IsNullOrWhiteSpace($hostnameJson)) {
            Write-LogMessage "WARNING: Could not get hostname list"
        } else {
            $existingDomains = $hostnameJson | ConvertFrom-Json
            $domainExists = $existingDomains | Where-Object { $_.name -eq $AZURE_CUSTOM_DOMAIN }
            
            if (-not $domainExists) {
                Write-LogMessage "Adding custom domain to Web App..."
                Write-LogMessage "  Note: Ensure DNS is configured correctly"
                Write-LogMessage "  Required DNS: CNAME $AZURE_CUSTOM_DOMAIN -> $AZURE_WEBAPP_NAME.azurewebsites.net"
                
                & $AZ_CLI_PATH webapp config hostname add `
                    --webapp-name $AZURE_WEBAPP_NAME `
                    --resource-group $AZURE_RESOURCE_GROUP `
                    --hostname $AZURE_CUSTOM_DOMAIN `
                    --output none `
                    2>$null
                
                $addExitCode = $LASTEXITCODE
                
                if ($addExitCode -eq 0) {
                    Write-LogMessage "Custom domain added successfully"
                } else {
                    Write-LogMessage "WARNING: Failed to add custom domain (exit code: $addExitCode)"
                    Write-LogMessage "  This usually means DNS is not configured correctly"
                    Write-LogMessage "  Continuing with certificate binding anyway..."
                }
            } else {
                Write-LogMessage "Custom domain already exists on Web App"
            }
        }
        
    } catch {
        Write-LogMessage "WARNING: Error processing custom domain: $_"
        Write-LogMessage "  Continuing with certificate binding anyway..."
    }
    
    # Bind certificate to custom domain (always attempt if we have thumbprint)
    if (-not [string]::IsNullOrEmpty($thumbprint)) {
        Write-LogMessage "Binding certificate to custom domain..."
        Write-LogMessage "  Domain: $AZURE_CUSTOM_DOMAIN"
        Write-LogMessage "  Certificate Thumbprint: $thumbprint"
        
        try {
            & $AZ_CLI_PATH webapp config ssl bind `
                --name $AZURE_WEBAPP_NAME `
                --resource-group $AZURE_RESOURCE_GROUP `
                --certificate-thumbprint $thumbprint `
                --ssl-type SNI `
                --output none `
                2>$null
            
            $bindExitCode = $LASTEXITCODE
            
            if ($bindExitCode -eq 0) {
                Write-LogMessage "Certificate bound successfully to custom domain"
                Write-LogMessage "  SSL Type: SNI (Server Name Indication)"
                Write-LogMessage "  Site URL: https://$AZURE_CUSTOM_DOMAIN"
                Write-LogMessage "  Certificate will be used for HTTPS connections"
            } else {
                Write-LogMessage "WARNING: Failed to bind certificate (exit code: $bindExitCode)"
                Write-LogMessage "  The certificate was uploaded but binding failed"
                Write-LogMessage "  You may need to bind it manually via Azure Portal"
            }
            
        } catch {
            Write-LogMessage "WARNING: Exception during certificate binding: $_"
            Write-LogMessage "  You may need to bind the certificate manually"
        }
    } else {
        Write-LogMessage "WARNING: No thumbprint available for binding"
    }
} else {
    Write-LogMessage "No custom domain specified (Parameter 3 is empty)"
    Write-LogMessage "  Certificate uploaded but not bound to any custom domain"
}

# ============================================================================
# Verification and Status Check
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Verifying certificate deployment..."
Write-LogMessage "=========================================="

try {
    # List all certificates in the resource group
    $sslListJson = & $AZ_CLI_PATH webapp config ssl list `
        --resource-group $AZURE_RESOURCE_GROUP `
        --output json `
        2>$null
    
    if ([string]::IsNullOrWhiteSpace($sslListJson)) {
        Write-LogMessage "WARNING: Could not retrieve certificate list"
    } else {
        $sslList = $sslListJson | ConvertFrom-Json
        
        Write-LogMessage "Total certificates in resource group: $($sslList.Count)"
        
        # Find our newly uploaded certificate
        if (-not [string]::IsNullOrEmpty($thumbprint)) {
            $deployedCert = $sslList | Where-Object { $_.thumbprint -eq $thumbprint }
            
            if ($deployedCert) {
                Write-LogMessage "Certificate verification successful"
                Write-LogMessage "  Certificate is active in Azure Web App"
                Write-LogMessage "  Status: Deployed and accessible"
                
                if ($deployedCert.hostNames -and $deployedCert.hostNames.Count -gt 0) {
                    Write-LogMessage "  Bound to hostnames: $($deployedCert.hostNames -join ', ')"
                } else {
                    Write-LogMessage "  Not currently bound to any hostnames"
                }
                
                if ($deployedCert.keyVaultSecretStatus) {
                    Write-LogMessage "  Key Vault Status: $($deployedCert.keyVaultSecretStatus)"
                }
            } else {
                Write-LogMessage "WARNING: Certificate uploaded but not found in SSL list"
                Write-LogMessage "  This may be a timing issue - certificate might still be processing"
            }
        }
        
        # List all certificates for debugging
        Write-LogMessage "All certificates in resource group:"
        foreach ($cert in $sslList) {
            Write-LogMessage "  - Subject: $($cert.subjectName), Thumbprint: $($cert.thumbprint), Expires: $($cert.expirationDate)"
        }
    }
    
} catch {
    Write-LogMessage "WARNING: Could not verify deployment: $_"
}

# ============================================================================
# Cleanup and Logout
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Performing cleanup..."
Write-LogMessage "=========================================="

# Logout from Azure to clear credentials
try {
    & $AZ_CLI_PATH logout 2>$null | Out-Null
    Write-LogMessage "Logged out from Azure successfully"
} catch {
    Write-LogMessage "WARNING: Could not logout from Azure: $_"
}

# Clear sensitive variables
$AZURE_CLIENT_SECRET = $null
$PFX_PASSWORD = $null
Remove-Variable AZURE_CLIENT_SECRET -ErrorAction SilentlyContinue
Remove-Variable PFX_PASSWORD -ErrorAction SilentlyContinue

Write-LogMessage "Cleanup completed"

# ============================================================================
# Final Summary
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "DEPLOYMENT SUMMARY"
Write-LogMessage "=========================================="
Write-LogMessage "Status: SUCCESS"
Write-LogMessage "Certificate File: $PFX_FILE"
Write-LogMessage "Certificate Path: $PFX_FILE_PATH"
Write-LogMessage "Azure Resource Group: $AZURE_RESOURCE_GROUP"
Write-LogMessage "Azure Web App: $AZURE_WEBAPP_NAME"
if (-not [string]::IsNullOrEmpty($thumbprint)) {
    Write-LogMessage "Certificate Thumbprint: $thumbprint"
}
if (-not [string]::IsNullOrEmpty($AZURE_CUSTOM_DOMAIN)) {
    Write-LogMessage "Custom Domain: $AZURE_CUSTOM_DOMAIN"
    Write-LogMessage "Access URL: https://$AZURE_CUSTOM_DOMAIN"
} else {
    Write-LogMessage "Default URL: https://$AZURE_WEBAPP_NAME.azurewebsites.net"
}
Write-LogMessage "Deployment completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-LogMessage "=========================================="

Write-LogMessage "Azure Web App certificate upload automation completed successfully"
Write-LogMessage "=========================================="

exit 0