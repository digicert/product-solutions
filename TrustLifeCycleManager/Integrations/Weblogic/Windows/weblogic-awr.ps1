# DC1 Post Script Data Extraction Script - PowerShell Version
# Converts PFX certificate to Java Keystore format
# Copyright (c) 2024 DigiCert. All rights reserved.

# Configuration
$LEGAL_NOTICE_ACCEPT = "true"
$LOGFILE = "C:\tlm_agent_3.0.15_win64\log\dc1_data.log"

# Java Keystore Configuration
$JKS_PATH = "C:\weblogic.jks"
$JKS_PASSWORD = "changeit"
$JKS_BACKUP_DIR = "C:\backups"
$JKS_ALIAS = "server_cert"  # Fixed alias to use in keystore
$USE_CN_AS_ALIAS = $false  # Set to $true to use certificate CN as alias

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE
}

# Function to test if running as administrator
function Test-Administrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script (PFX format with JKS update)"
Write-LogMessage "=========================================="

# Check if running as administrator
if (-not (Test-Administrator)) {
    Write-LogMessage "WARNING: Not running as Administrator. Some operations may fail."
}

# Check legal notice acceptance
Write-LogMessage "Checking legal notice acceptance..."
if ($LEGAL_NOTICE_ACCEPT -ne "true") {
    Write-LogMessage "ERROR: Legal notice not accepted. Set LEGAL_NOTICE_ACCEPT='true' to proceed."
    Write-LogMessage "Script execution terminated due to legal notice non-acceptance."
    Write-LogMessage "=========================================="
    exit 1
}
else {
    Write-LogMessage "Legal notice accepted, proceeding with script execution."
}

# Log initial configuration
Write-LogMessage "Configuration:"
Write-LogMessage "  LEGAL_NOTICE_ACCEPT: $LEGAL_NOTICE_ACCEPT"
Write-LogMessage "  LOGFILE: $LOGFILE"
Write-LogMessage "  JKS_PATH: $JKS_PATH"
Write-LogMessage "  JKS_ALIAS: $JKS_ALIAS"
Write-LogMessage "  JKS_BACKUP_DIR: $JKS_BACKUP_DIR"

# Log environment variable check
Write-LogMessage "Checking DC1_POST_SCRIPT_DATA environment variable..."
$CERT_INFO = $env:DC1_POST_SCRIPT_DATA

if ([string]::IsNullOrEmpty($CERT_INFO)) {
    Write-LogMessage "ERROR: DC1_POST_SCRIPT_DATA environment variable is not set"
    exit 1
}
else {
    Write-LogMessage "DC1_POST_SCRIPT_DATA is set (length: $($CERT_INFO.Length) characters)"
}

# Decode Base64-encoded JSON string
try {
    $jsonBytes = [System.Convert]::FromBase64String($CERT_INFO)
    $JSON_STRING = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
    Write-LogMessage "JSON_STRING decoded successfully"
}
catch {
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
    $jsonObject = $JSON_STRING | ConvertFrom-Json
    Write-LogMessage "JSON parsed successfully"
}
catch {
    Write-LogMessage "ERROR: Failed to parse JSON: $_"
    exit 1
}

# Extract arguments
Write-LogMessage "Extracting arguments from JSON..."
$args_array = $jsonObject.args
if ($args_array) {
    $ARGUMENT_1 = if ($args_array.Count -ge 1) { $args_array[0].Trim() } else { "" }
    $ARGUMENT_2 = if ($args_array.Count -ge 2) { $args_array[1].Trim() } else { "" }
    $ARGUMENT_3 = if ($args_array.Count -ge 3) { $args_array[2].Trim() } else { "" }
    $ARGUMENT_4 = if ($args_array.Count -ge 4) { $args_array[3].Trim() } else { "" }
    $ARGUMENT_5 = if ($args_array.Count -ge 5) { $args_array[4].Trim() } else { "" }
    
    Write-LogMessage "Arguments extracted:"
    Write-LogMessage "  ARGUMENT_1: '$ARGUMENT_1'"
    Write-LogMessage "  ARGUMENT_2: '$ARGUMENT_2'"
    Write-LogMessage "  ARGUMENT_3: '$ARGUMENT_3'"
    Write-LogMessage "  ARGUMENT_4: '$ARGUMENT_4'"
    Write-LogMessage "  ARGUMENT_5: '$ARGUMENT_5'"
}

