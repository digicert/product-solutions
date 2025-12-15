 <#
.SYNOPSIS
    Demo Wrapper Script for TLM Agent Post-Script Testing
  
.DESCRIPTION
    This script simulates the TLM agent by:
    1. Prompting for certificate and argument inputs
    2. Generating a self-signed certificate with OpenSSL
    3. Building the JSON payload structure
    4. Base64 encoding it into DC1_POST_SCRIPT_DATA
    5. Executing the target post-script
  
.PARAMETER TargetScript
    Path to the post-script to execute
  
.EXAMPLE
    .\awr-demo-wrapper.ps1 -TargetScript .\awr-template-crt.ps1
#>
  
param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$TargetScript
)
  
# Function to prompt with default value
function Read-HostWithDefault {
    param(
        [string]$Prompt,
        [string]$Default
    )
    $userInput = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($userInput)) {
        return $Default
    }
    return $userInput
}
  
# Header
Write-Host ""
Write-Host "========================================="
Write-Host "  TLM Agent Demo Wrapper Script"
Write-Host "========================================="
Write-Host ""
  
# Check if target script exists
if (-not (Test-Path $TargetScript)) {
    Write-Host "ERROR: Target script not found: $TargetScript" -ForegroundColor Red
    exit 1
}
  
# Check if OpenSSL is available
$opensslPath = $null
$possiblePaths = @(
    "C:\Program Files\OpenSSL-Win64\bin\openssl.exe",
    "C:\Program Files (x86)\OpenSSL-Win32\bin\openssl.exe",
    "C:\OpenSSL-Win64\bin\openssl.exe",
    "openssl"  # Try PATH
)
  
foreach ($path in $possiblePaths) {
    if ($path -eq "openssl") {
        # Check if openssl is in PATH
        $cmd = Get-Command openssl -ErrorAction SilentlyContinue
        if ($cmd) {
            $opensslPath = "openssl"
            break
        }
    } elseif (Test-Path $path) {
        $opensslPath = $path
        break
    }
}
  
if (-not $opensslPath) {
    Write-Host "ERROR: OpenSSL not found. Please install OpenSSL or add it to PATH." -ForegroundColor Red
    Write-Host "Download from: https://slproweb.com/products/Win32OpenSSL.html" -ForegroundColor Yellow
    exit 1
}
  
Write-Host "Target Script: $TargetScript"
Write-Host "OpenSSL: $opensslPath"
Write-Host ""
Write-Host "Enter values for JSON payload (press Enter to accept defaults):"
Write-Host ""
  
# --- Certificate Information ---
Write-Host "--- Certificate Information ---"
Write-Host ""
  
# Common Name
$COMMON_NAME = Read-HostWithDefault -Prompt "Common Name" -Default "awr-demo.com"
  
# Certificate Folder - dynamic default based on common name
$defaultCertFolder = "C:\Program Files\DigiCert\TLM Agent\.secrets\$COMMON_NAME"
$CERT_FOLDER = Read-HostWithDefault -Prompt "Certificate Folder" -Default $defaultCertFolder
  
