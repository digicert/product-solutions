<#
.SYNOPSIS
    DigiCert TLM Agent Certificate Processing Script (CRT/KEY Format) - PowerShell Version
.DESCRIPTION
    PowerShell conversion of the original Bash script for processing separate certificate and key files from DigiCert TLM Agent
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
$LOGFILE = "C:\Program Files\DigiCert\TLM Agent\log\awr-demo.log"

# Function to log messages with timestamp
function Write-LogMessage {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Add-Content -Path $LOGFILE -Encoding UTF8
}

# Start logging
Write-LogMessage "=========================================="
Write-LogMessage "Starting DC1_POST_SCRIPT_DATA extraction script"
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

Write-LogMessage "CERT_INFO length: $($CERT_INFO.Length) characters"

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
        $ARGUMENT_1 = $ARGS_ARRAY[0].Trim()
        Write-LogMessage "ARGUMENT_1 extracted: '$ARGUMENT_1'"
        Write-LogMessage "ARGUMENT_1 length: $($ARGUMENT_1.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 2) { 
        $ARGUMENT_2 = $ARGS_ARRAY[1].Trim()
        Write-LogMessage "ARGUMENT_2 extracted: '$ARGUMENT_2'"
        Write-LogMessage "ARGUMENT_2 length: $($ARGUMENT_2.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 3) { 
        $ARGUMENT_3 = $ARGS_ARRAY[2].Trim()
        Write-LogMessage "ARGUMENT_3 extracted: '$ARGUMENT_3'"
        Write-LogMessage "ARGUMENT_3 length: $($ARGUMENT_3.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 4) { 
        $ARGUMENT_4 = $ARGS_ARRAY[3].Trim()
        Write-LogMessage "ARGUMENT_4 extracted: '$ARGUMENT_4'"
        Write-LogMessage "ARGUMENT_4 length: $($ARGUMENT_4.Length)"
    }
    if ($ARGS_ARRAY.Count -ge 5) { 
        $ARGUMENT_5 = $ARGS_ARRAY[4].Trim()
        Write-LogMessage "ARGUMENT_5 extracted: '$ARGUMENT_5'"
        Write-LogMessage "ARGUMENT_5 length: $($ARGUMENT_5.Length)"
    }
}

# Extract cert folder
$CERT_FOLDER = $JSON_OBJECT.certfolder
Write-LogMessage "Extracted CERT_FOLDER: $CERT_FOLDER"

# Extract the certificate file (any extension)
$CERT_FILE = ""
if ($JSON_OBJECT.files) {
    $CERT_FILE = $JSON_OBJECT.files | Where-Object { $_ -match '\.(crt|pem|pfx|p12|cer|der)$' } | Select-Object -First 1
}
Write-LogMessage "Extracted CERT_FILE: $CERT_FILE"

# Extract the .crt file name (for backward compatibility)
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
$CRT_FILE_PATH = ""
$KEY_FILE_PATH = ""
$CERT_FILE_PATH = ""

if ($CRT_FILE) {
    $CRT_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CRT_FILE
}
if ($KEY_FILE) {
    $KEY_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $KEY_FILE
}
if ($CERT_FILE) {
    $CERT_FILE_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CERT_FILE
}

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
Write-LogMessage "  Certificate file (any): $CERT_FILE"
Write-LogMessage "  Certificate file (.crt): $CRT_FILE"
Write-LogMessage "  Private key file: $KEY_FILE"
Write-LogMessage "  Certificate path (current): $CERT_FILE_PATH"
Write-LogMessage "  Certificate path (.crt): $CRT_FILE_PATH"
Write-LogMessage "  Private key path: $KEY_FILE_PATH"
Write-LogMessage ""
Write-LogMessage "All files in array: $FILES_ARRAY"
Write-LogMessage "=========================================="

# Check if files exist and analyze them
$CERT_COUNT = 0
$KEY_FILE_CONTENT = ""