# Extract cert folder
$CERT_FOLDER = $jsonObject.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract files
$FILES_ARRAY = $jsonObject.files
Write-LogMessage "Files array contains $($FILES_ARRAY.Count) files"

# Find PFX files
$PFX_FILES = @()
$NON_LEGACY_PFX = ""
$LEGACY_PFX = ""

foreach ($file in $FILES_ARRAY) {
    if ($file -match '\.pfx$' -or $file -match '\.p12$') {
        $PFX_FILES += $file
        if ($file -match '_legacy') {
            $LEGACY_PFX = $file
            Write-LogMessage "Identified legacy PFX file: $LEGACY_PFX"
        }
        else {
            $NON_LEGACY_PFX = $file
            Write-LogMessage "Identified non-legacy PFX file: $NON_LEGACY_PFX"
        }
    }
}

Write-LogMessage "Found $($PFX_FILES.Count) PFX file(s): $($PFX_FILES -join ', ')"

# If no non-legacy file found, use the first available PFX
if ([string]::IsNullOrEmpty($NON_LEGACY_PFX) -and $PFX_FILES.Count -gt 0) {
    $NON_LEGACY_PFX = $PFX_FILES[0]
    Write-LogMessage "No explicit non-legacy file found, using: $NON_LEGACY_PFX"
}

# Extract PFX password
$PFX_PASSWORD = $jsonObject.password
if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
    # Try alternative field names
    if ($jsonObject.pfx_password) { $PFX_PASSWORD = $jsonObject.pfx_password }
    elseif ($jsonObject.keystore_password) { $PFX_PASSWORD = $jsonObject.keystore_password }
    elseif ($jsonObject.passphrase) { $PFX_PASSWORD = $jsonObject.passphrase }
    
    if ([string]::IsNullOrEmpty($PFX_PASSWORD)) {
        Write-LogMessage "WARNING: No PFX password found in any expected fields"
    }
}
else {
    Write-LogMessage "PFX password extracted from JSON"
    Write-LogMessage "PFX password length: $($PFX_PASSWORD.Length) characters"
    if ($PFX_PASSWORD.Length -ge 3) {
        $masked = $PFX_PASSWORD.Substring(0, 3) + "***"
        Write-LogMessage "PFX password (masked): $masked"
    }
    else {
        Write-LogMessage "PFX password (masked): ***"
    }
}

# Construct file path for non-legacy PFX
$PFX_FILE_PATH = Join-Path $CERT_FOLDER $NON_LEGACY_PFX

# Log summary
Write-LogMessage "=========================================="
Write-LogMessage "EXTRACTION SUMMARY:"
Write-LogMessage "=========================================="
Write-LogMessage "Certificate information:"
Write-LogMessage "  Certificate folder: $CERT_FOLDER"
Write-LogMessage "  Non-legacy PFX file: $NON_LEGACY_PFX"
Write-LogMessage "  Legacy PFX file: $LEGACY_PFX"
Write-LogMessage "  PFX file path: $PFX_FILE_PATH"
if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) {
    Write-LogMessage "  PFX password: Found ($($PFX_PASSWORD.Length) characters)"
}
else {
    Write-LogMessage "  PFX password: Not found"
}
Write-LogMessage "=========================================="

# Check if PFX file exists
if (Test-Path $PFX_FILE_PATH) {
    $fileInfo = Get-Item $PFX_FILE_PATH
    Write-LogMessage "PFX file exists: $PFX_FILE_PATH"
    Write-LogMessage "PFX file size: $($fileInfo.Length) bytes"
    
    # Try to inspect certificate using .NET
    if (-not [string]::IsNullOrEmpty($PFX_PASSWORD)) {
        try {
            $pfxCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PFX_FILE_PATH, $PFX_PASSWORD)
            Write-LogMessage "Successfully accessed PFX file with provided password"
            Write-LogMessage "Certificate Subject: $($pfxCert.Subject)"
            Write-LogMessage "Certificate Issuer: $($pfxCert.Issuer)"
            Write-LogMessage "Certificate Valid From: $($pfxCert.NotBefore)"
            Write-LogMessage "Certificate Valid To: $($pfxCert.NotAfter)"
            
            # Extract CN from subject
            if ($pfxCert.Subject -match 'CN=([^,]+)') {
                $CN = $Matches[1].Trim()
                Write-LogMessage "Certificate CN: $CN"
                if ($USE_CN_AS_ALIAS) {
                    $JKS_ALIAS = $CN
                    Write-LogMessage "Using CN as keystore alias: $JKS_ALIAS"
                }
                else {
                    Write-LogMessage "Using configured keystore alias: $JKS_ALIAS (CN=$CN)"
                }
            }
            $pfxCert.Dispose()
        }
        catch {
            Write-LogMessage "ERROR: Could not access PFX file: $_"
            exit 1
        }
    }
}
else {
    Write-LogMessage "ERROR: PFX file not found: $PFX_FILE_PATH"
    exit 1
}