# Remove trailing backslash if present
$CERT_FOLDER = $CERT_FOLDER.TrimEnd('\')
  
# Auto-generate certificate and key filenames from common name
$CERT_FILE = "$COMMON_NAME.crt"
$KEY_FILE = "$COMMON_NAME.key"
  
Write-Host ""
Write-Host "Certificate file will be: $CERT_FILE"
Write-Host "Private key file will be: $KEY_FILE"
Write-Host ""
  
# --- Script Arguments ---
Write-Host "--- Script Arguments ---"
Write-Host ""
  
$ARG_1 = Read-HostWithDefault -Prompt "Argument 1" -Default "Argument-1"
$ARG_2 = Read-HostWithDefault -Prompt "Argument 2" -Default "Argument-2"
$ARG_3 = Read-HostWithDefault -Prompt "Argument 3" -Default "Argument-3"
$ARG_4 = Read-HostWithDefault -Prompt "Argument 4" -Default "Argument-4"
$ARG_5 = Read-HostWithDefault -Prompt "Argument 5" -Default "Argument-5"
  
Write-Host ""
Write-Host "========================================="
Write-Host "  Generating Self-Signed Certificate"
Write-Host "========================================="
Write-Host ""
  
# Create certificate folder if it doesn't exist
if (-not (Test-Path $CERT_FOLDER)) {
    Write-Host "Creating certificate folder: $CERT_FOLDER"
    try {
        New-Item -ItemType Directory -Path $CERT_FOLDER -Force | Out-Null
        Write-Host "Certificate folder created successfully"
    } catch {
        Write-Host "ERROR: Failed to create certificate folder: $_" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Certificate folder already exists: $CERT_FOLDER"
}
  
# Build the subject string
$SUBJECT = "/C=US/ST=Utah/L=Lehi/O=Digicert/OU=Product/CN=$COMMON_NAME"
  
Write-Host ""
Write-Host "Certificate Subject: $SUBJECT"
Write-Host ""
  
# Generate self-signed certificate
$CERT_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $CERT_FILE
$KEY_PATH = Join-Path -Path $CERT_FOLDER -ChildPath $KEY_FILE
  
Write-Host "Generating certificate and private key..."
Write-Host "  Certificate: $CERT_PATH"
Write-Host "  Private Key: $KEY_PATH"
Write-Host ""
  
# Run OpenSSL to generate the certificate
# Build argument string with proper quoting for paths with spaces
$opensslArgs = "req -x509 -nodes -days 365 -newkey rsa:2048 -keyout `"$KEY_PATH`" -out `"$CERT_PATH`" -subj `"$SUBJECT`""
  
try {
    $process = Start-Process -FilePath $opensslPath -ArgumentList $opensslArgs -Wait -PassThru -NoNewWindow -RedirectStandardError "$env:TEMP\openssl_error.txt"
    
    if ($process.ExitCode -ne 0) {
        $errorContent = Get-Content "$env:TEMP\openssl_error.txt" -ErrorAction SilentlyContinue
        Write-Host "ERROR: Failed to generate certificate" -ForegroundColor Red
        Write-Host $errorContent -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "ERROR: Failed to run OpenSSL: $_" -ForegroundColor Red
    exit 1
}
  
Write-Host ""
Write-Host "Certificate generated successfully!" -ForegroundColor Green
Write-Host ""
  
# Display certificate info
Write-Host "Certificate Details:"
& $opensslPath x509 -in $CERT_PATH -noout -subject -dates
Write-Host ""
  
Write-Host "========================================="
Write-Host "  Building JSON Payload"
Write-Host "========================================="
Write-Host ""
  
# Build the JSON payload (matching actual TLM agent format)
$jsonObject = @{
    args = @($ARG_1, $ARG_2, $ARG_3, $ARG_4, $ARG_5)
    certfolder = $CERT_FOLDER
    files = @($CERT_FILE, $KEY_FILE)
}
  
$JSON_PAYLOAD = $jsonObject | ConvertTo-Json -Compress
  
Write-Host "Raw JSON Payload:"
Write-Host $JSON_PAYLOAD
Write-Host ""
  
Write-Host "Formatted JSON:"
Write-Host ($jsonObject | ConvertTo-Json)
Write-Host ""
  
# Base64 encode the JSON
$jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($JSON_PAYLOAD)
$ENCODED_PAYLOAD = [System.Convert]::ToBase64String($jsonBytes)
  
Write-Host "Base64 Encoded Payload:"
Write-Host $ENCODED_PAYLOAD
Write-Host ""
  
Write-Host "========================================="
Write-Host "  Executing Target Script"
Write-Host "========================================="
Write-Host ""
  
# Set the environment variable
$env:DC1_POST_SCRIPT_DATA = $ENCODED_PAYLOAD
  
Write-Host "DC1_POST_SCRIPT_DATA has been set ($($ENCODED_PAYLOAD.Length) characters)"
Write-Host ""
Write-Host "Executing: $TargetScript"
Write-Host ""
Write-Host "--- Script Output Below ---"
Write-Host ""
  
# Execute the target script
try {
    & $TargetScript
    $exitCode = $LASTEXITCODE
} catch {
    Write-Host "ERROR: Failed to execute target script: $_" -ForegroundColor Red
    $exitCode = 1
}
  
Write-Host ""
Write-Host "--- End of Script Output ---"
Write-Host ""
Write-Host "========================================="
Write-Host "  Execution Complete"
Write-Host "========================================="
Write-Host ""
Write-Host "Target script exit code: $exitCode"
Write-Host ""
  
exit $exitCode 