if (Test-Path $CRT_FILE_PATH) {
    $crtFileInfo = Get-Item $CRT_FILE_PATH
    Write-LogMessage "Certificate file exists: $CRT_FILE_PATH"
    Write-LogMessage "Certificate file size: $($crtFileInfo.Length) bytes"
    
    # Count certificates in the file
    $crtContent = Get-Content $CRT_FILE_PATH -Raw
    $CERT_COUNT = ([regex]::Matches($crtContent, "BEGIN CERTIFICATE")).Count
    Write-LogMessage "Total certificates in file: $CERT_COUNT"
    
    # Try to parse certificate using .NET
    try {
        # Extract just the first certificate if there are multiple
        if ($crtContent -match '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----') {
            $certBase64 = $matches[1] -replace '\s', ''
            $certBytes = [Convert]::FromBase64String($certBase64)
            $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($certBytes)
            
            Write-LogMessage "Certificate details:"
            Write-LogMessage "  Subject: $($cert.Subject)"
            Write-LogMessage "  Issuer: $($cert.Issuer)"
            Write-LogMessage "  Serial Number: $($cert.SerialNumber)"
            Write-LogMessage "  Valid From: $($cert.NotBefore)"
            Write-LogMessage "  Valid To: $($cert.NotAfter)"
            Write-LogMessage "  Thumbprint: $($cert.Thumbprint)"
            Write-LogMessage "  Signature Algorithm: $($cert.SignatureAlgorithm.FriendlyName)"
            
            $cert.Dispose()
        }
    } catch {
        Write-LogMessage "Could not parse certificate details: $_"
    }
} else {
    Write-LogMessage "WARNING: Certificate file not found: $CRT_FILE_PATH"
}

if (Test-Path $KEY_FILE_PATH) {
    $keyFileInfo = Get-Item $KEY_FILE_PATH
    Write-LogMessage "Private key file exists: $KEY_FILE_PATH"
    Write-LogMessage "Private key file size: $($keyFileInfo.Length) bytes"
    
    # Read key file content and determine type
    $KEY_FILE_CONTENT = Get-Content $KEY_FILE_PATH -Raw
    
    if ($KEY_FILE_CONTENT -match "BEGIN RSA PRIVATE KEY") {
        Write-LogMessage "Key type: RSA (BEGIN RSA PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN EC PRIVATE KEY") {
        Write-LogMessage "Key type: ECC (BEGIN EC PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN PRIVATE KEY") {
        Write-LogMessage "Key type: PKCS#8 format (BEGIN PRIVATE KEY found)"
    } elseif ($KEY_FILE_CONTENT -match "BEGIN ENCRYPTED PRIVATE KEY") {
        Write-LogMessage "Key type: Encrypted PKCS#8 format (BEGIN ENCRYPTED PRIVATE KEY found)"
    } else {
        Write-LogMessage "Key type: Unknown"
    }
} else {
    Write-LogMessage "WARNING: Private key file not found: $KEY_FILE_PATH"
}

# ============================================================================
# CUSTOM SCRIPT SECTION - ADD YOUR CUSTOM LOGIC HERE
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Starting custom script section..."
Write-LogMessage "=========================================="

# Function to extract common name from folder path
function Get-CommonNameFromPath {
    param([string]$FolderPath)
    
    $folderName = Split-Path $FolderPath -Leaf
    if ($folderName -match '^(.+?)_\d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2}$') {
        return $matches[1]
    }
    return $folderName
}

# Function to get certificate format from file extension
function Get-CertificateFormat {
    param([string]$FileName)
    
    $extension = [System.IO.Path]::GetExtension($FileName).ToLower()
    switch ($extension) {
        ".crt" { return "CRT" }
        ".pem" { return "PEM" }
        ".pfx" { return "PFX" }
        ".p12" { return "P12" }
        ".cer" { return "CER" }
        ".der" { return "DER" }
        default { return "Unknown" }
    }
}

# Determine the certificate format for the current certificate file
$CERT_FILE_FORMAT = ""
if ($CERT_FILE) {
    $CERT_FILE_FORMAT = Get-CertificateFormat $CERT_FILE
    Write-LogMessage "Current certificate format determined: $CERT_FILE_FORMAT for file: $CERT_FILE"
}

# Define paths
$SECRETS_PATH = "C:\Program Files\DigiCert\TLM Agent\.secrets"
$DATA_DIR = "C:\inetpub\wwwroot"
$CSV_PATH = Join-Path $DATA_DIR "awr-demo-certificate_data.csv"
$HTML_OUTPUT_PATH = Join-Path $DATA_DIR "awr-demo.html"

Write-LogMessage "Data directory: $DATA_DIR"
Write-LogMessage "CSV path: $CSV_PATH"
Write-LogMessage "HTML output path: $HTML_OUTPUT_PATH"