# ========================================
# JAVA KEYSTORE UPDATE SECTION
# ========================================
Write-LogMessage "=========================================="
Write-LogMessage "Starting Java Keystore Update Process"
Write-LogMessage "=========================================="

# Check if keytool is available
$keytoolPath = Get-Command keytool -ErrorAction SilentlyContinue
if (-not $keytoolPath) {
    # Try to find keytool in JAVA_HOME
    if ($env:JAVA_HOME) {
        $keytoolPath = Join-Path $env:JAVA_HOME "bin\keytool.exe"
        if (-not (Test-Path $keytoolPath)) {
            Write-LogMessage "ERROR: keytool not found in JAVA_HOME\bin"
            exit 1
        }
    }
    else {
        Write-LogMessage "ERROR: keytool command not found and JAVA_HOME not set"
        exit 1
    }
}
else {
    $keytoolPath = "keytool"
}
Write-LogMessage "keytool is available at: $keytoolPath"

# Get Java version
try {
    $javaVersion = & $keytoolPath -version 2>&1
    Write-LogMessage "Java keytool version: $javaVersion"
}
catch {
    Write-LogMessage "WARNING: Could not determine keytool version"
}

# Create backup directory if it doesn't exist
if (-not (Test-Path $JKS_BACKUP_DIR)) {
    New-Item -ItemType Directory -Force -Path $JKS_BACKUP_DIR | Out-Null
    Write-LogMessage "Created backup directory: $JKS_BACKUP_DIR"
}

# Backup existing keystore if it exists
if (Test-Path $JKS_PATH) {
    $backupFile = Join-Path $JKS_BACKUP_DIR "weblogic_$(Get-Date -Format 'yyyyMMdd_HHmmss').jks"
    Copy-Item $JKS_PATH $backupFile -Force
    Write-LogMessage "Backed up existing keystore to: $backupFile"
    
    # Check if alias already exists
    $aliasExists = & $keytoolPath -list -keystore $JKS_PATH -storepass $JKS_PASSWORD -alias $JKS_ALIAS 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-LogMessage "Alias '$JKS_ALIAS' already exists in keystore, will be replaced"
        # Delete existing alias
        & $keytoolPath -delete -keystore $JKS_PATH -storepass $JKS_PASSWORD -alias $JKS_ALIAS 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-LogMessage "Deleted existing alias '$JKS_ALIAS' from keystore"
        }
    }
    else {
        Write-LogMessage "Alias '$JKS_ALIAS' does not exist in keystore, will be added"
    }
}
else {
    Write-LogMessage "Keystore does not exist at $JKS_PATH, will be created"
}

# Import PFX into Java keystore
Write-LogMessage "=========================================="
Write-LogMessage "Importing PFX into Java Keystore"
Write-LogMessage "=========================================="
Write-LogMessage "Source PFX: $PFX_FILE_PATH"
Write-LogMessage "Target JKS: $JKS_PATH"
Write-LogMessage "Alias: $JKS_ALIAS"

# Get source alias from PFX
$srcAliasOutput = & $keytoolPath -list -keystore $PFX_FILE_PATH -storepass $PFX_PASSWORD -storetype pkcs12 2>&1 | Select-String "PrivateKeyEntry"
if ($srcAliasOutput) {
    $SRC_ALIAS = ($srcAliasOutput -split ',')[0] -replace '.*:\s*', ''
    Write-LogMessage "Found source alias in PFX: $SRC_ALIAS"
}
else {
    $SRC_ALIAS = "1"
    Write-LogMessage "Could not determine source alias, using default: $SRC_ALIAS"
}

# Import the certificate
Write-LogMessage "Attempting PFX import using keytool..."
$importArgs = @(
    "-importkeystore",
    "-srckeystore", $PFX_FILE_PATH,
    "-srcstoretype", "pkcs12",
    "-srcstorepass", $PFX_PASSWORD,
    "-srcalias", $SRC_ALIAS,
    "-destkeystore", $JKS_PATH,
    "-deststoretype", "jks",
    "-deststorepass", $JKS_PASSWORD,
    "-destalias", $JKS_ALIAS,
    "-destkeypass", $JKS_PASSWORD,
    "-noprompt"
)

$importOutput = & $keytoolPath $importArgs 2>&1
$importResult = $LASTEXITCODE

Write-LogMessage $importOutput

if ($importResult -eq 0) {
    Write-LogMessage "SUCCESS: PFX successfully imported into Java keystore"
}
else {
    Write-LogMessage "Import failed with error code: $importResult"
    Write-LogMessage "Trying alternative import method without source alias..."
    
    # Try without specifying source alias
    $importArgs = @(
        "-importkeystore",
        "-srckeystore", $PFX_FILE_PATH,
        "-srcstoretype", "pkcs12",
        "-srcstorepass", $PFX_PASSWORD,
        "-destkeystore", $JKS_PATH,
        "-deststoretype", "jks",
        "-deststorepass", $JKS_PASSWORD,
        "-noprompt"
    )
    
    $importOutput = & $keytoolPath $importArgs 2>&1
    $importResult = $LASTEXITCODE
    
    Write-LogMessage $importOutput
    
    if ($importResult -eq 0) {
        Write-LogMessage "SUCCESS: Certificate imported using alternative method"
    }
    else {
        Write-LogMessage "ERROR: Failed to import PFX into keystore"
        exit 1
    }
}

# Verify the import
if ($importResult -eq 0) {
    Write-LogMessage "=========================================="
    Write-LogMessage "Verifying Java Keystore Import"
    Write-LogMessage "=========================================="
    
    # List all entries in the keystore
    Write-LogMessage "Listing all keystore entries:"
    $listOutput = & $keytoolPath -list -keystore $JKS_PATH -storepass $JKS_PASSWORD 2>&1
    Write-LogMessage $listOutput
    
    # Check specific alias
    $aliasCheck = & $keytoolPath -list -keystore $JKS_PATH -storepass $JKS_PASSWORD -alias $JKS_ALIAS 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-LogMessage "SUCCESS: Certificate alias '$JKS_ALIAS' verified in keystore"
        
        # Get certificate details
        Write-LogMessage "Certificate details for alias '$JKS_ALIAS':"
        $certDetails = & $keytoolPath -list -keystore $JKS_PATH -storepass $JKS_PASSWORD -alias $JKS_ALIAS -v 2>&1 | Select-String "Owner:|Issuer:|Valid from:|SHA256:"
        Write-LogMessage $certDetails
    }
    else {
        Write-LogMessage "WARNING: Alias '$JKS_ALIAS' not found, checking what was imported..."
        Write-LogMessage "All aliases in keystore:"
        $allAliases = & $keytoolPath -list -keystore $JKS_PATH -storepass $JKS_PASSWORD 2>&1 | Select-String "Entry,"
        Write-LogMessage $allAliases
    }
    
    Write-LogMessage "=========================================="
    Write-LogMessage "Java Keystore Update Completed Successfully"
    Write-LogMessage "=========================================="
    Write-LogMessage "Keystore: $JKS_PATH"
    Write-LogMessage "Source PFX: $NON_LEGACY_PFX"
    if (-not [string]::IsNullOrEmpty($LEGACY_PFX)) {
        Write-LogMessage "Legacy PFX (not imported): $LEGACY_PFX"
    }
    if (Test-Path $backupFile) {
        Write-LogMessage "Backup saved to: $backupFile"
    }
}
else {
    Write-LogMessage "=========================================="
    Write-LogMessage "ERROR: Java Keystore Update Failed"
    Write-LogMessage "=========================================="
    exit 1
}

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

exit 0