# Create data directory if it doesn't exist
if (!(Test-Path $DATA_DIR)) {
    New-Item -ItemType Directory -Path $DATA_DIR -Force | Out-Null
    Write-LogMessage "Created data directory: $DATA_DIR"
}

# Load existing CSV data or create empty structure
$existingData = @()
if (Test-Path $CSV_PATH) {
    try {
        Write-LogMessage "Loading existing CSV data..."
        # Read CSV manually to avoid encoding issues
        $csvLines = [System.IO.File]::ReadAllLines($CSV_PATH)
        if ($csvLines.Count -gt 1) {
            $headers = $csvLines[0] -replace '"', '' -split ','
            for ($i = 1; $i -lt $csvLines.Count; $i++) {
                $values = $csvLines[$i] -replace '"', '' -split ','
                if ($values.Count -ge 5) {
                    $record = [PSCustomObject]@{
                        DateTime = $values[0]
                        CommonName = $values[1]
                        CertificateFormat = $values[2]
                        FileName = $values[3]
                        FolderName = $values[4]
                        PostScript = if ($values.Count -gt 5) { $values[5] } else { "False" }
                        Argument1 = if ($values.Count -gt 6) { $values[6] } else { "" }
                        Argument2 = if ($values.Count -gt 7) { $values[7] } else { "" }
                        Argument3 = if ($values.Count -gt 8) { $values[8] } else { "" }
                        Argument4 = if ($values.Count -gt 9) { $values[9] } else { "" }
                        Argument5 = if ($values.Count -gt 10) { $values[10] } else { "" }
                    }
                    $existingData += $record
                }
            }
        }
        Write-LogMessage "Loaded $($existingData.Count) existing records from CSV"
    } catch {
        Write-LogMessage "ERROR: Failed to load existing CSV: $_"
    }
} else {
    Write-LogMessage "No existing CSV found, will create new one"
}

# Keep track of the current AWR folder name if we have one
$currentAWRFolderName = ""
if ($CERT_FOLDER) {
    $currentAWRFolderName = Split-Path $CERT_FOLDER -Leaf
    Write-LogMessage "Current AWR folder name: $currentAWRFolderName"
}

# Scan .secrets directory for all certificates and update CSV
Write-LogMessage "Scanning for certificate files in: $SECRETS_PATH"
$allCertificates = @()

if (Test-Path $SECRETS_PATH) {
    $certificateFiles = Get-ChildItem -Path $SECRETS_PATH -Recurse -File | 
        Where-Object { $_.Extension -match '\.(crt|pem|pfx|p12|cer|der)$' }
    
    foreach ($certFile in $certificateFiles) {
        $folderPath = $certFile.DirectoryName
        $fileName = $certFile.Name
        $format = Get-CertificateFormat $fileName
        $commonName = Get-CommonNameFromPath $folderPath
        $folderName = Split-Path $folderPath -Leaf
        $dateTime = $certFile.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        
        # Create unique key for certificate
        $certKey = "$folderName|$fileName"
        
        # Check if this certificate already exists in CSV data
        $existingCert = $existingData | Where-Object { "$($_.FolderName)|$($_.FileName)" -eq $certKey }
        
        # Determine post-script status: if this certificate is in the current AWR folder, mark it as True
        $postScript = "False"
        if ($currentAWRFolderName -and ($folderName -eq $currentAWRFolderName)) {
            $postScript = "True"
            Write-LogMessage "Certificate $fileName is in current AWR folder, marking as True"
        }
        
        if ($existingCert) {
            # Update existing entry
            $existingCert.DateTime = $dateTime
            $existingCert.CommonName = $commonName
            $existingCert.CertificateFormat = $format
            
            # Update post-script status if this is in the current AWR folder
            if ($postScript -eq "True") {
                $existingCert.PostScript = "True"
                # Also update arguments for post-script certificates
                if ($currentAWRFolderName -and ($folderName -eq $currentAWRFolderName)) {
                    $existingCert.Argument1 = $ARGUMENT_1
                    $existingCert.Argument2 = $ARGUMENT_2
                    $existingCert.Argument3 = $ARGUMENT_3
                    $existingCert.Argument4 = $ARGUMENT_4
                    $existingCert.Argument5 = $ARGUMENT_5
                }
            }
            
            $allCertificates += $existingCert
            Write-LogMessage "Updated existing certificate: $fileName (Post-Script: $($existingCert.PostScript))"
        } else {
            # Add new certificate from scan
            $newCert = [PSCustomObject]@{
                DateTime = $dateTime
                CommonName = $commonName
                CertificateFormat = $format
                FileName = $fileName
                FolderName = $folderName
                PostScript = $postScript
                Argument1 = if ($postScript -eq "True") { $ARGUMENT_1 } else { "" }
                Argument2 = if ($postScript -eq "True") { $ARGUMENT_2 } else { "" }
                Argument3 = if ($postScript -eq "True") { $ARGUMENT_3 } else { "" }
                Argument4 = if ($postScript -eq "True") { $ARGUMENT_4 } else { "" }
                Argument5 = if ($postScript -eq "True") { $ARGUMENT_5 } else { "" }
            }
            $allCertificates += $newCert
            Write-LogMessage "Added new certificate from scan: $fileName (Post-Script: $postScript)"
        }
    }
} else {
    Write-LogMessage "WARNING: Secrets directory not found: $SECRETS_PATH"
    $allCertificates = $existingData
}

# Sort certificates by date (oldest first)
Write-LogMessage "Sorting certificates by date (oldest first)..."
$allCertificates = $allCertificates | Sort-Object { [DateTime]$_.DateTime }

# Export updated data to CSV
try {
    # Convert to CSV format manually to avoid encoding issues
    $csvContent = @()
    $csvContent += '"DateTime","CommonName","CertificateFormat","FileName","FolderName","Post-Script","Post-Script Arg 1","Post-Script Arg 2","Post-Script Arg 3","Post-Script Arg 4","Post-Script Arg 5"'
    
    foreach ($cert in $allCertificates) {
        $line = @(
            "`"$($cert.DateTime)`"",
            "`"$($cert.CommonName)`"",
            "`"$($cert.CertificateFormat)`"",
            "`"$($cert.FileName)`"",
            "`"$($cert.FolderName)`"",
            "`"$($cert.PostScript)`"",
            "`"$($cert.Argument1)`"",
            "`"$($cert.Argument2)`"",
            "`"$($cert.Argument3)`"",
            "`"$($cert.Argument4)`"",
            "`"$($cert.Argument5)`""
        ) -join ','
        $csvContent += $line
    }
    
    # Write to file without BOM
    [System.IO.File]::WriteAllLines($CSV_PATH, $csvContent)
    Write-LogMessage "Updated CSV file with $($allCertificates.Count) certificate records"
    
    # Verify the file was written
    Start-Sleep -Milliseconds 500
    if (Test-Path $CSV_PATH) {
        $verifyContent = [System.IO.File]::ReadAllLines($CSV_PATH)
        Write-LogMessage "Verification: CSV file contains $($verifyContent.Count) lines"
    }
} catch {
    Write-LogMessage "ERROR: Failed to export CSV: $_"
}

# Generate HTML report
Write-LogMessage "Generating HTML report from CSV: $CSV_PATH"

# Use the in-memory data directly for HTML generation (already sorted)
$csvData = $allCertificates

# If no in-memory data, try reading from CSV
if ($csvData.Count -eq 0 -and (Test-Path $CSV_PATH)) {
    try {
        Write-LogMessage "No in-memory data, reading from CSV file..."
        $csvLines = [System.IO.File]::ReadAllLines($CSV_PATH)
        if ($csvLines.Count -gt 1) {
            $headers = $csvLines[0] -replace '"', '' -split ','
            for ($i = 1; $i -lt $csvLines.Count; $i++) {
                $values = $csvLines[$i] -replace '"', '' -split ','
                if ($values.Count -ge 5) {
                    $record = [PSCustomObject]@{
                        DateTime = $values[0]
                        CommonName = $values[1]
                        CertificateFormat = $values[2]
                        FileName = $values[3]
                        FolderName = $values[4]
                        PostScript = if ($values.Count -gt 5) { $values[5] } else { "False" }
                        Argument1 = if ($values.Count -gt 6) { $values[6] } else { "" }
                        Argument2 = if ($values.Count -gt 7) { $values[7] } else { "" }
                        Argument3 = if ($values.Count -gt 8) { $values[8] } else { "" }
                        Argument4 = if ($values.Count -gt 9) { $values[9] } else { "" }
                        Argument5 = if ($values.Count -gt 10) { $values[10] } else { "" }
                    }
                    $csvData += $record
                }
            }
            # Sort the loaded data
            $csvData = $csvData | Sort-Object { [DateTime]$_.DateTime }
        }
    } catch {
        Write-LogMessage "ERROR: Failed to read CSV for HTML generation: $_"
    }
}

Write-LogMessage "Using $($csvData.Count) records for HTML generation"

# Count certificates by type - Fixed counting method
$crtCount = 0
$pemCount = 0
$pfxCount = 0

# Count certificates by post-script status
$trueCount = 0
$falseCount = 0

if ($csvData.Count -gt 0) {
    # Use a more robust counting method
    $crtCerts = @($csvData | Where-Object { $_.CertificateFormat -eq "CRT" })
    $pemCerts = @($csvData | Where-Object { $_.CertificateFormat -eq "PEM" })
    $pfxCerts = @($csvData | Where-Object { $_.CertificateFormat -eq "PFX" })
    
    $crtCount = $crtCerts.Count
    $pemCount = $pemCerts.Count
    $pfxCount = $pfxCerts.Count
    
    # Count by post-script status
    $trueCerts = @($csvData | Where-Object { $_.PostScript -eq "True" })
    $falseCerts = @($csvData | Where-Object { $_.PostScript -eq "False" })
    
    $trueCount = $trueCerts.Count
    $falseCount = $falseCerts.Count
    
    Write-LogMessage "Certificate counts: CRT=$crtCount, PEM=$pemCount, PFX=$pfxCount"
    Write-LogMessage "Post-Script counts: True=$trueCount, False=$falseCount"
}

# Determine if any certificate has arguments
$hasArguments = $false
$maxArguments = 0

if ($csvData.Count -gt 0) {
    foreach ($row in $csvData) {
        for ($i = 1; $i -le 5; $i++) {
            $argValue = $row."Argument$i"
            if (![string]::IsNullOrEmpty($argValue) -and $argValue.Trim() -ne "") {
                $hasArguments = $true
                $maxArguments = [Math]::Max($maxArguments, $i)
            }
        }
    }
}

Write-LogMessage "Arguments status: hasArguments=$hasArguments, maxArguments=$maxArguments"

$currentDateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Create HTML content
$htmlLines = @()
$htmlLines += '<!DOCTYPE html>'
$htmlLines += '<html lang="en">'
$htmlLines += '<head>'
$htmlLines += '    <meta charset="UTF-8">'
$htmlLines += '    <meta name="viewport" content="width=device-width, initial-scale=1.0">'
$htmlLines += '    <title>Solution Engineering Admin Web Request Demo</title>'
$htmlLines += '    <style>'
$htmlLines += '        body { font-family: "Segoe UI", Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; color: #333; }'
$htmlLines += '        .header { background-color: #2c5aa0; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; text-align: center; }'
$htmlLines += '        .header h1 { margin: 0; font-size: 28px; }'
$htmlLines += '        .report-info { background-color: white; padding: 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }'
$htmlLines += '        .report-info h3 { margin-top: 0; color: #2c5aa0; }'
$htmlLines += '        .synopsis { background-color: white; padding: 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }'
$htmlLines += '        .synopsis h3 { margin-top: 0; color: #2c5aa0; }'
$htmlLines += '        .synopsis p { margin-bottom: 10px; line-height: 1.6; }'
$htmlLines += '        .synopsis ul { margin-top: 10px; margin-bottom: 10px; }'
$htmlLines += '        .synopsis li { margin-bottom: 5px; }'
$htmlLines += '        .synopsis .format-list { background-color: #f8f9fa; padding: 10px; border-radius: 4px; margin: 10px 0; }'
$htmlLines += '        .synopsis .format-item { margin-bottom: 8px; }'
$htmlLines += '        .synopsis .format-name { font-weight: bold; color: #2c5aa0; }'
$htmlLines += '        .summary { background-color: white; padding: 15px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }'
$htmlLines += '        .summary h3 { margin-top: 0; color: #2c5aa0; }'
$htmlLines += '        .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-top: 15px; }'
$htmlLines += '        .summary-item { background-color: #f8f9fa; padding: 15px; border-radius: 6px; text-align: center; border-left: 4px solid #2c5aa0; }'
$htmlLines += '        .summary-item .number { font-size: 24px; font-weight: bold; color: #2c5aa0; }'
$htmlLines += '        .summary-item .label { margin-top: 5px; font-size: 14px; color: #666; }'
$htmlLines += '        .table-container { background-color: white; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }'
$htmlLines += '        table { width: 100%; border-collapse: collapse; }'
$htmlLines += '        th { background-color: #2c5aa0; color: white; padding: 12px; text-align: left; font-weight: 600; }'
$htmlLines += '        td { padding: 12px; border-bottom: 1px solid #e9ecef; }'
$htmlLines += '        tr:nth-child(even) { background-color: #f8f9fa; }'
$htmlLines += '        tr:hover { background-color: #e3f2fd; }'
$htmlLines += '        .postscript-true { background-color: #28a745; color: white; padding: 2px 8px; border-radius: 4px; font-weight: 600; }'
$htmlLines += '        .postscript-false { background-color: #6c757d; color: white; padding: 2px 8px; border-radius: 4px; font-weight: 600; }'
$htmlLines += '        .no-data { text-align: center; padding: 40px; color: #666; font-style: italic; }'
$htmlLines += '        .footer { margin-top: 20px; text-align: center; color: #666; font-size: 12px; }'
$htmlLines += '    </style>'
$htmlLines += '</head>'
$htmlLines += '<body>'
$htmlLines += '    <div class="header">'
$htmlLines += '        <h1>Solution Engineering Admin Web Request Demo</h1>'
$htmlLines += '    </div>'
$htmlLines += '    <div class="report-info">'
$htmlLines += '        <h3>Report Information</h3>'
$htmlLines += '        <p><strong>Server:</strong> Cloudshare (uvo1eleeqhoqp63nmxa.vm.cld.sr)</p>'
$htmlLines += "        <p><strong>Server Time:</strong> $currentDateTime</p>"
$htmlLines += '    </div>'
$htmlLines += '    <div class="synopsis">'
$htmlLines += '        <h3>Synopsis</h3>'
$htmlLines += '        <p>This is to demonstrate the Admin Web Request initiated from Trust Lifecycle Manager.</p>'
$htmlLines += '        <p>This can demonstrate three certificate delivery formats:</p>'
$htmlLines += '        <div class="format-list">'
$htmlLines += '            <div class="format-item"><span class="format-name">CRT:</span> Plain Text X509 containing two files, cert + private key</div>'
$htmlLines += '            <div class="format-item"><span class="format-name">PEM:</span> X509 with encrypted, password protected private key (single file)</div>'
$htmlLines += '            <div class="format-item"><span class="format-name">PFX:</span> PKCS12 with embedded private key (single file)</div>'
$htmlLines += '        </div>'
$htmlLines += '        <p><strong>Post-Script Arguments:</strong> When initiating an Admin Web Request from Trust Lifecycle Manager, you can specify up to five arguments that will be passed from the request to the TLM Agent. These arguments are captured and made available to the post-script for use in automation. Common use cases include:</p>'
$htmlLines += '        <ul>'
$htmlLines += '            <li>API keys or authentication tokens for third-party services</li>'
$htmlLines += '            <li>Target server hostnames or IP addresses</li>'
$htmlLines += '            <li>Configuration parameters or environment identifiers</li>'
$htmlLines += '            <li>Notification endpoints or webhook URLs</li>'
$htmlLines += '            <li>Custom metadata or tracking identifiers</li>'
$htmlLines += '        </ul>'
$htmlLines += '        <p>The arguments passed during the Admin Web Request are displayed in the table below for tracking and audit purposes.</p>'
$htmlLines += "        <p>Any certificates present in the certificate folder, either through a local operation or admin web request without post script operation, will be marked 'False'. Certificates placed in the folder and utilizing the admin web request script are marked 'True'</p>"
$htmlLines += "        <p>An Admin Web Request Post Script can essentially do anything. In fact, this webpage was generated by an Admin Web Request, also. Another example could be a series of API calls to upload the generated certificates to a 3rd party appliance (i.e. Firewall, CDN etc.)</p>"
$htmlLines += "        <p>Please note though that this page only gets updated when the script is being executed by an Admin Web Request. If you add certificates locally, they will not appear here until the next Admin Web Request is executed.</p>"
$htmlLines += '    </div>'
$htmlLines += '    <div class="summary">'
$htmlLines += '        <h3>Certificate Summary</h3>'
$htmlLines += '        <div class="summary-grid">'
$htmlLines += '            <div class="summary-item">'
$htmlLines += "                <div class='number'>$crtCount</div>"
$htmlLines += '                <div class="label">CRT Certificates</div>'
$htmlLines += '            </div>'
$htmlLines += '            <div class="summary-item">'
$htmlLines += "                <div class='number'>$pemCount</div>"
$htmlLines += '                <div class="label">PEM Certificates</div>'
$htmlLines += '            </div>'
$htmlLines += '            <div class="summary-item">'
$htmlLines += "                <div class='number'>$pfxCount</div>"
$htmlLines += '                <div class="label">PFX Certificates</div>'
$htmlLines += '            </div>'
$htmlLines += '        </div>'
$htmlLines += '    </div>'
$htmlLines += '    <div class="table-container">'
$htmlLines += '        <table>'
$htmlLines += '            <thead>'
$htmlLines += '                <tr>'
$htmlLines += '                    <th>Date Time</th>'
$htmlLines += '                    <th>Common Name</th>'
$htmlLines += '                    <th>Certificate Format</th>'
$htmlLines += '                    <th>File Name</th>'
$htmlLines += '                    <th>Folder Name</th>'
$htmlLines += '                    <th>Post-Script</th>'

# Add argument columns if needed
if ($hasArguments) {
    for ($i = 1; $i -le $maxArguments; $i++) {
        $htmlLines += "                    <th>Post-Script Arg $i</th>"
    }
}

$htmlLines += '                </tr>'
$htmlLines += '            </thead>'
$htmlLines += '            <tbody>'

# Add table rows
if ($csvData.Count -gt 0) {
    Write-LogMessage "Adding $($csvData.Count) rows to HTML table"
    
    foreach ($row in $csvData) {
        $htmlLines += '                <tr>'
        $htmlLines += "                    <td>$($row.DateTime)</td>"
        $htmlLines += "                    <td>$($row.CommonName)</td>"
        $htmlLines += "                    <td>$($row.CertificateFormat)</td>"
        $htmlLines += "                    <td>$($row.FileName)</td>"
        $htmlLines += "                    <td>$($row.FolderName)</td>"
        
        # Add post-script status with styling
        if ($row.PostScript -eq "True") {
            $htmlLines += '                    <td><span class="postscript-true">True</span></td>'
        } else {
            $htmlLines += '                    <td><span class="postscript-false">False</span></td>'
        }
        
        # Add argument cells if needed
        if ($hasArguments) {
            for ($i = 1; $i -le $maxArguments; $i++) {
                $argValue = $row."Argument$i"
                if ([string]::IsNullOrEmpty($argValue)) { $argValue = "" }
                $htmlLines += "                    <td>$argValue</td>"
            }
        }
        
        $htmlLines += '                </tr>'
    }
} else {
    Write-LogMessage "No data found, adding 'no data' row"
    $colspanCount = 6  # Updated to include Post-Script column
    if ($hasArguments) { $colspanCount += $maxArguments }
    $htmlLines += "                <tr><td colspan='$colspanCount' class='no-data'>No certificate data available</td></tr>"
}

$htmlLines += '            </tbody>'
$htmlLines += '        </table>'
$htmlLines += '    </div>'
$htmlLines += '    <div class="footer">'
$htmlLines += '        <p>Generated by DigiCert TLM Agent Certificate Processing Script</p>'
$htmlLines += '        <p>© 2024 DigiCert, Inc. All rights reserved.</p>'
$htmlLines += '    </div>'
$htmlLines += '</body>'
$htmlLines += '</html>'

# Write HTML file
try {
    $htmlContent = $htmlLines -join "`n"
    [System.IO.File]::WriteAllText($HTML_OUTPUT_PATH, $htmlContent)
    Write-LogMessage "HTML report successfully generated: $HTML_OUTPUT_PATH"
    Write-LogMessage "Report contains $($csvData.Count) certificate entries"
    Write-LogMessage "Summary: CRT: $crtCount, PEM: $pemCount, PFX: $pfxCount"
    Write-LogMessage "Post-Script Status: True: $trueCount, False: $falseCount"
} catch {
    Write-LogMessage "ERROR: Failed to write HTML file: $_"
}

Write-LogMessage "Custom script section completed"
Write-LogMessage "=========================================="

# ============================================================================
# END OF CUSTOM SCRIPT SECTION
# ============================================================================

Write-LogMessage "=========================================="
Write-LogMessage "Script execution completed"
Write-LogMessage "=========================================="

exit 0